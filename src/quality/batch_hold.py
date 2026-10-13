"""Hold back batches that fail staging data quality.

A held batch stays in staging (for investigation) but every load procedure
skips it. When the batch later passes staging DQ, the hold is released and its
staging rows are re-queued with new stg_ids: the procedures' watermarks moved
past the original rows while they were held, so without re-queuing they would
never be loaded.
"""

from sqlalchemy import text

from src.config import CONTROL_DB, STAGING_DB
from src.ingestion.sources import SOURCES
from src.utils.db import get_engine
from src.utils.logger import get_logger

logger = get_logger("src.quality.batch_hold")

AUDIT_COLUMNS = ("batch_id", "source_file", "loaded_at")


def hold_batch(batch_id: str, reason: str) -> None:
    """Exclude the batch from warehouse loads until it passes staging DQ."""
    with get_engine(CONTROL_DB).begin() as conn:
        conn.execute(text("INSERT INTO etl_batch_hold (batch_id, reason) VALUES (:batch_id, :reason) AS new "
                          "ON DUPLICATE KEY UPDATE reason = new.reason, held_at = NOW()"),
                     {"batch_id": batch_id, "reason": reason[:500]})
    logger.warning("Batch %s held back from the warehouse: %s", batch_id, reason)


def release_batch(batch_id: str) -> None:
    """Lift a hold (if any) and re-queue the batch's staging rows for the next load."""
    with get_engine(CONTROL_DB).begin() as conn:
        released = conn.execute(text("DELETE FROM etl_batch_hold WHERE batch_id = :batch_id"),
                                {"batch_id": batch_id}).rowcount
    if not released:
        return

    with get_engine(STAGING_DB).begin() as conn:
        for spec in SOURCES.values():
            for table, columns in spec.tables.items():
                # Identifiers come from the SOURCES registry, never from input data
                column_list = ", ".join(f"`{c}`" for c in (*columns, *AUDIT_COLUMNS))
                last_old_id = conn.execute(text(f"SELECT MAX(stg_id) FROM {table} WHERE batch_id = :batch_id"),
                                           {"batch_id": batch_id}).scalar()
                if last_old_id is None:
                    continue
                conn.execute(text(f"INSERT INTO {table} ({column_list}) SELECT {column_list} FROM {table} "
                                  f"WHERE batch_id = :batch_id ORDER BY stg_id"), {"batch_id": batch_id})
                conn.execute(text(f"DELETE FROM {table} WHERE batch_id = :batch_id AND stg_id <= :last_old_id"),
                             {"batch_id": batch_id, "last_old_id": last_old_id})
    logger.info("Batch %s released from hold and re-queued for loading", batch_id)
