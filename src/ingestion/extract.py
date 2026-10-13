"""Extract: pull the day's orders from the mock API and locate the landed files."""

import json
import os
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from src.config import DATA_LANDING_DIR, MOCK_API_BASE_URL
from src.ingestion.sources import SOURCES
from src.utils.logger import get_logger

logger = get_logger("src.ingestion.extract")

PAGE_SIZE = 500
MAX_ATTEMPTS = 3
REQUEST_TIMEOUT_SECONDS = 30


class ExtractError(Exception):
    """The source API could not be read."""


def _get_json(url: str) -> dict[str, Any]:
    """GET a JSON document, retrying transient failures with exponential backoff."""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code < 500:  # client errors will not succeed on retry
                raise ExtractError(f"GET {url} failed: HTTP {exc.code} {exc.read().decode(errors='replace')}") from exc
            error: Exception = exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            error = exc
        if attempt < MAX_ATTEMPTS:
            logger.warning("GET %s failed (%s); retrying in %ss", url, error, 2 ** attempt)
            time.sleep(2 ** attempt)
    raise ExtractError(f"GET {url} failed after {MAX_ATTEMPTS} attempts: {error}")


def fetch_orders(run_date: date, base_url: str = MOCK_API_BASE_URL,
                 landing_dir: Path = DATA_LANDING_DIR) -> tuple[Path, int]:
    """Download every page of the day's orders and land them as one JSON file.

    Returns:
        Path of the landed file and the number of orders in it.
    """
    orders: list[dict[str, Any]] = []
    page, total_pages = 1, 1
    while page <= total_pages:
        query = urlencode({"date": run_date.isoformat(), "page": page, "page_size": PAGE_SIZE})
        payload = _get_json(f"{base_url.rstrip('/')}/orders?{query}")
        orders.extend(payload["orders"])
        total_pages = payload["total_pages"]
        page += 1

    path = landing_dir / SOURCES["orders"].filename(run_date)
    tmp_path = path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(orders, indent=1), encoding="utf-8")
    os.replace(tmp_path, path)  # atomic: ingestion never sees a partial file
    logger.info("Landed %d orders from %d page(s) at %s", len(orders), total_pages, path.name)
    return path, len(orders)


def discover_files(run_date: date, landing_dir: Path = DATA_LANDING_DIR) -> dict[str, Path | None]:
    """Map each source name to its landed file for the run date, or None if absent."""
    found: dict[str, Path | None] = {}
    for name, spec in SOURCES.items():
        path = landing_dir / spec.filename(run_date)
        found[name] = path if path.is_file() else None
    return found
