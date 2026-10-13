"""Pipeline runner: executes the steps for one run date, in order, stopping at the first failure.

    generate -> ingest -> dq_staging -> load_dimensions -> load_facts -> dq_warehouse

The whole run is logged as a `pipeline_run` job; each step logs its own jobs
(ingestion files, DQ checks, stored procedures). On failure the remaining steps
are skipped and an alert is sent through the configured notifiers.
"""

import traceback
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date

from sqlalchemy import text

from src.config import CONTROL_DB, DATA_LANDING_DIR
from src.generator.master_data import write_master_csvs
from src.ingestion.runner import run_ingestion
from src.orchestration.notifier import notify_failure
from src.processing.procedure_runner import load_dimensions, load_facts, reset_warehouse
from src.quality.dq_engine import run_dq_checks
from src.quality.profiler import profile_batch
from src.utils.batch import make_batch_id
from src.utils.db import get_engine
from src.utils.job_log import job_run
from src.utils.logger import get_logger, log_context

logger = get_logger("src.orchestration.pipeline")


class PipelineError(Exception):
    """A pipeline step failed; downstream steps were not run."""


@dataclass(frozen=True)
class RunContext:
    """What a step needs to know about the current run."""

    run_date: date
    batch_id: str


def _generate(ctx: RunContext) -> None:
    write_master_csvs(ctx.run_date, DATA_LANDING_DIR)


def _ingest(ctx: RunContext) -> None:
    summary = run_ingestion(ctx.run_date)
    if summary.failed:
        raise PipelineError("ingestion failed for: " + ", ".join(
            f"{r.source} ({r.error})" for r in summary.failed))


def _dq_staging(ctx: RunContext) -> None:
    profile_batch(ctx.batch_id)
    run_dq_checks("STAGING", ctx.batch_id)


def _load_dimensions(ctx: RunContext) -> None:
    load_dimensions(ctx.batch_id)


def _load_facts(ctx: RunContext) -> None:
    load_facts(ctx.batch_id)


def _dq_warehouse(ctx: RunContext) -> None:
    run_dq_checks("WAREHOUSE", ctx.batch_id)


STEPS: dict[str, Callable[[RunContext], None]] = {
    "generate": _generate,
    "ingest": _ingest,
    "dq_staging": _dq_staging,
    "load_dimensions": _load_dimensions,
    "load_facts": _load_facts,
    "dq_warehouse": _dq_warehouse,
}


def _record_success(batch_id: str) -> None:
    with get_engine(CONTROL_DB).begin() as conn:
        conn.execute(text("UPDATE pipeline_metadata SET metadata_value = :batch_id "
                          "WHERE metadata_key = 'last_successful_batch_id'"), {"batch_id": batch_id})


def run_pipeline(run_date: date, steps: list[str] | None = None, full_refresh: bool = False) -> None:
    """Run the selected steps (default: all) for `run_date`.

    Args:
        run_date: Business date to process.
        steps: Subset of STEPS to run, executed in pipeline order.
        full_refresh: Empty the warehouse first and rebuild it from all staged
            batches (applies before the load steps).

    Raises:
        PipelineError: If a step fails (an alert has already been sent).
    """
    selected = [name for name in STEPS if steps is None or name in steps]
    ctx = RunContext(run_date, make_batch_id(run_date))

    with log_context(batch_id=ctx.batch_id):
        logger.info("Pipeline started for %s: %s%s", run_date, " -> ".join(selected),
                    " (full refresh)" if full_refresh else "")
        current_step = "start"
        try:
            with job_run("pipeline_run", ctx.batch_id):
                if full_refresh:
                    current_step = "full_refresh"
                    with log_context(step=current_step):
                        reset_warehouse(ctx.batch_id)
                for current_step in selected:
                    with log_context(step=current_step):
                        logger.info("Step %s started", current_step)
                        STEPS[current_step](ctx)
                        logger.info("Step %s finished", current_step)
        except Exception as exc:
            subject = f"[food-order-pipeline] {ctx.batch_id} failed at step '{current_step}'"
            body = (f"Run date: {run_date}\nBatch: {ctx.batch_id}\nFailed step: {current_step}\n"
                    f"Error: {type(exc).__name__}: {exc}\n\n{traceback.format_exc(limit=5)}")
            notify_failure(subject, body)
            raise PipelineError(f"pipeline failed for {ctx.batch_id} at step '{current_step}': {exc}") from exc

        if steps is None:
            _record_success(ctx.batch_id)
        logger.info("Pipeline finished successfully for %s", run_date)
