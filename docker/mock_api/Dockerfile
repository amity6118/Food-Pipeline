# Mock Orders API image: serves simulated food-delivery orders over HTTP (FastAPI + Uvicorn).
FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY src/ ./src/

# Run as an unprivileged user
RUN useradd --create-home --uid 1000 api \
    && mkdir -p data logs \
    && chown -R api:api /app
USER api

EXPOSE 8000

CMD ["uvicorn", "src.generator.mock_api:app", "--host", "0.0.0.0", "--port", "8000"]
