"""Pluggable failure notifications.

Channels are chosen with ALERT_CHANNEL (comma-separated): `console` is always
active; `webhook` posts to ALERT_WEBHOOK_URL (Slack/Teams/Discord-compatible
JSON with a "text" field); `email` sends through SMTP_* settings. A broken
channel is logged and skipped, so alerting never masks the original failure.
"""

import json
import smtplib
import urllib.request
from email.message import EmailMessage
from typing import Protocol

from src import config
from src.utils.logger import get_logger

logger = get_logger("src.orchestration.notifier")


class Notifier(Protocol):
    """A destination for pipeline alerts."""

    def send(self, subject: str, body: str) -> None:
        """Deliver one alert."""


class ConsoleNotifier:
    """Writes the alert to the pipeline log (console + JSON file)."""

    def send(self, subject: str, body: str) -> None:
        logger.error("ALERT: %s\n%s", subject, body)


class WebhookNotifier:
    """POSTs {"text": ...} to an incoming-webhook URL."""

    def __init__(self, url: str) -> None:
        self.url = url

    def send(self, subject: str, body: str) -> None:
        request = urllib.request.Request(
            self.url,
            data=json.dumps({"text": f"*{subject}*\n{body}"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10):
            pass


class EmailNotifier:
    """Sends a plain-text email over SMTP with STARTTLS."""

    def __init__(self, host: str, port: int, user: str, password: str, sender: str, recipients: str) -> None:
        self.host, self.port = host, port
        self.user, self.password = user, password
        self.sender = sender
        self.recipients = [r.strip() for r in recipients.split(",") if r.strip()]

    def send(self, subject: str, body: str) -> None:
        message = EmailMessage()
        message["Subject"], message["From"], message["To"] = subject, self.sender, ", ".join(self.recipients)
        message.set_content(body)
        with smtplib.SMTP(self.host, self.port, timeout=15) as smtp:
            smtp.starttls()
            if self.user:
                smtp.login(self.user, self.password)
            smtp.send_message(message)


def build_notifiers() -> list[Notifier]:
    """Notifiers enabled by ALERT_CHANNEL; misconfigured channels are skipped with a warning."""
    channels = {c.strip().lower() for c in config.ALERT_CHANNEL.split(",") if c.strip()}
    notifiers: list[Notifier] = [ConsoleNotifier()]
    if "webhook" in channels:
        if config.ALERT_WEBHOOK_URL:
            notifiers.append(WebhookNotifier(config.ALERT_WEBHOOK_URL))
        else:
            logger.warning("ALERT_CHANNEL includes webhook but ALERT_WEBHOOK_URL is empty")
    if "email" in channels:
        if config.SMTP_HOST and config.ALERT_EMAIL_TO:
            notifiers.append(EmailNotifier(config.SMTP_HOST, config.SMTP_PORT, config.SMTP_USER,
                                           config.SMTP_PASSWORD, config.ALERT_EMAIL_FROM, config.ALERT_EMAIL_TO))
        else:
            logger.warning("ALERT_CHANNEL includes email but SMTP_HOST / ALERT_EMAIL_TO are not set")
    return notifiers


def notify_failure(subject: str, body: str, notifiers: list[Notifier] | None = None) -> None:
    """Send an alert through every configured channel, never raising."""
    for notifier in notifiers if notifiers is not None else build_notifiers():
        try:
            notifier.send(subject, body)
        except Exception as exc:  # alerting must not hide the pipeline failure
            logger.warning("%s failed to send alert: %s", type(notifier).__name__, exc)
