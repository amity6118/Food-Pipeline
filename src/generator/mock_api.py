"""Mock food-delivery Orders API (FastAPI).

Stands in for the order service of a Zomato/Swiggy-style platform so the
pipeline can demonstrate paginated HTTP extraction. Orders are generated on
demand and are deterministic per date, so repeated calls return identical data.

    GET /health
    GET /orders?date=YYYY-MM-DD&page=1&page_size=500
"""

from datetime import date
from functools import lru_cache
from math import ceil
from typing import Any

from fastapi import FastAPI, HTTPException, Query

from src.config import CALENDAR_END, CALENDAR_START
from src.generator.master_data import build_platform
from src.generator.orders import generate_orders

app = FastAPI(
    title="Food Orders Mock API",
    version="1.0.0",
    description="Simulated order feed for the Food Order ETL Pipeline.",
)


@lru_cache(maxsize=32)
def _orders_for(order_date: date) -> tuple[dict[str, Any], ...]:
    return tuple(generate_orders(order_date, build_platform()))


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness probe used by the container healthcheck."""
    return {"status": "ok"}


@app.get("/orders")
def list_orders(
    order_date: date = Query(..., alias="date", description="Order date, YYYY-MM-DD"),
    page: int = Query(1, ge=1),
    page_size: int = Query(500, ge=1, le=1000),
) -> dict[str, Any]:
    """One page of the orders placed on `date`, each with its order items."""
    latest = min(CALENDAR_END, date.today())
    if not CALENDAR_START <= order_date <= latest:
        raise HTTPException(status_code=422, detail=f"date must be between {CALENDAR_START} and {latest}")

    orders = _orders_for(order_date)
    total_pages = max(1, ceil(len(orders) / page_size))
    start = (page - 1) * page_size
    return {
        "date": order_date.isoformat(),
        "page": page,
        "page_size": page_size,
        "total_orders": len(orders),
        "total_pages": total_pages,
        "orders": list(orders[start:start + page_size]),
    }
