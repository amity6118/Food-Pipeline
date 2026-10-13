"""Ingestion step: extract -> validate -> parse -> load for one run date.

Every file is processed independently and logged as its own job in
food_control.etl_job_log. A file that fails validation or parsing is moved to
data/error and reported as FAILED, while the remaining files still load. A
database error is not the file's fault, so it propagates without moving the file.
"""

from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Literal

from src.ingestion.extract import discover_files, fetch_orders
from src.ingestion.file_mover import archive_file, quarantine_file
from src.ingestion.load import load_to_staging
from src.ingestion.parse import parse_file
from src.ingestion.sources import SOURCES
from src.ingestion.validate import validate_file
from src.utils.batch import make_batch_id
from src.utils.job_log import job_run
from src.utils.logger import get_logger

logger = get_logger("src.ingestion")


@dataclass
class FileResult:
    """Outcome of ingesting one source."""

    source: str
    status: Literal["LOADED", "MISSING", "FAILED"]
    path: Path | None = None
    rows: dict[str, int] = field(default_factory=dict)
    error: str | None = None


@dataclass
class IngestionSummary:
    """Outcome of an ingestion run."""

    batch_id: str
    results: list[FileResult]

    @property
    def failed(self) -> list[FileResult]:
        """Sources that must be fixed before the pipeline can continue."""
        return [r for r in self.results if r.status == "FAILED"]


def _ingest_file(source: str, path: Path, run_date: date, batch_id: str) -> FileResult:
    spec = SOURCES[source]
    try:
        with job_run(f"ingest_{source}", batch_id) as job:
            validate_file(path, spec)
            frames = parse_file(path, spec)
            job.rows_read = sum(len(frame) for frame in frames.values())
            rows = load_to_staging(frames, batch_id, path.name)
            job.rows_inserted = sum(rows.values())
    except ValueError as exc:  # ValidationError, malformed CSV/JSON, bad encoding
        target = quarantine_file(path, run_date, str(exc))
        logger.error("%s rejected (%s); moved to %s", path.name, exc, target.parent)
        return FileResult(source, "FAILED", target, error=str(exc))

    archived = archive_file(path, run_date)
    logger.info("%s loaded %s; archived", path.name, rows)
    return FileResult(source, "LOADED", archived, rows)


def run_ingestion(run_date: date, fetch_from_api: bool = True) -> IngestionSummary:
    """Ingest all source files for `run_date` into staging.

    Args:
        run_date: Business date being processed.
        fetch_from_api: Pull orders from the mock API first; set False to use
            an orders file that was dropped into data/landing by other means.
    """
    batch_id = make_batch_id(run_date)
    logger.info("Ingestion started for %s (batch %s)", run_date, batch_id)

    if fetch_from_api:
        with job_run("extract_orders_api", batch_id) as job:
            _, job.rows_read = fetch_orders(run_date)

    results = []
    for source, path in discover_files(run_date).items():
        if path is not None:
            results.append(_ingest_file(source, path, run_date, batch_id))
        elif SOURCES[source].required:
            logger.error("Required file %s is missing", SOURCES[source].filename(run_date))
            results.append(FileResult(source, "FAILED", error="required file not found in landing"))
        else:
            logger.warning("No %s file for %s; that dimension keeps its current data", source, run_date)
            results.append(FileResult(source, "MISSING"))

    summary = IngestionSummary(batch_id, results)
    logger.info("Ingestion finished for %s: %d loaded, %d missing, %d failed", run_date,
                sum(r.status == "LOADED" for r in results), sum(r.status == "MISSING" for r in results),
                len(summary.failed))
    return summary
