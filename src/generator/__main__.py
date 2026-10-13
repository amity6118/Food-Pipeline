"""Drop the daily master-data CSVs into the landing folder.

Usage:
    python -m src.generator --date 2026-10-13
    python -m src.generator                 # today

Orders are not written here: the ingestion step pulls them from the mock API.
"""

import argparse

from src.config import DATA_LANDING_DIR
from src.generator.master_data import write_master_csvs
from src.utils.batch import parse_run_date
from src.utils.logger import get_logger

logger = get_logger("src.generator")


def main() -> None:
    """Parse arguments and write the snapshot files."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--date", type=parse_run_date, default="today",
                        help="snapshot date, YYYY-MM-DD (default: today)")
    args = parser.parse_args()

    for path in write_master_csvs(args.date, DATA_LANDING_DIR):
        logger.info("Wrote %s", path.name)


if __name__ == "__main__":
    main()
