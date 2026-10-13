"""Validate: light structural checks before a file is loaded.

Only the file's shape is checked here (not empty, parsable, required columns
present). Value-level problems such as bad dates or negative amounts are left
for the data quality rules and stored procedures, because staging must keep
every row exactly as received.
"""

import csv
import json
from pathlib import Path

from src.ingestion.sources import ORDER_COLUMNS, ORDER_ITEM_COLUMNS, SourceSpec
from src.utils.logger import get_logger

logger = get_logger("src.ingestion.validate")


class ValidationError(ValueError):
    """The file does not meet its source contract and must not be loaded."""


def _validate_csv(path: Path, spec: SourceSpec) -> None:
    (required,) = spec.tables.values()
    # utf-8-sig also accepts files saved by Excel, which start with a byte-order mark
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if not header:
            raise ValidationError("file has no header row")
        header = [column.strip() for column in header]
        if len(header) != len(set(header)):
            raise ValidationError(f"duplicate column names in header: {header}")
        missing = [column for column in required if column not in header]
        if missing:
            raise ValidationError(f"missing required columns: {missing}")
        extra = [column for column in header if column not in required]
        if extra:
            logger.warning("%s: ignoring unexpected columns %s", path.name, extra)
        if next(reader, None) is None:
            raise ValidationError("file has a header but no data rows")


def _validate_orders_json(path: Path) -> None:
    try:
        orders = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValidationError(f"invalid JSON: {exc}") from exc
    if not isinstance(orders, list):
        raise ValidationError("expected a JSON array of orders")
    if not orders:
        raise ValidationError("the orders array is empty")
    for position, order in enumerate(orders):
        if not isinstance(order, dict):
            raise ValidationError(f"order #{position} is not an object")
        missing = [key for key in (*ORDER_COLUMNS, "items") if key not in order]
        if missing:
            raise ValidationError(f"order #{position} is missing keys {missing}")
        if not isinstance(order["items"], list):
            raise ValidationError(f"order #{position}: 'items' must be an array")
        for item in order["items"]:
            missing_item_keys = [key for key in ORDER_ITEM_COLUMNS if key != "order_id" and key not in item]
            if missing_item_keys:
                raise ValidationError(f"order #{position} has an item missing keys {missing_item_keys}")


def validate_file(path: Path, spec: SourceSpec) -> None:
    """Raise ValidationError if the file is empty, unreadable or misses required columns."""
    if path.stat().st_size == 0:
        raise ValidationError("file is empty (0 bytes)")
    try:
        if spec.file_format == "csv":
            _validate_csv(path, spec)
        else:
            _validate_orders_json(path)
    except UnicodeDecodeError as exc:
        raise ValidationError(f"file is not valid UTF-8: {exc}") from exc
