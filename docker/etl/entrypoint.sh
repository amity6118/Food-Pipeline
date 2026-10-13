#!/usr/bin/env bash
set -e

echo "[ETL Entrypoint] Checking MySQL connectivity at ${MYSQL_HOST}:${MYSQL_PORT}..."

# Wait for MySQL to be ready using python socket check
python - <<'EOF'
import socket
import time
import os
import sys

host = os.getenv("MYSQL_HOST", "mysql")
port = int(os.getenv("MYSQL_PORT", 3306))
timeout = 60
start_time = time.time()

print(f"Waiting for MySQL at {host}:{port} to accept connections...")
while True:
    try:
        with socket.create_connection((host, port), timeout=2):
            print("Successfully connected to MySQL port!")
            sys.exit(0)
    except (socket.timeout, ConnectionRefusedError, OSError):
        if time.time() - start_time > timeout:
            print(f"ERROR: Timed out waiting for MySQL at {host}:{port} after {timeout} seconds.")
            sys.exit(1)
        time.sleep(2)
EOF

echo "[ETL Entrypoint] MySQL is ready. Executing pipeline command: $@"
exec "$@"
