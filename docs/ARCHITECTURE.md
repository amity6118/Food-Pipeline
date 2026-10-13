# Architecture — Food Order ETL Pipeline

This document describes how data moves from simulated food-delivery sources
through a MySQL staging layer, stored-procedure transformations and a star-schema
warehouse, to Power BI. It also covers orchestration, data quality and the
Docker runtime topology.

## 1. End-to-end data flow

![Food Order ETL Pipeline Architecture](images/architecture.svg)

```mermaid
flowchart LR
    subgraph SRC["1 · SOURCES"]
        GEN["Python + Faker generator<br/>(seeded, en_IN)"]
        API["Mock Orders API<br/>FastAPI :8000<br/>GET /orders?date=YYYY-MM-DD"]
        CSV["CSV master data<br/>customers · restaurants<br/>menu_items · delivery_partners<br/>payment_methods"]
        GEN --> API
        GEN --> CSV
    end

    subgraph ING["2 · INGESTION (src/ingestion)"]
        EX["extract.py<br/>pull API JSON → landing<br/>pick up CSVs"]
        VA["validate.py<br/>schema · columns · empty file"]
        PA["parse.py<br/>flatten JSON → orders + items"]
        LO["load.py<br/>pandas + SQLAlchemy bulk insert<br/>stamp batch_id / source_file"]
        EX --> VA --> PA --> LO
    end

    subgraph STG["3 · STAGING (food_staging)"]
        RAW["stg_* tables<br/>loose VARCHAR + audit cols"]
        REJ["stg_rejected_records"]
    end

    subgraph PROC["4 · PROCESSING (stored procedures)"]
        DIMP["sp_load_dim_*<br/>cleanse · SCD2 · upsert"]
        FACTP["sp_load_fact_*<br/>business rules · SK lookup<br/>watermark incremental"]
        DIMP --> FACTP
    end

    subgraph DW["5 · WAREHOUSE (food_dw)"]
        STAR["Star schema<br/>2 facts + 6 dims"]
    end

    subgraph CTL["6 · CONTROL (food_control)"]
        JOB["etl_job_log · etl_error_log"]
        DQ["dq_rules · dq_results"]
        META["pipeline_metadata<br/>(watermarks)"]
    end

    PBI["9 · Power BI Desktop<br/>(Windows host, localhost:3306)<br/>read-only user"]

    API --> EX
    CSV --> EX
    LO --> RAW
    VA -. bad files .-> ERRDIR["data/error"]
    LO -. done .-> ARCH["data/archive"]
    RAW --> DIMP
    DIMP -. bad rows .-> REJ
    FACTP -. bad rows .-> REJ
    FACTP --> STAR
    DIMP --> STAR
    PROC --> JOB
    PROC <--> META
    STAR --> PBI
    CTL --> PBI
```

## 2. Orchestration and control flow

```mermaid
flowchart TD
    SCHED["APScheduler in etl container<br/>cron from PIPELINE_CRON_SCHEDULE"] --> RUN
    CLI["python run_pipeline.py<br/>--date · --step · --full-refresh"] --> RUN
    RUN["run_pipeline.py<br/>creates batch_id"] --> S1["generate / extract"]
    S1 --> S2["ingest → staging"]
    S2 --> S3["DQ checks (staging rules)"]
    S3 -->|FAIL severity| STOP
    S3 -->|pass / WARN| S4["sp_load_dim_* (dependency order)"]
    S4 --> S5["sp_load_fact_orders → sp_load_fact_order_items"]
    S5 --> S6["DQ checks (warehouse rules)"]
    S6 -->|FAIL| STOP
    S6 -->|pass| OK["advance watermark<br/>job_log = SUCCESS"]
    STOP["halt pipeline<br/>job_log = FAILED"] --> NOTIFY["Notifier<br/>console + webhook / email (env vars)"]
```

- Each step writes a `RUNNING` row to `etl_job_log`, then updates it to `SUCCESS` or `FAILED`.
- Every stored procedure declares `DECLARE EXIT HANDLER FOR SQLEXCEPTION`. The handler rolls back, marks the job `FAILED` and writes the error to `etl_error_log`.
- If a step fails, none of the steps after it run.

## 3. Warehouse star schema

```mermaid
erDiagram
    dim_date ||--o{ fact_orders : date_key
    dim_customer ||--o{ fact_orders : customer_key
    dim_restaurant ||--o{ fact_orders : restaurant_key
    dim_delivery_partner ||--o{ fact_orders : delivery_partner_key
    dim_payment_method ||--o{ fact_orders : payment_method_key
    fact_orders ||--o{ fact_order_items : order_key
    dim_menu_item ||--o{ fact_order_items : menu_item_key

    fact_orders {
        bigint order_key PK
        varchar order_id UK
        int date_key FK
        decimal gross_amount
        decimal discount
        decimal delivery_fee
        decimal net_amount "gross - discount + fee"
        int delivery_minutes
        tinyint is_late "minutes > 45"
        decimal rating
        varchar order_status "mapped"
    }
    fact_order_items {
        bigint order_item_key PK
        bigint order_key FK
        int menu_item_key FK
        int quantity
        decimal unit_price
        decimal line_total
    }
    dim_customer {
        int customer_key PK
        varchar customer_id "SCD2"
        datetime valid_from
        datetime valid_to
        tinyint is_current
    }
    dim_restaurant {
        int restaurant_key PK
        varchar restaurant_id "SCD2"
    }
```

| Table | Grain | Notes |
|---|---|---|
| `fact_orders` | One row per order | Upserted on `order_id` |
| `fact_order_items` | One row per item per order | Replaced per order on reload |
| `dim_customer`, `dim_restaurant` | One row per version | SCD Type 2 (`valid_from`, `valid_to`, `is_current`) |
| `dim_menu_item`, `dim_delivery_partner`, `dim_payment_method` | One row per natural key | SCD Type 1 upsert |
| `dim_date` | One row per day, 2023–2027 | Weekend and Indian festival flags |

All foreign keys and `date_key` are indexed.

## 4. Layer responsibilities

| Layer | Owns | Never does |
|---|---|---|
| **Sources** | Seeded fake data: lunch/dinner peaks, more orders on weekends, ~5% cancellations, ~2–3% dirty rows | — |
| **Ingestion** (Python) | Extract, structural validation, flatten JSON, bulk load, move files to archive or error | Business logic or type conversion |
| **Staging** (`food_staging`) | Raw copies as VARCHAR with `batch_id`, `source_file`, `loaded_at`; deduplication; rejected rows | Enforcing types |
| **Processing** (stored procedures) | Trim and cast, `net_amount`, `is_late`, status mapping, surrogate keys, SCD2, upserts | — |
| **Warehouse** (`food_dw`) | Typed star schema with indexes on every foreign key | — |
| **Control** (`food_control`) | Job and error logs, DQ rules and results, watermarks | — |
| **Data quality** | Runs the SQL in `dq_rules` (null, range, referential, freshness checks) and writes `dq_results`. `WARN` logs and continues; `FAIL` stops the run | — |
| **Reporting** | Power BI on `food_dw` (business pages) and `food_control` (pipeline health), using a SELECT-only user | Reading staging |

### Idempotency

- Each run date gets a predictable `batch_id`.
- Staging rows are deleted by `batch_id` before that batch is reloaded.
- Facts are upserted on the natural key (`order_id`). Order items are deleted and reinserted per order.
- SCD2 adds a new dimension version only when the hash of the tracked attributes changes.

As a result, running the same date again leaves row counts unchanged.

## 5. Runtime topology (Docker Desktop on Windows)

```mermaid
flowchart LR
    subgraph HOST["Windows host"]
        PBI2["Power BI Desktop"]
        BROWSER["Browser"]
    end
    subgraph NET["docker network: pipeline_net"]
        MYSQL[("mysql:8.0<br/>:3306<br/>volume mysql_data<br/>init: ./sql/init")]
        MOCK["mock_api<br/>FastAPI :8000"]
        ETL["etl (python:3.11)<br/>APScheduler + run_pipeline.py"]
        ADM["adminer :8080"]
    end
    ETL --> MYSQL
    ETL --> MOCK
    ADM --> MYSQL
    PBI2 -->|localhost:3306| MYSQL
    BROWSER -->|localhost:8080| ADM
    BROWSER -->|localhost:8000/docs| MOCK
```

### Why a mock API instead of plain JSON files

Real aggregator platforms deliver orders over HTTP, so pulling them from an
endpoint is a more realistic extraction pattern. The API serves orders for a
given date from a fixed seed, so repeated calls return the same data. The
extract step saves each response to `data/landing/orders_<date>.json`, which
keeps ingestion file-based and makes every raw payload replayable.

## 6. Folder layout

```
food-order-pipeline/
├── docker-compose.yml
├── .env.example  .gitignore  .gitattributes  requirements.txt  README.md
├── run_pipeline.py                  # CLI orchestrator
├── docs/
│   └── ARCHITECTURE.md
├── docker/
│   ├── etl/       Dockerfile  entrypoint.sh
│   └── mock_api/  Dockerfile
├── sql/
│   ├── init/                        # runs once on first MySQL boot
│   │   01_create_databases.sql           02_create_staging_tables.sql
│   │   03_create_control_tables.sql      04_create_dw_tables.sql
│   │   05_create_cleansing_functions.sql 06_create_dim_date.sql
│   │   07_seed_control_data.sql          08_procedures_dimensions.sql
│   │   09_procedures_facts.sql           10_procedure_master.sql
│   │   99_create_app_users.sh            # users from .env, runs last
│   └── validation/
│       reconciliation.sql           # staging ↔ DW row counts
├── src/
│   ├── config.py
│   ├── utils/         db.py  logger.py  batch.py  job_log.py  healthcheck.py
│   ├── generator/     reference_data.py  master_data.py  orders.py  mock_api.py
│   ├── ingestion/     sources.py  extract.py  validate.py  parse.py  load.py
│   │                  file_mover.py  runner.py
│   ├── processing/    procedure_runner.py
│   ├── quality/       dq_engine.py
│   └── orchestration/ pipeline.py  scheduler.py  notifier.py
├── tests/
│   conftest.py  test_validate.py  test_parse.py  test_dq_engine.py  test_transformations.py
├── data/   landing/  archive/  error/
└── logs/
```

## 7. Out of scope for v1

Airflow, Kafka and Spark are left out on purpose to keep v1 small. Possible
upgrades are listed under "Future Enhancements" in the README.
