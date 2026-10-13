"""Centralized configuration loader for the Food Order ETL Pipeline."""

import os
from pathlib import Path
from dotenv import load_dotenv

# Base paths
PROJECT_ROOT = Path(__file__).resolve().parent.parent
# Real environment variables (e.g. injected by Docker) take precedence over .env
load_dotenv(PROJECT_ROOT / ".env", override=False)

# MySQL Settings (credentials have no defaults; they must come from the environment)
MYSQL_HOST = os.getenv("MYSQL_HOST", "localhost")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", 3306))
MYSQL_USER = os.getenv("MYSQL_USER", "")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD", "")

# Database Names
STAGING_DB = os.getenv("STAGING_DB", "food_staging")
CONTROL_DB = os.getenv("CONTROL_DB", "food_control")
DW_DB = os.getenv("DW_DB", "food_dw")

# Host Ports
HOST_MYSQL_PORT = int(os.getenv("HOST_MYSQL_PORT", 3306))
HOST_ADMINER_PORT = int(os.getenv("HOST_ADMINER_PORT", 8080))
HOST_MOCK_API_PORT = int(os.getenv("HOST_MOCK_API_PORT", 8000))

# Mock API
MOCK_API_BASE_URL = os.getenv("MOCK_API_BASE_URL", "http://localhost:8000")

# Directories
DATA_LANDING_DIR = Path(os.getenv("DATA_LANDING_DIR", PROJECT_ROOT / "data" / "landing"))
DATA_ARCHIVE_DIR = Path(os.getenv("DATA_ARCHIVE_DIR", PROJECT_ROOT / "data" / "archive"))
DATA_ERROR_DIR = Path(os.getenv("DATA_ERROR_DIR", PROJECT_ROOT / "data" / "error"))
LOG_DIR = Path(os.getenv("LOG_DIR", PROJECT_ROOT / "logs"))

# Ensure directory trees exist
DATA_LANDING_DIR.mkdir(parents=True, exist_ok=True)
DATA_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
DATA_ERROR_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Alerts & Logging
ALERT_CHANNEL = os.getenv("ALERT_CHANNEL", "console")
ALERT_WEBHOOK_URL = os.getenv("ALERT_WEBHOOK_URL", "")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
