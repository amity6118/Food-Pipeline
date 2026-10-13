FROM python:3.11-slim-bullseye

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Kolkata

# Install system dependencies (curl and default-mysql-client for connectivity testing)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create necessary directories
RUN mkdir -p /app/data/landing /app/data/archive /app/data/error /app/logs

# Copy project files
COPY . .

# Set execution permissions on entrypoint script
RUN chmod +x /app/docker/etl/entrypoint.sh

ENTRYPOINT ["/app/docker/etl/entrypoint.sh"]
CMD ["python", "run_pipeline.py", "--step", "all"]
