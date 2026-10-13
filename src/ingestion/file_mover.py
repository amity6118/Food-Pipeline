"""Move landed files out of data/landing once they have been handled.

Loaded files go to data/archive/<run date>/; files that failed validation go to
data/error/<run date>/ together with a `<file>.error.txt` explaining why.
"""

import shutil
from datetime import date, datetime
from pathlib import Path

from src.config import DATA_ARCHIVE_DIR, DATA_ERROR_DIR


def _move(path: Path, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / path.name
    target.unlink(missing_ok=True)  # a re-run replaces the earlier copy
    shutil.move(str(path), target)
    return target


def archive_file(path: Path, run_date: date) -> Path:
    """Move a successfully loaded file to the archive."""
    return _move(path, DATA_ARCHIVE_DIR / run_date.isoformat())


def quarantine_file(path: Path, run_date: date, reason: str) -> Path:
    """Move a rejected file to the error folder and record the reason beside it."""
    target = _move(path, DATA_ERROR_DIR / run_date.isoformat())
    target.with_name(f"{target.name}.error.txt").write_text(
        f"rejected_at: {datetime.now():%Y-%m-%d %H:%M:%S}\nreason: {reason}\n", encoding="utf-8")
    return target
