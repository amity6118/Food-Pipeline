"""Long-running scheduler for the etl container (APScheduler).

Runs the full pipeline for "today" on PIPELINE_CRON_SCHEDULE in
PIPELINE_TIMEZONE. A failed run has already been alerted on by run_pipeline,
so the scheduler logs it and waits for the next trigger instead of exiting.
"""

from datetime import datetime
from zoneinfo import ZoneInfo

from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger

from src.config import CALENDAR_END, CALENDAR_START, PIPELINE_CRON_SCHEDULE, PIPELINE_TIMEZONE, RUN_ON_STARTUP
from src.orchestration.pipeline import PipelineError, run_pipeline
from src.utils.logger import get_logger

logger = get_logger("src.orchestration.scheduler")


def scheduled_run() -> None:
    """One scheduled execution for the current local date."""
    run_date = datetime.now(ZoneInfo(PIPELINE_TIMEZONE)).date()
    if not CALENDAR_START <= run_date <= CALENDAR_END:
        logger.error("Skipping run: %s is outside the dim_date calendar (%s to %s)",
                     run_date, CALENDAR_START, CALENDAR_END)
        return
    try:
        run_pipeline(run_date)
    except PipelineError as exc:
        logger.error("Scheduled run failed: %s", exc)


def start_scheduler() -> None:
    """Block forever, running the pipeline on the configured cron schedule."""
    scheduler = BlockingScheduler(timezone=PIPELINE_TIMEZONE)
    trigger = CronTrigger.from_crontab(PIPELINE_CRON_SCHEDULE, timezone=PIPELINE_TIMEZONE)
    # coalesce + max_instances=1: never run two pipelines at once or replay missed runs in a burst
    job = scheduler.add_job(scheduled_run, trigger, id="daily_pipeline", coalesce=True, max_instances=1,
                            misfire_grace_time=3600)
    logger.info("Scheduler started: '%s' (%s); next run at %s", PIPELINE_CRON_SCHEDULE, PIPELINE_TIMEZONE,
                trigger.get_next_fire_time(None, datetime.now(ZoneInfo(PIPELINE_TIMEZONE))))
    if RUN_ON_STARTUP:
        job.modify(next_run_time=datetime.now(ZoneInfo(PIPELINE_TIMEZONE)))
    scheduler.start()
