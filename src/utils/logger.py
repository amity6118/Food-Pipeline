"""Structured logging: readable lines on the console, JSON lines in logs/etl_pipeline.log.

Every record carries the current run context (batch_id, step), set with
`log_context(...)`, so a whole run can be filtered from the JSON log:

    with log_context(batch_id="B20261012", step="ingest"):
        logger.info("Loaded %d rows", n)
"""

import json
import logging
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime
from logging.handlers import RotatingFileHandler

from src.config import LOG_DIR, LOG_LEVEL

LOG_FILE = LOG_DIR / "etl_pipeline.log"
_ROOT_LOGGER = "src"
_context: ContextVar[dict[str, str]] = ContextVar("log_context", default={})


class _ContextFilter(logging.Filter):
    """Copies the current run context onto each record."""

    def filter(self, record: logging.LogRecord) -> bool:
        context = _context.get()
        record.batch_id = context.get("batch_id", "-")
        record.step = context.get("step", "-")
        return True


class _JsonFormatter(logging.Formatter):
    """One JSON object per line, ready for log tooling or ad-hoc jq/pandas analysis."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(record.created).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "batch_id": record.batch_id,
            "step": record.step,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def _configure_root() -> logging.Logger:
    root = logging.getLogger(_ROOT_LOGGER)
    if root.handlers:
        return root
    root.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.INFO))
    root.propagate = False
    context_filter = _ContextFilter()

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(logging.Formatter(
        "[%(asctime)s] [%(levelname)s] [%(name)s] [%(batch_id)s]: %(message)s", datefmt="%Y-%m-%d %H:%M:%S"))
    console.addFilter(context_filter)
    root.addHandler(console)

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(LOG_FILE, maxBytes=5_000_000, backupCount=5, encoding="utf-8")
    file_handler.setFormatter(_JsonFormatter())
    file_handler.addFilter(context_filter)
    root.addHandler(file_handler)
    return root


def get_logger(name: str) -> logging.Logger:
    """Logger for a module under the shared `src` configuration (pass a `src.*` name)."""
    _configure_root()
    return logging.getLogger(name)


@contextmanager
def log_context(**values: str) -> Iterator[None]:
    """Attach key/value context (e.g. batch_id, step) to every log record in the block."""
    token = _context.set({**_context.get(), **values})
    try:
        yield
    finally:
        _context.reset(token)
