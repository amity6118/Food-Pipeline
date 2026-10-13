"""Parse: turn a validated source file into one DataFrame per staging table.

Every value is kept as text exactly as received (stray spaces included), since
staging stores raw VARCHARs and cleansing belongs to the stored procedures.
The only normalisation is that empty values become NULL.
"""

import json
from pathlib import Path
from typing import Any

import pandas as pd

from src.ingestion.sources import ORDER_COLUMNS, ORDER_ITEM_COLUMNS, SourceSpec


def _as_text(value: Any) -> str | None:
    """JSON value -> staging text; None and "" become NULL."""
    if value is None or value == "":
        return None
    return str(value)


def _parse_csv(path: Path, spec: SourceSpec) -> dict[str, pd.DataFrame]:
    (table, columns), = spec.tables.items()
    frame = pd.read_csv(path, dtype=str, keep_default_na=False, na_filter=False, encoding="utf-8-sig")
    frame.columns = frame.columns.str.strip()
    frame = frame[list(columns)].replace({"": None})
    return {table: frame}


def _parse_orders_json(path: Path) -> dict[str, pd.DataFrame]:
    orders = json.loads(path.read_text(encoding="utf-8"))
    order_rows = [{column: _as_text(order[column]) for column in ORDER_COLUMNS} for order in orders]
    item_rows = [
        {"order_id": _as_text(order["order_id"]),
         **{column: _as_text(item[column]) for column in ORDER_ITEM_COLUMNS if column != "order_id"}}
        for order in orders
        for item in order["items"]
    ]
    return {
        "stg_orders": pd.DataFrame(order_rows, columns=list(ORDER_COLUMNS)),
        "stg_order_items": pd.DataFrame(item_rows, columns=list(ORDER_ITEM_COLUMNS)),
    }


def parse_file(path: Path, spec: SourceSpec) -> dict[str, pd.DataFrame]:
    """Return {staging table: DataFrame of text columns} for the file."""
    if spec.file_format == "csv":
        return _parse_csv(path, spec)
    return _parse_orders_json(path)
