"""Staging data profiling: completeness and cardinality of every column in a batch.

Results go to food_staging.stg_column_profile (one row per batch/table/column),
giving a per-batch view of how full and how varied each source column is,
which is useful for spotting a source change before it breaks a load.
"""

from sqlalchemy import text

from src.config import STAGING_DB
from src.ingestion.sources import SOURCES
from src.utils.db import get_engine
from src.utils.job_log import job_run
from src.utils.logger import get_logger

logger = get_logger("src.quality.profiler")


def _profile_query(table: str, columns: tuple[str, ...]) -> str:
    """One pass over the batch computing every column's statistics.

    Identifiers come from the SOURCES registry, never from input data.
    """
    selects = [
        f"SELECT '{column}' AS column_name, COUNT(*) AS row_count, "
        f"COALESCE(SUM(food_staging.fn_is_blank(`{column}`)), 0) AS blank_count, "
        f"COUNT(DISTINCT `{column}`) AS distinct_count, "
        f"LEFT(MIN(`{column}`), 255) AS min_value, LEFT(MAX(`{column}`), 255) AS max_value "
        f"FROM {table} WHERE batch_id = :batch_id"
        for column in columns
    ]
    return " UNION ALL ".join(selects)


def profile_batch(batch_id: str) -> int:
    """Profile every staging table's rows for the batch; returns the number of column profiles."""
    with job_run("profile_staging", batch_id) as job:
        rows = []
        with get_engine(STAGING_DB).connect() as conn:
            for spec in SOURCES.values():
                for table, columns in spec.tables.items():
                    for profile in conn.execute(text(_profile_query(table, columns)), {"batch_id": batch_id}).mappings():
                        if profile["row_count"]:
                            rows.append({"batch_id": batch_id, "table_name": table, **profile})

        with get_engine(STAGING_DB).begin() as conn:
            conn.execute(text("DELETE FROM stg_column_profile WHERE batch_id = :batch_id"), {"batch_id": batch_id})
            if rows:
                conn.execute(
                    text("INSERT INTO stg_column_profile (batch_id, table_name, column_name, row_count, "
                         "blank_count, distinct_count, min_value, max_value) VALUES (:batch_id, :table_name, "
                         ":column_name, :row_count, :blank_count, :distinct_count, :min_value, :max_value)"),
                    rows,
                )
        job.rows_read = job.rows_inserted = len(rows)
        logger.info("Profiled %d staging columns for batch %s", len(rows), batch_id)
    return len(rows)
