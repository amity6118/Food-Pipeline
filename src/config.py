"""Centralized configuration for the Food Order ETL Pipeline.

Every setting is read from environment variables, with `.env` at the project
root as a fallback. Variables already set in the environment (for example by
Docker Compose) take precedence over `.env`, which is how the etl container
points MYSQL_HOST at the `mysql` service while host-side runs use `localhost`.
"""

import os
from datetime import date
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

# Calendar covered by dim_date; run dates and generated data must fall inside it
CALENDAR_START = date(2023, 1, 1)
CALENDAR_END = date(2027, 12, 31)

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

# Scheduling
PIPELINE_CRON_SCHEDULE = os.getenv("PIPELINE_CRON_SCHEDULE", "0 2 * * *")
PIPELINE_TIMEZONE = os.getenv("PIPELINE_TIMEZONE", "Asia/Kolkata")
RUN_ON_STARTUP = os.getenv("RUN_ON_STARTUP", "false").lower() == "true"

# Logging & failure alerts
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
ALERT_CHANNEL = os.getenv("ALERT_CHANNEL", "console")  # comma list: console,webhook,email
ALERT_WEBHOOK_URL = os.getenv("ALERT_WEBHOOK_URL", "")
SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
ALERT_EMAIL_FROM = os.getenv("ALERT_EMAIL_FROM", "")
ALERT_EMAIL_TO = os.getenv("ALERT_EMAIL_TO", "")
