"""Mock food-delivery Orders API (FastAPI).

Stands in for the order service of a Zomato/Swiggy-style platform so the
pipeline can demonstrate HTTP extraction. Currently exposes only the health
endpoint used by the Docker healthcheck; order endpoints are served by the
data generator.
"""

from fastapi import FastAPI

app = FastAPI(title="Food Orders Mock API", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness probe used by the container healthcheck."""
    return {"status": "ok"}
