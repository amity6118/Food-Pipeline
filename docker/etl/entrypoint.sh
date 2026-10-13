#!/usr/bin/env bash
# Entrypoint for the ETL container: wait until the ETL user can log in to every
# pipeline database, then hand over to the container command.
set -euo pipefail

python -m src.utils.healthcheck --wait "${DB_WAIT_SECONDS:-90}"

exec "$@"
