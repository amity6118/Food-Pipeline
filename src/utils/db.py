"""SQLAlchemy engines for the pipeline databases (one cached engine per database)."""

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from src.config import MYSQL_HOST, MYSQL_PASSWORD, MYSQL_PORT, MYSQL_USER

_ENGINES: dict[str, Engine] = {}


def get_engine(database_name: str) -> Engine:
    """Return the cached engine for `database_name` (food_staging, food_control or food_dw).

    Raises:
        RuntimeError: If the ETL credentials are not configured.
    """
    if database_name not in _ENGINES:
        if not MYSQL_USER or not MYSQL_PASSWORD:
            raise RuntimeError("MYSQL_USER and MYSQL_PASSWORD must be set (copy .env.example to .env).")
        url = (f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@{MYSQL_HOST}:{MYSQL_PORT}/"
               f"{database_name}?charset=utf8mb4")
        # pre_ping drops connections MySQL has closed; recycle stays under wait_timeout
        _ENGINES[database_name] = create_engine(url, pool_pre_ping=True, pool_recycle=3600)
    return _ENGINES[database_name]
