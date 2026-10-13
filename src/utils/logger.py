"""Structured logging module for the Food Order ETL pipeline."""

import logging
import sys
from pathlib import Path
from src.config import LOG_DIR, LOG_LEVEL

def get_logger(name: str) -> logging.Logger:
    """Returns a pre-configured logger with console and rotating file output.
    
    Args:
        name: Name of the module/component requesting the logger.
        
    Returns:
        logging.Logger instance configured with standardized formats.
    """
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger

    numeric_level = getattr(logging, LOG_LEVEL.upper(), logging.INFO)
    logger.setLevel(numeric_level)

    # Formatter with timestamp, level, module and message
    formatter = logging.Formatter(
        fmt="[%(asctime)s] [%(levelname)s] [%(name)s]: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # Console Handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    # File Handler
    log_file_path = LOG_DIR / "etl_pipeline.log"
    try:
        file_handler = logging.FileHandler(log_file_path, encoding="utf-8")
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    except Exception as exc:
        # Fallback to console only if file cannot be opened
        console_handler.setLevel(numeric_level)
        logger.warning(f"Failed to initialize file logger at {log_file_path}: {exc}")

    logger.propagate = False
    return logger
