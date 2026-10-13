"""Run-date parsing and batch ids."""

import argparse
from datetime import date, timedelta

import pytest

from src.utils.batch import make_batch_id, parse_run_date


def test_batch_id_is_deterministic_per_date():
    assert make_batch_id(date(2026, 10, 12)) == "B20261012"
    assert make_batch_id(date(2026, 10, 12)) == make_batch_id(date(2026, 10, 12))


def test_parse_run_date_accepts_iso_dates_and_today():
    assert parse_run_date("2026-03-02") == date(2026, 3, 2)
    assert parse_run_date("today") == date.today()


@pytest.mark.parametrize("value", ["2026-02-30", "12-10-2026", "yesterday"])
def test_parse_run_date_rejects_malformed_values(value):
    with pytest.raises(argparse.ArgumentTypeError, match="invalid date"):
        parse_run_date(value)


@pytest.mark.parametrize("value", ["2022-12-31", (date.today() + timedelta(days=1)).isoformat()])
def test_parse_run_date_rejects_dates_outside_calendar_or_in_future(value):
    with pytest.raises(argparse.ArgumentTypeError, match="must be between"):
        parse_run_date(value)
