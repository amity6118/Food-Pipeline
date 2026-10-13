"""Run-date and batch-id helpers shared by the pipeline steps."""

import argparse
from datetime import date

from src.config import CALENDAR_END, CALENDAR_START


def make_batch_id(run_date: date) -> str:
    """Batch id for a run date, e.g. 2026-10-13 -> "B20261013".

    The id is derived from the date (not a timestamp or UUID) on purpose:
    re-running a date reuses the same batch id, so every step can replace that
    batch's rows instead of appending duplicates.
    """
    return f"B{run_date:%Y%m%d}"


def parse_run_date(value: str) -> date:
    """argparse type for run dates: "YYYY-MM-DD" or "today", within the simulation range."""
    try:
        run_date = date.today() if value == "today" else date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid date {value!r}; expected YYYY-MM-DD") from exc
    if not CALENDAR_START <= run_date <= CALENDAR_END:
        raise argparse.ArgumentTypeError(f"date must be between {CALENDAR_START} and {CALENDAR_END}")
    return run_date
