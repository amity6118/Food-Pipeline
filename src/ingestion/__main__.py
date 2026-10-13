"""Load one day's source files into food_staging.

Usage:
    python -m src.ingestion --date 2026-10-13
    python -m src.ingestion --date 2026-10-13 --skip-api   # use an orders file already in data/landing

Exit code 1 if any file failed, so a scheduler can stop downstream steps.
"""

import argparse
import sys

from src.ingestion.extract import ExtractError
from src.ingestion.runner import run_ingestion
from src.utils.batch import parse_run_date


def main() -> int:
    """Run ingestion and print a per-file summary."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--date", type=parse_run_date, default="today",
                        help="business date to ingest, YYYY-MM-DD (default: today)")
    parser.add_argument("--skip-api", action="store_true",
                        help="do not call the mock API; expect orders_<date>.json in data/landing")
    args = parser.parse_args()

    try:
        summary = run_ingestion(args.date, fetch_from_api=not args.skip_api)
    except ExtractError as exc:  # already logged with its traceback in etl_error_log
        print(f"\nIngestion aborted: {exc}", file=sys.stderr)
        return 1

    print(f"\nBatch {summary.batch_id}")
    for result in summary.results:
        detail = ", ".join(f"{table}={rows}" for table, rows in result.rows.items()) or result.error or ""
        print(f"  {result.source:<18} {result.status:<8} {detail}")
    return 1 if summary.failed else 0


if __name__ == "__main__":
    sys.exit(main())
