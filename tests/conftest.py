"""Shared fixtures. Integration tests are skipped automatically when MySQL is unreachable."""

from collections.abc import Iterator

import pytest
from sqlalchemy import text
from sqlalchemy.engine import Connection
from sqlalchemy.exc import OperationalError

from src.config import DW_DB
from src.utils.db import get_engine


@pytest.fixture(scope="session")
def dw() -> Iterator[Connection]:
    """Read-only connection to food_dw for integration tests."""
    try:
        conn = get_engine(DW_DB).connect()
        conn.execute(text("SELECT 1"))
    except (RuntimeError, OperationalError) as exc:
        pytest.skip(f"MySQL not reachable: {exc}")
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def loaded_dw(dw: Connection) -> Connection:
    """food_dw connection, skipping tests when the warehouse has not been loaded yet."""
    if not dw.execute(text("SELECT COUNT(*) FROM fact_orders")).scalar():
        pytest.skip("warehouse is empty; run the pipeline first")
    return dw
