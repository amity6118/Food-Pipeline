"""Data quality engine driven by food_control.dq_rules.

For each active rule of a stage, the engine wraps the rule's violation query
(one row per violation) to count violations and capture up to five samples,
then writes one dq_results row per rule. Outcome per rule:

    PASS   violations <= max_violations
    WARN   breached, severity WARN  -> logged, pipeline continues
    FAIL   breached, severity FAIL  -> pipeline stops (DataQualityError)

A staging FAIL also holds the batch back from all future warehouse loads until
it passes staging DQ again (see batch_hold); a warehouse FAIL stops the run and
alerts, as the rows are already loaded.

A rule whose SQL itself errors is recorded as FAIL: an unrunnable check is
not a passed check.
"""

import json
from dataclasses import dataclass
from typing import Any, Literal

from sqlalchemy import Connection, text
from sqlalchemy.exc import DBAPIError

from src.config import CONTROL_DB
from src.quality.batch_hold import hold_batch, release_batch
from src.utils.db import get_engine
from src.utils.job_log import job_run
from src.utils.logger import get_logger

logger = get_logger("src.quality")

Stage = Literal["STAGING", "WAREHOUSE"]
Outcome = Literal["PASS", "WARN", "FAIL"]
SAMPLE_SIZE = 5


class DataQualityError(Exception):
    """At least one FAIL-severity rule was breached."""


@dataclass(frozen=True)
class RuleResult:
    """Outcome of one rule for one batch."""

    rule_id: int
    rule_name: str
    severity: str
    violation_count: int
    outcome: Outcome
    samples: list[dict[str, Any]]


def evaluate_outcome(violation_count: int, max_violations: int, severity: str) -> Outcome:
    """PASS when within tolerance, otherwise the rule's severity (WARN or FAIL)."""
    if violation_count <= max_violations:
        return "PASS"
    return "FAIL" if severity == "FAIL" else "WARN"


def _run_rule(conn: Connection, rule: dict[str, Any], batch_id: str) -> RuleResult:
    query = rule["violation_query"]
    params = {"batch_id": batch_id}
    try:
        count = conn.execute(text(f"SELECT COUNT(*) FROM ({query}) AS violations"), params).scalar_one()
        samples = [dict(row) for row in conn.execute(
            text(f"SELECT * FROM ({query}) AS violations LIMIT {SAMPLE_SIZE}"), params).mappings()]
    except DBAPIError as exc:
        logger.error("DQ rule %s could not run: %s", rule["rule_name"], exc.orig)
        return RuleResult(rule["rule_id"], rule["rule_name"], rule["severity"], 0, "FAIL",
                          [{"rule_error": str(exc.orig)}])
    outcome = evaluate_outcome(count, rule["max_violations"], rule["severity"])
    return RuleResult(rule["rule_id"], rule["rule_name"], rule["severity"], count, outcome, samples)


def run_dq_checks(stage: Stage, batch_id: str) -> list[RuleResult]:
    """Run all active rules of `stage` for the batch and store the results.

    Results for the same batch and stage are replaced, so a re-run does not
    duplicate them.

    Raises:
        DataQualityError: If any FAIL-severity rule was breached.
    """
    with job_run(f"dq_{stage.lower()}", batch_id) as job:
        engine = get_engine(CONTROL_DB)
        with engine.connect() as conn:
            rules = conn.execute(
                text("SELECT rule_id, rule_name, severity, max_violations, violation_query "
                     "FROM dq_rules WHERE stage = :stage AND is_active = 1 ORDER BY rule_id"),
                {"stage": stage},
            ).mappings().all()
            results = [_run_rule(conn, dict(rule), batch_id) for rule in rules]

        with engine.begin() as conn:
            conn.execute(text("DELETE FROM dq_results WHERE batch_id = :batch_id AND stage = :stage"),
                         {"batch_id": batch_id, "stage": stage})
            if results:
                conn.execute(
                    text("INSERT INTO dq_results (batch_id, rule_id, rule_name, stage, severity, "
                         "violation_count, outcome, sample_violations) VALUES (:batch_id, :rule_id, "
                         ":rule_name, :stage, :severity, :violation_count, :outcome, :samples)"),
                    [{"batch_id": batch_id, "stage": stage, "rule_id": r.rule_id, "rule_name": r.rule_name,
                      "severity": r.severity, "violation_count": r.violation_count, "outcome": r.outcome,
                      "samples": json.dumps(r.samples, default=str) if r.samples else None}
                     for r in results],
                )

        for r in results:
            if r.outcome != "PASS":
                level = logger.error if r.outcome == "FAIL" else logger.warning
                level("DQ %s %s: %d violation(s)", r.outcome, r.rule_name, r.violation_count)
        failed = [r for r in results if r.outcome == "FAIL"]
        job.rows_read = len(results)
        job.rows_rejected = sum(r.outcome != "PASS" for r in results)
        logger.info("DQ %s: %d rules, %d passed, %d warned, %d failed", stage, len(results),
                    sum(r.outcome == "PASS" for r in results), sum(r.outcome == "WARN" for r in results),
                    len(failed))
        if failed:
            message = f"{len(failed)} FAIL rule(s) breached: {', '.join(r.rule_name for r in failed)}"
            if stage == "STAGING":
                hold_batch(batch_id, message)
            raise DataQualityError(message)
        if stage == "STAGING":
            release_batch(batch_id)
    return results
