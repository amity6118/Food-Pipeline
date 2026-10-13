"""Build the web dashboard's three data files from the warehouse.

Run inside the stack (output goes to dashboard/data/, which is git-ignored):
    docker compose run --rm etl python -m dashboard.build_datasets

Definitions match the Power BI measures:
    orders     = all orders
    gmv        = gross amount of DELIVERED orders
    on_time    = delivered orders not late / delivered orders
    avg_rating = mean of non-null ratings
Date-range presets (7, 30, 90 days, all) are anchored on the latest order day; each
is compared with the previous period of the same length when the data covers it.
"""

import json
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import text

from src.config import DW_DB, PROJECT_ROOT
from src.utils.db import get_engine
from src.utils.logger import get_logger

logger = get_logger("dashboard.build_datasets")
OUT_DIR = PROJECT_ROOT / "dashboard" / "data"

ORDERS_SQL = """
    SELECT DATE(f.order_datetime) AS day, r.restaurant_id, r.restaurant_name, r.city,
           r.cuisine_type AS cuisine, f.order_status AS status, f.gross_amount AS gross,
           f.is_late, f.rating, f.delivery_minutes
    FROM fact_orders f
    JOIN dim_restaurant r ON r.restaurant_key = f.restaurant_key
"""
PRESETS = (("7d", "Last 7 days", 7), ("30d", "Last 30 days", 30), ("90d", "Last 90 days", 90))


def load_orders() -> list[dict[str, Any]]:
    """Order rows joined to the restaurant (city, cuisine) they were placed with."""
    with get_engine(DW_DB).connect() as conn:
        rows = [dict(r) for r in conn.execute(text(ORDERS_SQL)).mappings()]
    for r in rows:
        r["gross"] = float(r["gross"])
        r["rating"] = None if r["rating"] is None else float(r["rating"])
    return rows


def metrics(orders: list[dict[str, Any]]) -> dict[str, Any]:
    """The headline measures for a set of orders."""
    delivered = [r for r in orders if r["status"] == "DELIVERED"]
    rated = [r["rating"] for r in orders if r["rating"] is not None]
    minutes = [r["delivery_minutes"] for r in orders if r["delivery_minutes"] is not None]
    return {
        "orders": len(orders),
        "gmv": round(sum(r["gross"] for r in delivered), 2),
        "on_time": round(sum(not r["is_late"] for r in delivered) / len(delivered), 4) if delivered else None,
        "avg_rating": round(sum(rated) / len(rated), 2) if rated else None,
        "avg_minutes": round(sum(minutes) / len(minutes), 1) if minutes else None,
    }


def mean(values: list[float]) -> float | None:
    return round(sum(values) / len(values), 2) if values else None


def periods(first: date, last: date) -> list[tuple[str, str, date, date, tuple[date, date] | None]]:
    """(key, label, start, end, previous window or None) for each date-range preset."""
    result = []
    for key, label, days in PRESETS:
        start = last - timedelta(days=days - 1)
        previous = (start - timedelta(days=days), start - timedelta(days=1))
        result.append((key, label, start, last, previous if previous[0] >= first else None))
    result.append(("all", "All data", first, last, None))
    return result


def build(orders: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """The kpis, daily and restaurants datasets."""
    first, last = min(r["day"] for r in orders), max(r["day"] for r in orders)
    cities = sorted({r["city"] for r in orders})
    cuisines = sorted({r["cuisine"] for r in orders})
    slices = [(city, cuisine) for city in ["All", *cities] for cuisine in ["All", *cuisines]]

    def in_slice(r: dict[str, Any], city: str, cuisine: str) -> bool:
        return city in ("All", r["city"]) and cuisine in ("All", r["cuisine"])

    def label(d: date) -> str:
        return f"{d:%b} {d.day}"

    kpis = []
    for key, name, start, end, previous in periods(first, last):
        days = [start + timedelta(days=i) for i in range((end - start).days + 1)]
        for city, cuisine in slices:  # empty slices stay in, so every filter choice resolves to a row
            sel = [r for r in orders if start <= r["day"] <= end and in_slice(r, city, cuisine)]
            m = metrics(sel)
            prev = metrics([r for r in orders if previous[0] <= r["day"] <= previous[1]
                            and in_slice(r, city, cuisine)]) if previous else None
            per_day: dict[date, int] = defaultdict(int)
            for r in sel:
                per_day[r["day"]] += 1
            weekend = [per_day[d] for d in days if d.weekday() >= 5]
            weekday = [per_day[d] for d in days if d.weekday() < 5]
            delivered_rated = [r for r in sel if r["status"] == "DELIVERED" and r["rating"]]
            kpis.append({
                "period": key, "period_label": name, "start": start.isoformat(), "end": end.isoformat(),
                "window": f"{label(start)} – {label(end)}", "city": city, "cuisine": cuisine,
                "orders": m["orders"], "gmv": m["gmv"], "on_time": m["on_time"], "avg_rating": m["avg_rating"],
                "prev_orders": prev["orders"] if prev else None, "prev_gmv": prev["gmv"] if prev else None,
                "prev_on_time": prev["on_time"] if prev else None,
                "prev_avg_rating": prev["avg_rating"] if prev else None,
                "rating_on_time": mean([r["rating"] for r in delivered_rated if not r["is_late"]]),
                "rating_late": mean([r["rating"] for r in delivered_rated if r["is_late"]]),
                "weekend_uplift": (round((sum(weekend) / len(weekend)) / (sum(weekday) / len(weekday)) - 1, 4)
                                   if weekend and weekday and sum(weekday) else None),
            })

    daily = []
    for d in [first + timedelta(days=i) for i in range((last - first).days + 1)]:
        day_orders = [r for r in orders if r["day"] == d]
        for city, cuisine in slices:
            m = metrics([r for r in day_orders if in_slice(r, city, cuisine)])
            daily.append({"day": d.isoformat(), "city": city, "cuisine": cuisine, "orders": m["orders"], "gmv": m["gmv"]})

    names = {r["restaurant_id"]: (r["restaurant_name"], r["city"], r["cuisine"]) for r in orders}
    restaurants = []
    for key, _, start, end, _ in periods(first, last):
        for rid, (name, city, cuisine) in sorted(names.items()):
            sel = [r for r in orders if r["restaurant_id"] == rid and start <= r["day"] <= end]
            if sel:
                m = metrics(sel)
                restaurants.append({"period": key, "restaurant_id": rid, "restaurant": name, "city": city,
                                    "cuisine": cuisine, "orders": m["orders"], "gmv": m["gmv"],
                                    "on_time": m["on_time"], "avg_rating": m["avg_rating"],
                                    "avg_minutes": m["avg_minutes"]})
    return {"kpis": kpis, "daily": daily, "restaurants": restaurants}


def main() -> None:
    """Query the warehouse and write dashboard/data/<dataset>.json."""
    orders = load_orders()
    if not orders:
        raise SystemExit("The warehouse has no orders yet: run the pipeline first.")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, rows in build(orders).items():
        path = OUT_DIR / f"{name}.json"
        path.write_text(json.dumps(rows, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
        logger.info("Wrote %s (%d rows)", path.relative_to(PROJECT_ROOT), len(rows))


if __name__ == "__main__":
    main()
