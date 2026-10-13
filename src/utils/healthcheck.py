"""Connectivity check: verifies the ETL user can log in to every pipeline database.

Usage:
    python -m src.utils.healthcheck              # single check, exit code 0/1
    python -m src.utils.healthcheck --wait 90    # retry until MySQL is ready (container entrypoint)
"""

import argparse
import sys
import time

from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from src.config import CONTROL_DB, DW_DB, MYSQL_HOST, MYSQL_PORT, STAGING_DB
from src.utils.db import get_engine
from src.utils.logger import get_logger

logger = get_logger("src.utils.healthcheck")

PIPELINE_DATABASES = (STAGING_DB, CONTROL_DB, DW_DB)
RETRY_INTERVAL_SECONDS = 3


def check_databases() -> dict[str, int]:
    """Connect to each pipeline database and count its tables.

    Returns:
        Mapping of database name to number of tables it contains.

    Raises:
        OperationalError: If MySQL is unreachable or a login/database is invalid.
    """
    table_counts: dict[str, int] = {}
    for database in PIPELINE_DATABASES:
        with get_engine(database).connect() as conn:
            table_counts[database] = conn.execute(
                text("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = :db"),
                {"db": database},
            ).scalar_one()
    return table_counts


def main() -> int:
    """Run the check, optionally retrying until MySQL accepts connections."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--wait", type=int, default=0, metavar="SECONDS",
                        help="keep retrying for up to SECONDS before failing (default: no retry)")
    args = parser.parse_args()

    deadline = time.monotonic() + args.wait
    while True:
        try:
            table_counts = check_databases()
            break
        except OperationalError as exc:
            if time.monotonic() >= deadline:
                logger.error("MySQL at %s:%s is not reachable: %s", MYSQL_HOST, MYSQL_PORT, exc.orig)
                return 1
            logger.info("Waiting for MySQL at %s:%s ...", MYSQL_HOST, MYSQL_PORT)
            time.sleep(RETRY_INTERVAL_SECONDS)

    for database, count in table_counts.items():
        logger.info("%-13s OK (%d tables)", database, count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
