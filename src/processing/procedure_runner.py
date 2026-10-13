"""Processing step: call the warehouse stored procedures in dependency order.

All transformation logic lives in the procedures (sql/init/09-11); this module
only invokes them. Each procedure writes its own etl_job_log entry, and a
failure inside one is rolled back, logged and re-raised here as a DBAPIError.
"""

from sqlalchemy import text

from src.config import DW_DB
from src.utils.db import get_engine
from src.utils.logger import get_logger

logger = get_logger("src.processing")

# Dimensions first (facts look up their surrogate keys); orders before order items.
DIMENSION_PROCEDURES = (
    "sp_load_dim_payment_method",
    "sp_load_dim_delivery_partner",
    "sp_load_dim_restaurant",
    "sp_load_dim_menu_item",
    "sp_load_dim_customer",
)
FACT_PROCEDURES = ("sp_load_fact_orders", "sp_load_fact_order_items")


def call_procedure(name: str, batch_id: str) -> None:
    """CALL food_dw.<name>(batch_id) on an autocommit connection.

    Autocommit is required: the procedures manage their own transactions, and
    their job-log writes must persist even when the load itself rolls back.
    """
    if name not in (*DIMENSION_PROCEDURES, *FACT_PROCEDURES, "sp_reset_warehouse"):
        raise ValueError(f"unknown procedure: {name}")
    logger.info("CALL %s('%s')", name, batch_id)
    with get_engine(DW_DB).connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
        conn.execute(text(f"CALL {name}(:batch_id)"), {"batch_id": batch_id})


def load_dimensions(batch_id: str) -> None:
    """Run every dimension load procedure."""
    for name in DIMENSION_PROCEDURES:
        call_procedure(name, batch_id)


def load_facts(batch_id: str) -> None:
    """Run the fact load procedures (after the dimensions)."""
    for name in FACT_PROCEDURES:
        call_procedure(name, batch_id)


def reset_warehouse(batch_id: str) -> None:
    """Empty the warehouse and rewind watermarks so the next load rebuilds it from staging."""
    call_procedure("sp_reset_warehouse", batch_id)
