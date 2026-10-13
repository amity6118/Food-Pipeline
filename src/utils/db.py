"""Database connection manager and helper utilities using SQLAlchemy and PyMySQL."""

from typing import Dict, Any, Optional
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine, Connection
from src.config import (
    MYSQL_HOST,
    MYSQL_PORT,
    MYSQL_USER,
    MYSQL_PASSWORD,
    STAGING_DB,
    CONTROL_DB,
    DW_DB,
)
from src.utils.logger import get_logger

logger = get_logger("src.utils.db")

_ENGINES: Dict[str, Engine] = {}

def get_engine(database_name: str) -> Engine:
    """Returns a cached SQLAlchemy Engine instance for the requested database.
    
    Args:
        database_name: Database name (food_staging, food_control, or food_dw).
        
    Returns:
        SQLAlchemy Engine.
    """
    if database_name not in _ENGINES:
        if not MYSQL_USER or not MYSQL_PASSWORD:
            raise RuntimeError(
                "MYSQL_USER and MYSQL_PASSWORD must be set (copy .env.example to .env)."
            )
        # PyMySQL connection URL
        url = (
            f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@"
            f"{MYSQL_HOST}:{MYSQL_PORT}/{database_name}?"
            f"charset=utf8mb4"
        )
        _ENGINES[database_name] = create_engine(
            url,
            pool_size=10,
            max_overflow=20,
            pool_recycle=3600,
            pool_pre_ping=True,
            echo=False
        )
        logger.debug(f"Created connection engine for database: {database_name} on {MYSQL_HOST}:{MYSQL_PORT}")
    return _ENGINES[database_name]

def execute_query(database_name: str, sql: str, params: Optional[Dict[str, Any]] = None):
    """Executes a SQL statement with optional parameters and returns the raw result.
    
    Args:
        database_name: Target database.
        sql: SQL query or statement string.
        params: Optional dictionary of query parameters.
    """
    engine = get_engine(database_name)
    with engine.begin() as conn:
        return conn.execute(text(sql), params or {})

def fetch_one(database_name: str, sql: str, params: Optional[Dict[str, Any]] = None):
    """Fetches a single row result from a query."""
    engine = get_engine(database_name)
    with engine.connect() as conn:
        result = conn.execute(text(sql), params or {})
        return result.fetchone()

def fetch_all(database_name: str, sql: str, params: Optional[Dict[str, Any]] = None):
    """Fetches all rows as a list of mappings/tuples."""
    engine = get_engine(database_name)
    with engine.connect() as conn:
        result = conn.execute(text(sql), params or {})
        return result.fetchall()
