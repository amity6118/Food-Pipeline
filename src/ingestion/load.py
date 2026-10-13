"""Load: bulk-insert parsed frames into food_staging, idempotently per batch."""

import pandas as pd
from sqlalchemy import text

from src.config import STAGING_DB
from src.ingestion.sources import SOURCES
from src.utils.db import get_engine

STAGING_TABLES = frozenset(table for spec in SOURCES.values() for table in spec.tables)
INSERT_CHUNK_ROWS = 1_000


def load_to_staging(frames: dict[str, pd.DataFrame], batch_id: str, source_file: str) -> dict[str, int]:
    """Replace this batch's rows in each staging table with the given frames.

    Deleting the batch's existing rows first, in the same transaction as the
    insert, makes a re-run of the same batch replace rather than duplicate data.
    Re-inserted rows get new, higher stg_ids, so the warehouse procedures'
    stg_id watermarks pick them up again.

    Returns:
        Rows inserted per staging table.
    """
    unknown = set(frames) - STAGING_TABLES
    if unknown:
        raise ValueError(f"not a staging table: {sorted(unknown)}")

    inserted: dict[str, int] = {}
    with get_engine(STAGING_DB).begin() as conn:
        for table, frame in frames.items():
            # Table names come from the SOURCES registry (checked above), never from input data
            conn.execute(text(f"DELETE FROM {table} WHERE batch_id = :batch_id"), {"batch_id": batch_id})
            frame.assign(batch_id=batch_id, source_file=source_file).to_sql(
                table, conn, if_exists="append", index=False, method="multi", chunksize=INSERT_CHUNK_ROWS)
            inserted[table] = len(frame)
    return inserted
