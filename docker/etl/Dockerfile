# ETL worker image: Python 3.11 runtime for ingestion, DQ checks and orchestration.
FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# tzdata lets logs and the scheduler honour PIPELINE_TIMEZONE (e.g. Asia/Kolkata)
RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first, so code edits don't invalidate this cached layer
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Run as an unprivileged user
RUN useradd --create-home --uid 1000 etl \
    && mkdir -p data/landing data/archive data/error logs \
    && chown -R etl:etl /app
USER etl

# Invoked through bash so the script works even if a Windows checkout drops the exec bit
ENTRYPOINT ["bash", "/app/docker/etl/entrypoint.sh"]
CMD ["python", "-m", "src.utils.healthcheck"]
