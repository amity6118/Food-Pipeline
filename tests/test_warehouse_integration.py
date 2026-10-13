"""Integration tests against MySQL: SQL cleansing functions and warehouse invariants.

Run inside the stack after at least one pipeline run:
    docker compose run --rm etl pytest -m integration
"""

from decimal import Decimal

import pytest
from sqlalchemy import text

pytestmark = pytest.mark.integration


def scalar(conn, sql: str, **params):
    return conn.execute(text(sql), params).scalar()


# -- cleansing functions (food_staging.fn_*) --------------------------------------------
@pytest.mark.parametrize("raw, expected", [
    ("2024-02-29 13:05:09", "2024-02-29 13:05:09"),
    ("2024-07-01", "2024-07-01 00:00:00"),
    ("2024-02-31 25:99:99", None),   # injected dirty value
    ("2023-02-29", None),            # not a leap year
    ("2026/10/12", None),
    ("   ", None),
])
def test_fn_to_datetime(dw, raw, expected):
    value = scalar(dw, "SELECT food_staging.fn_to_datetime(:raw)", raw=raw)
    assert (value.strftime("%Y-%m-%d %H:%M:%S") if value else None) == expected


@pytest.mark.parametrize("function, raw, expected", [
    ("fn_to_decimal", " 120.50 ", Decimal("120.50")),
    ("fn_to_decimal", "-150", Decimal("-150.00")),
    ("fn_to_decimal", "12x", None),
    ("fn_to_int", "38.0", 38),
    ("fn_to_int", "38.5", None),
    ("fn_to_flag", " yes ", 1),
    ("fn_to_flag", "0", 0),
    ("fn_to_flag", "maybe", None),
    ("fn_clean_phone", "+91 98450 12345", "+91-9845012345"),
    ("fn_clean_phone", "12345", None),
    ("fn_title_case", "  FAST   FOOD ", "Fast Food"),
    ("fn_clean_text", "   Asha   Rao  ", "Asha Rao"),
])
def test_cleansing_functions(dw, function, raw, expected):
    assert scalar(dw, f"SELECT food_staging.{function}(:raw)", raw=raw) == expected


# -- business rules and integrity of the loaded warehouse --------------------------------
def test_net_amount_follows_the_business_formula(loaded_dw):
    assert scalar(loaded_dw, "SELECT COUNT(*) FROM fact_orders "
                             "WHERE ABS(net_amount - (gross_amount - discount + delivery_fee)) > 0.001") == 0


def test_is_late_matches_the_sla(loaded_dw):
    assert scalar(loaded_dw, """
        SELECT COUNT(*) FROM fact_orders
        WHERE is_late <> COALESCE(delivery_minutes > food_control.fn_metadata_int('delivery_sla_minutes', 45), 0)
    """) == 0


def test_messy_source_statuses_are_mapped(loaded_dw):
    rows = loaded_dw.execute(text("""
        SELECT LOWER(TRIM(s.order_status)) AS raw_status, f.order_status
        FROM food_staging.stg_orders s JOIN fact_orders f ON f.order_id = TRIM(s.order_id)
    """)).all()
    expected = {"delivered": "DELIVERED", "cancelled": "CANCELLED", "canceled": "CANCELLED", "refunded": "REFUNDED"}
    assert rows and all(expected[raw] == mapped for raw, mapped in rows)


@pytest.mark.parametrize("dimension, natural_key", [("dim_customer", "customer_id"),
                                                    ("dim_restaurant", "restaurant_id")])
def test_scd2_has_exactly_one_current_version_and_gapless_history(loaded_dw, dimension, natural_key):
    assert scalar(loaded_dw, f"SELECT COUNT(*) FROM (SELECT {natural_key} FROM {dimension} "
                             f"GROUP BY {natural_key} HAVING SUM(is_current) <> 1) x") == 0
    # each expired version ends exactly where the next version starts
    assert scalar(loaded_dw, f"""
        SELECT COUNT(*) FROM {dimension} prev
        JOIN {dimension} nxt ON nxt.{natural_key} = prev.{natural_key} AND nxt.scd_version = prev.scd_version + 1
        WHERE prev.valid_to <> nxt.valid_from OR prev.is_current = 1
    """) == 0


def test_orders_use_the_customer_version_valid_at_order_time(loaded_dw):
    assert scalar(loaded_dw, """
        SELECT COUNT(*) FROM fact_orders f JOIN dim_customer c ON c.customer_key = f.customer_key
        WHERE NOT (f.order_datetime >= c.valid_from AND f.order_datetime < c.valid_to)
    """) == 0


def test_every_staged_order_is_loaded_or_rejected(loaded_dw):
    """Row-count reconciliation per batch (held batches excluded): staged = loaded + rejected."""
    mismatches = loaded_dw.execute(text("""
        SELECT s.batch_id, s.staged, COALESCE(l.loaded, 0) AS loaded, COALESCE(r.rejected, 0) AS rejected
        FROM (SELECT batch_id, COUNT(DISTINCT UPPER(TRIM(order_id))) AS staged
              FROM food_staging.stg_orders GROUP BY batch_id) s
        LEFT JOIN (SELECT batch_id, COUNT(*) AS loaded FROM fact_orders GROUP BY batch_id) l
               ON l.batch_id = s.batch_id
        LEFT JOIN (SELECT batch_id, COUNT(DISTINCT record_identifier) AS rejected
                   FROM food_staging.stg_rejected_records WHERE source_table = 'stg_orders' GROUP BY batch_id) r
               ON r.batch_id = s.batch_id
        WHERE s.batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)
          AND s.staged <> COALESCE(l.loaded, 0) + COALESCE(r.rejected, 0)
    """)).all()
    assert mismatches == []
