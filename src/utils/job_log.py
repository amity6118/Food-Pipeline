"""Job audit trail: records every pipeline step in food_control.etl_job_log.

Usage:
    with job_run("ingest_customers", batch_id) as job:
        job.rows_read = ...
        job.rows_inserted = ...

The row is written as RUNNING when the block starts and finished as SUCCESS,
or as FAILED with the error (plus a traceback in etl_error_log) if the block raises.
"""

import traceback
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

from sqlalchemy import text

from src.config import CONTROL_DB
from src.utils.db import get_engine

MAX_MESSAGE_LENGTH = 60_000  # stays inside a MySQL TEXT column


@dataclass
class JobCounters:
    """Row counts a step reports for its job-log entry."""

    rows_read: int = 0
    rows_inserted: int = 0
    rows_updated: int = 0
    rows_rejected: int = 0


def _finish(job_id: int, status: str, counters: JobCounters, error_message: str | None = None) -> None:
    with get_engine(CONTROL_DB).begin() as conn:
        conn.execute(
            text("""UPDATE etl_job_log
                    SET status = :status, end_time = NOW(), rows_read = :rows_read,
                        rows_inserted = :rows_inserted, rows_updated = :rows_updated,
                        rows_rejected = :rows_rejected, error_message = :error_message
                    WHERE job_id = :job_id"""),
            {"job_id": job_id, "status": status, "error_message": error_message, **vars(counters)},
        )


@contextmanager
def job_run(job_name: str, batch_id: str) -> Iterator[JobCounters]:
    """Log the enclosed block as one job; re-raises any exception after logging it."""
    with get_engine(CONTROL_DB).begin() as conn:
        job_id = conn.execute(
            text("INSERT INTO etl_job_log (job_name, batch_id, status, start_time) "
                 "VALUES (:job_name, :batch_id, 'RUNNING', NOW())"),
            {"job_name": job_name, "batch_id": batch_id},
        ).lastrowid

    counters = JobCounters()
    try:
        yield counters
    except Exception as exc:
        message = f"{type(exc).__name__}: {exc}"[:MAX_MESSAGE_LENGTH]
        _finish(job_id, "FAILED", counters, message)
        with get_engine(CONTROL_DB).begin() as conn:
            conn.execute(
                text("INSERT INTO etl_error_log (job_id, batch_id, step_name, error_code, error_message, error_detail) "
                     "VALUES (:job_id, :batch_id, :step_name, :error_code, :error_message, :error_detail)"),
                {"job_id": job_id, "batch_id": batch_id, "step_name": job_name,
                 "error_code": type(exc).__name__[:20], "error_message": message,
                 "error_detail": traceback.format_exc()[:MAX_MESSAGE_LENGTH]},
            )
        raise
    _finish(job_id, "SUCCESS", counters)
