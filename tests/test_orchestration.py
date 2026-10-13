"""DQ outcome rules, notifier wiring and pipeline step control (database calls stubbed out)."""

from contextlib import contextmanager
from datetime import date

import pytest

from src import config
from src.orchestration import notifier, pipeline
from src.quality.dq_engine import evaluate_outcome


# -- data quality outcome ------------------------------------------------------
@pytest.mark.parametrize("violations, tolerated, severity, expected", [
    (0, 0, "FAIL", "PASS"),
    (3, 5, "FAIL", "PASS"),
    (1, 0, "WARN", "WARN"),
    (1, 0, "FAIL", "FAIL"),
    (6, 5, "FAIL", "FAIL"),
])
def test_dq_outcome(violations, tolerated, severity, expected):
    assert evaluate_outcome(violations, tolerated, severity) == expected


# -- notifier --------------------------------------------------------------------
def test_console_is_always_on_and_misconfigured_channels_are_skipped(monkeypatch):
    monkeypatch.setattr(config, "ALERT_CHANNEL", "console,webhook,email")
    monkeypatch.setattr(config, "ALERT_WEBHOOK_URL", "https://hooks.example.test/x")
    monkeypatch.setattr(config, "SMTP_HOST", "")
    kinds = [type(n).__name__ for n in notifier.build_notifiers()]
    assert kinds == ["ConsoleNotifier", "WebhookNotifier"]  # email skipped: no SMTP_HOST


def test_a_failing_channel_does_not_stop_the_others():
    delivered = []

    class Broken:
        def send(self, subject, body):
            raise ConnectionError("webhook down")

    class Recorder:
        def send(self, subject, body):
            delivered.append(subject)

    notifier.notify_failure("subject", "body", notifiers=[Broken(), Recorder()])
    assert delivered == ["subject"]


# -- pipeline control --------------------------------------------------------------
@pytest.fixture
def fake_pipeline(monkeypatch):
    """Replace every step and side effect with recorders."""
    calls, alerts = [], []

    @contextmanager
    def no_job_log(job_name, batch_id):
        yield

    monkeypatch.setattr(pipeline, "job_run", no_job_log)
    monkeypatch.setattr(pipeline, "_record_success", lambda batch_id: calls.append("record_success"))
    monkeypatch.setattr(pipeline, "reset_warehouse", lambda batch_id: calls.append("reset"))
    monkeypatch.setattr(pipeline, "notify_failure", lambda subject, body: alerts.append(subject))
    monkeypatch.setattr(pipeline, "STEPS", {name: (lambda ctx, name=name: calls.append(name))
                                            for name in pipeline.STEPS})
    return calls, alerts


def test_steps_run_in_pipeline_order_and_success_is_recorded(fake_pipeline):
    calls, _ = fake_pipeline
    pipeline.run_pipeline(date(2026, 3, 2))
    assert calls == [*pipeline.STEPS, "record_success"]


def test_selected_steps_keep_pipeline_order_and_do_not_record_success(fake_pipeline):
    calls, _ = fake_pipeline
    pipeline.run_pipeline(date(2026, 3, 2), steps=["load_facts", "ingest"], full_refresh=True)
    assert calls == ["reset", "ingest", "load_facts"]


def test_failure_stops_downstream_steps_and_alerts(fake_pipeline, monkeypatch):
    calls, alerts = fake_pipeline

    def broken_step(ctx):
        raise RuntimeError("boom")

    monkeypatch.setitem(pipeline.STEPS, "dq_staging", broken_step)
    with pytest.raises(pipeline.PipelineError, match="dq_staging"):
        pipeline.run_pipeline(date(2026, 3, 2))
    assert calls == ["generate", "ingest"]
    assert alerts == ["[food-order-pipeline] B20260302 failed at step 'dq_staging'"]
