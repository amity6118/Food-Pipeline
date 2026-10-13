"""Food Order ETL Pipeline: command-line entry point.

Examples:
    python run_pipeline.py                          # full pipeline for today
    python run_pipeline.py --date 2026-10-12        # full pipeline for one business date
    python run_pipeline.py --date 2026-10-12 --step ingest --step dq_staging
    python run_pipeline.py --date 2026-10-12 --full-refresh   # rebuild the warehouse from all staged batches
    python run_pipeline.py --schedule               # run forever on PIPELINE_CRON_SCHEDULE (etl container)

Exit code 0 on success, 1 if any step failed (an alert has been sent).
"""

import argparse
import sys

from src.orchestration.pipeline import STEPS, PipelineError, run_pipeline
from src.orchestration.scheduler import start_scheduler
from src.utils.batch import parse_run_date


def main() -> int:
    """Parse arguments and run the pipeline or the scheduler."""
    parser = argparse.ArgumentParser(description="Food Order ETL Pipeline",
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--date", type=parse_run_date, default="today",
                        help="business date to process, YYYY-MM-DD (default: today)")
    parser.add_argument("--step", action="append", choices=["all", *STEPS], metavar="STEP",
                        help=f"run only this step; repeatable. One of: all, {', '.join(STEPS)}")
    parser.add_argument("--full-refresh", action="store_true",
                        help="empty the warehouse and rebuild it from every staged batch before loading")
    parser.add_argument("--schedule", action="store_true",
                        help="start the long-running scheduler instead of a single run")
    args = parser.parse_args()

    if args.schedule:
        start_scheduler()
        return 0

    steps = None if not args.step or "all" in args.step else args.step
    try:
        run_pipeline(args.date, steps=steps, full_refresh=args.full_refresh)
    except PipelineError as exc:
        print(f"\n{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
