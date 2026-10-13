"""Centralized configuration for the Food Order ETL Pipeline.

Every setting is read from environment variables, with `.env` at the project
root as a fallback. Variables already set in the environment (for example by
Docker Compose) take precedence over `.env`, which is how the etl container
points MYSQL_HOST at the `mysql` service while host-side runs use `localhost`.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env", override=False)

# MySQL connection (credentials have no defaults; they must come from the environment)
MYSQL_HOST = os.getenv("MYSQL_HOST", "localhost")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", "3306"))
MYSQL_USER = os.getenv("MYSQL_USER", "")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD", "")

# Database names (must match the scripts in sql/init)
STAGING_DB = os.getenv("STAGING_DB", "food_staging")
CONTROL_DB = os.getenv("CONTROL_DB", "food_control")
DW_DB = os.getenv("DW_DB", "food_dw")

# Mock source API
MOCK_API_BASE_URL = os.getenv("MOCK_API_BASE_URL", "http://localhost:8000")

# File-drop directories, relative to the project root so the same code works
# on the Windows host and inside containers (where the root is /app)
DATA_LANDING_DIR = PROJECT_ROOT / "data" / "landing"
DATA_ARCHIVE_DIR = PROJECT_ROOT / "data" / "archive"
DATA_ERROR_DIR = PROJECT_ROOT / "data" / "error"
LOG_DIR = PROJECT_ROOT / "logs"

for _directory in (DATA_LANDING_DIR, DATA_ARCHIVE_DIR, DATA_ERROR_DIR, LOG_DIR):
    _directory.mkdir(parents=True, exist_ok=True)

# Logging & alerts
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
ALERT_CHANNEL = os.getenv("ALERT_CHANNEL", "console")
ALERT_WEBHOOK_URL = os.getenv("ALERT_WEBHOOK_URL", "")
