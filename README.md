# Food Order ETL Pipeline

**End-to-end data engineering project: a batch ETL pipeline for a simulated
food-delivery platform (in the style of Zomato / Swiggy), built with Python,
MySQL 8, Docker and Power BI.**

A seeded generator simulates the platform's order feed (served by a mock REST
API) and its daily master-data drops (CSV). Python extracts, validates and
bulk-loads everything into a raw staging layer. MySQL stored procedures cleanse
and transform it into a star-schema warehouse with SCD Type 2 history. Rule-driven
data quality checks gate each run, a scheduler runs the pipeline daily inside
Docker, and every step is logged to a control database for a Power BI
pipeline-health page.

---

## Table of contents

- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Data model](#data-model)
- [Key design decisions](#key-design-decisions)
- [Project structure](#project-structure)
- [Getting started (Windows + Docker Desktop)](#getting-started-windows--docker-desktop)
- [Running the pipeline](#running-the-pipeline)
- [Data quality](#data-quality)
- [Scheduling and alerts](#scheduling-and-alerts)
- [Testing and reconciliation](#testing-and-reconciliation)
- [Verifying the warehouse](#verifying-the-warehouse)
- [Connecting Power BI](#connecting-power-bi)
- [Suggested DAX measures](#suggested-dax-measures)
- [Suggested report pages](#suggested-report-pages)
- [What's built](#whats-built)
- [Future enhancements](#future-enhancements)

---

## Architecture

![Architecture: sources flow through Python ingestion, MySQL staging, stored-procedure ETL and the food_dw warehouse to Power BI, with orchestration, data quality and monitoring layers](docs/images/architecture.svg)

| Layer | Responsibility |
|---|---|
| **Sources** | Seeded Faker data (`en_IN`): customers, restaurants, menu items, delivery partners and payment methods as daily CSV snapshots; orders as JSON from a paginated mock API. Lunch/dinner peaks, weekend spikes, ~5% cancellations and ~2–3% deliberately dirty rows |
| **Ingestion** | Python package: extract (API + files) → structural validation → parse → idempotent bulk load into staging; files are archived or quarantined. No business logic |
| **Staging** | Raw copies as loose `VARCHAR` with `batch_id`, `source_file` and `loaded_at`; column profiles per batch; rows the procedures cannot load land in `stg_rejected_records` with a reason |
| **Processing** | One stored procedure per target table: cleansing functions, business rules, surrogate keys, SCD Type 2, watermark-based incremental upserts, job logging and `EXIT HANDLER` error handling |
| **Warehouse** | Star schema: 2 fact tables and 6 dimensions, every foreign key indexed |
| **Control** | Job and error logs, table-driven DQ rules and results, watermarks and settings, batch holds |
| **Orchestration** | `run_pipeline.py` runs the steps in order and stops at the first failure; APScheduler runs it daily in the `etl` container; failures alert via console, webhook or email |

📐 More diagrams (orchestration flow, ER diagram, container topology):
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**

---

## Tech stack

| Area | Tools |
|---|---|
| Language | Python 3.11 (type-hinted, modular packages) |
| Database | MySQL 8.0 (stored procedures, functions, star schema) |
| Data handling | pandas, SQLAlchemy 2, PyMySQL |
| Data generation | Faker (`en_IN` locale, seeded for reproducibility) |
| Mock source API | FastAPI + Uvicorn |
| Scheduling | APScheduler |
| Containers | Docker Compose (MySQL, ETL, mock API, Adminer) |
| Testing | pytest (unit + MySQL integration tests) |
| Reporting | Power BI Desktop |

---

## Data model

![food_dw star schema: fact_orders and fact_order_items joined to six dimensions](docs/images/star_schema.svg)

| Table | Grain / type | Notes |
|---|---|---|
| `fact_orders` | One row per order | Upsert on `order_id`. `net_amount = gross_amount - discount + delivery_fee`; `is_late` when delivery exceeds the SLA (45 min, in `pipeline_metadata`); `order_status` mapped to `DELIVERED` / `CANCELLED` / `REFUNDED`. CHECK constraints guard amounts and ratings |
| `fact_order_items` | One row per item per order | Unique on `(order_key, menu_item_key)`; `line_total = quantity × unit_price` |
| `dim_customer` | SCD Type 2 | `row_hash` detects changes; `valid_from` / `valid_to` / `is_current`; a generated-column unique key allows only one current row per customer. Facts join the version valid at order time |
| `dim_restaurant` | SCD Type 2 | Same SCD2 pattern (price-band changes, offboarding) |
| `dim_menu_item` | SCD Type 1 | Upsert on `item_id` |
| `dim_delivery_partner` | SCD Type 1 | Upsert on `partner_id` |
| `dim_payment_method` | SCD Type 1 | Upsert on `payment_method_id` |
| `dim_date` | One row per day, 2023–2027 | ISO weekday, `is_weekend`, `is_holiday` (national), `is_festival` (Holi, Id-ul-Fitr, Dussehra, Diwali, Christmas, New Year), driven by `ref_indian_holidays` |

---

## Key design decisions

- **Business logic lives in SQL, not pandas.** Python only moves data. Cleansing,
  business rules, surrogate keys and SCD2 run in stored procedures close to the
  data. Each procedure logs to `etl_job_log`, and a `DECLARE EXIT HANDLER FOR
  SQLEXCEPTION` rolls back, records the error and re-raises it.
- **Staging is lossless.** Every column is a `VARCHAR`, so a malformed value
  never breaks a load. Reusable SQL functions (`fn_to_datetime`, `fn_to_decimal`,
  `fn_clean_phone`, …) return NULL instead of failing, and the procedures decide
  whether to null a value or reject the row with a reason.
- **Incremental by watermark.** Each procedure processes only staging rows with
  `stg_id` above its watermark and advances the watermark in the same
  transaction as the data, so a failure never skips or double-loads rows.
- **Idempotent end to end.** The batch id is derived from the business date.
  Re-ingesting a date replaces its staging rows, facts upsert on their grain,
  and SCD2 only versions a row when its hash changes. Re-running a day leaves
  every count unchanged.
- **History that stays correct.** SCD2 batches are applied in date order with
  the business date as the effective date, a replayed older batch cannot
  rewrite newer history, and `--full-refresh` rebuilds all history from staging.
- **A DQ failure really stops bad data.** Rules are rows in `dq_rules`
  (`WARN` or `FAIL`). A staging `FAIL` stops the run *and* holds the batch back
  from all future loads until it passes; the hold is visible in `etl_batch_hold`.
- **Realistic, reproducible sources.** The same date always generates the same
  data. Value-changing defects (bad pincode, negative cost) stick to the same
  entities every day, so cleansing never creates false SCD2 versions.
- **Mock API over plain files.** Real platforms deliver orders over HTTP, so the
  pipeline pages through a FastAPI endpoint with retries; each response is landed
  as a file so it can be replayed.
- **No secrets in the repo; least privilege for reporting.** Credentials come
  only from `.env`. Power BI uses a `SELECT`-only user that cannot see staging.

---

## Project structure

```
food-order-pipeline/
├── run_pipeline.py             # CLI: run steps, backfill, full refresh, or start the scheduler
├── docker-compose.yml          # mysql, mock_api, etl (scheduler), adminer
├── .env.example                # copy to .env and set real passwords
├── requirements.txt            # exact pins for reproducible builds
├── pytest.ini
├── docs/
│   ├── ARCHITECTURE.md         # detailed diagrams
│   └── images/                 # architecture + star schema images
├── docker/
│   ├── etl/                    # ETL image (Python 3.11) + entrypoint that waits for MySQL
│   └── mock_api/               # FastAPI image
├── sql/
│   ├── init/                   # runs automatically on first MySQL boot, in order
│   │   ├── 01_create_databases.sql
│   │   ├── 02_create_staging_tables.sql
│   │   ├── 03_create_control_tables.sql
│   │   ├── 04_create_dw_tables.sql
│   │   ├── 05_create_cleansing_functions.sql
│   │   ├── 06_create_dim_date.sql          # holidays + sp_populate_dim_date
│   │   ├── 07_seed_control_data.sql        # watermarks, settings, DQ rule catalogue
│   │   ├── 08_procedures_control.sql       # job logging + watermark helpers
│   │   ├── 09_procedures_dimensions.sql    # sp_load_dim_* (SCD1 + SCD2)
│   │   ├── 10_procedures_facts.sql         # sp_load_fact_orders, sp_load_fact_order_items
│   │   ├── 11_procedures_orchestration.sql # sp_run_warehouse_load, sp_reset_warehouse
│   │   └── 99_create_app_users.sh          # ETL + Power BI users from .env
│   └── validation/
│       └── reconciliation.sql  # staging ↔ warehouse row-count reconciliation
├── src/
│   ├── config.py               # all settings from environment variables
│   ├── generator/              # seeded platform model, order stream, mock API
│   ├── ingestion/              # sources · extract · validate · parse · load · file_mover · runner
│   ├── processing/             # stored-procedure runner
│   ├── quality/                # DQ engine, staging profiler, batch holds
│   ├── orchestration/          # pipeline, scheduler, notifier
│   └── utils/                  # DB engine, structured logging, batch ids, job log, healthcheck
├── tests/                      # unit tests + MySQL integration tests
├── data/                       # landing/ → archive/<date>/ or error/<date>/
└── logs/                       # etl_pipeline.log (JSON lines, rotated)
```

---

## Getting started (Windows + Docker Desktop)

### Prerequisites

- Windows 10/11 with **Docker Desktop** (WSL 2 backend), running
- **Git**
- **Power BI Desktop** plus **MySQL Connector/NET 8.x** (needed by Power BI's MySQL connector)

### 1. Clone and configure

```powershell
git clone https://github.com/amity6118/Food-Pipeline.git
cd Food-Pipeline
Copy-Item .env.example .env
notepad .env
```

Replace every `change_me_*` value with your own password (no single quotes). If
a local MySQL server already uses port 3306, set both `HOST_MYSQL_PORT=3307` and
`MYSQL_PORT=3307`.

### 2. Build and start the stack

```powershell
docker compose up -d --build
docker compose ps
```

The first boot takes about a minute while MySQL runs its init scripts.

| Service | Status |
|---|---|
| `food_order_mysql` | Up (healthy) |
| `food_order_mock_api` | Up (healthy) |
| `food_order_adminer` | Up |
| `food_order_etl` | Up: the scheduler, waiting for the next run |

```powershell
docker compose logs etl
```

```
[...] [INFO] [src.utils.healthcheck] [-]: food_staging  OK (9 tables)
[...] [INFO] [src.utils.healthcheck] [-]: food_control  OK (6 tables)
[...] [INFO] [src.utils.healthcheck] [-]: food_dw       OK (9 tables)
[...] [INFO] [src.orchestration.scheduler] [-]: Scheduler started: '0 2 * * *' (Asia/Kolkata); next run at ...
```

### 3. Reset from scratch (optional)

The init scripts only run on the first boot of an empty volume:

```powershell
docker compose down -v
docker compose up -d --build
```

---

## Running the pipeline

Every run processes one **business date** (from 2023-01-01 up to today):

```
generate → ingest → dq_staging → load_dimensions → load_facts → dq_warehouse
```

```powershell
# Full pipeline for one date
docker compose run --rm etl python run_pipeline.py --date 2026-10-12

# Backfill a date range (each date in order, so SCD2 history builds correctly)
$d = [datetime]"2026-09-01"; while ($d -le [datetime]"2026-09-30") {
    docker compose run --rm etl python run_pipeline.py --date $d.ToString("yyyy-MM-dd"); $d = $d.AddDays(1) }

# Selected steps only (always executed in pipeline order)
docker compose run --rm etl python run_pipeline.py --date 2026-10-12 --step ingest --step dq_staging

# Empty the warehouse and rebuild it, including SCD2 history, from every staged batch
docker compose run --rm etl python run_pipeline.py --date 2026-10-12 --full-refresh --step load_dimensions --step load_facts
```

A successful run:

```
[B20261012]: Pipeline started for 2026-10-12: generate -> ingest -> dq_staging -> load_dimensions -> load_facts -> dq_warehouse
[B20261012]: Ingestion finished for 2026-10-12: 6 loaded, 0 missing, 0 failed
[B20261012]: DQ STAGING: 12 rules, 6 passed, 6 warned, 0 failed
[B20261012]: DQ WAREHOUSE: 8 rules, 6 passed, 2 warned, 0 failed
[B20261012]: Pipeline finished successfully for 2026-10-12
```

The exit code is 1 if any step fails; downstream steps are skipped and an alert
is sent. Each step can also run on its own:

| Command | What it does |
|---|---|
| `python -m src.generator --date D` | Drop the day's master-data CSVs into `data/landing` |
| `python -m src.ingestion --date D` | Pull orders from the API and load every landed file into staging. Loaded files move to `data/archive/<date>/`; invalid files to `data/error/<date>/` with a `.error.txt` reason |
| `CALL food_dw.sp_run_warehouse_load('B20261012')` | Run every load procedure in dependency order, directly in MySQL |

The mock API can be browsed at http://localhost:8000/docs, e.g.
http://localhost:8000/orders?date=2026-10-12&page=1&page_size=50.

---

## Data quality

`food_control.dq_rules` holds 20 rules. Each one is a SELECT returning one row
per violation, scoped to the batch with `:batch_id`:

| Stage | Examples | Severity |
|---|---|---|
| `STAGING` (before the procedures) | batch not empty, `order_id` not null | FAIL |
| | blank customer, impossible timestamp, gross amount ≤ 0, rating outside 1–5, duplicate orders, unknown customer, zero quantity, invalid pincode | WARN: expected row-level dirt that the procedures reject or cleanse |
| `WAREHOUSE` (after the procedures) | net amount formula, valid amounts, rating range, no future-dated orders | FAIL |
| | delivery minutes range, freshness, orders without items, line totals vs gross | WARN |

- Results (counts, outcome and up to five sample violations as JSON) go to `dq_results`.
- A staging `FAIL` stops the run and adds the batch to `etl_batch_hold`. Every
  load procedure skips held batches. When the batch passes staging DQ again (for
  example after a source fix and a re-run), the hold is released and its rows
  are re-queued for loading.
- Each batch is also profiled per column (row count, blanks, distinct values,
  min/max) into `food_staging.stg_column_profile`.
- Adding or tuning a rule is a data change: insert or update a row in `dq_rules`.

---

## Scheduling and alerts

The `etl` container runs `python run_pipeline.py --schedule`: APScheduler runs
the full pipeline for the current date on `PIPELINE_CRON_SCHEDULE` in
`PIPELINE_TIMEZONE` (default: daily at 02:00, Asia/Kolkata). Two pipelines never
overlap, and a failed run is alerted on and retried at the next trigger. Set
`RUN_ON_STARTUP=true` to also run once when the container starts.

Failure alerts go to every channel listed in `ALERT_CHANNEL`:

| Channel | Configuration |
|---|---|
| `console` (always on) | Logged as `ALERT: ...` to the console and the JSON log |
| `webhook` | `ALERT_WEBHOOK_URL` (Slack, Teams or Discord incoming webhook; posts `{"text": ...}`) |
| `email` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `ALERT_EMAIL_FROM`, `ALERT_EMAIL_TO` |

Logs are written as readable lines to the console and as JSON lines (with
`batch_id` and `step` on every record) to `logs/etl_pipeline.log`, rotated at 5 MB.

---

## Testing and reconciliation

```powershell
# All tests: 64 unit + integration tests (integration tests skip when MySQL is unreachable)
docker compose run --rm etl pytest

# Only the MySQL integration tests (run after at least one pipeline run)
docker compose run --rm etl pytest -m integration
```

| Test module | Covers |
|---|---|
| `test_generator.py` | Determinism, dirty-data rate (1.5–4.5%), cancellation rate, business rules in clean orders, local ordering, entity-stable defects |
| `test_ingestion.py` | CSV/JSON validation cases, raw parsing (whitespace kept, empty → NULL, items flattened), archive/quarantine |
| `test_orchestration.py` | DQ outcome rules, notifier wiring, step order, stop-on-failure and alerting |
| `test_batch.py` | Batch ids and run-date validation |
| `test_warehouse_integration.py` | SQL cleansing functions, net amount and SLA rules, status mapping, SCD2 integrity (one current version, gapless history), point-in-time keys, staged = loaded + rejected |

`sql/validation/reconciliation.sql` checks, per batch, that every staged order
and order item was either loaded or rejected, that every dimension key reached
the warehouse, and shows the latest runs with their DQ outcome:

```powershell
Get-Content sql/validation/reconciliation.sql | docker exec -i food_order_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table'
```

```
+-------------+-----------+--------+--------+----------+--------+
| target      | batch_id  | staged | loaded | rejected | status |
+-------------+-----------+--------+--------+----------+--------+
| fact_orders | B20261011 |    392 |    383 |        9 | OK     |
| fact_orders | B20261012 |    294 |    292 |        2 | OK     |
+-------------+-----------+--------+--------+----------+--------+
```

---

## Verifying the warehouse

After running the pipeline for a few dates, open a MySQL shell
(`docker exec -it food_order_mysql mysql -uroot -p`) and try:

```sql
-- Business rules hold on every order
SELECT COUNT(*) AS orders,
       SUM(ABS(net_amount - (gross_amount - discount + delivery_fee)) > 0.001) AS bad_net,   -- 0
       ROUND(AVG(is_late) * 100, 1) AS late_pct,
       ROUND(AVG(order_status = 'CANCELLED') * 100, 1) AS cancel_pct                         -- ~5
FROM food_dw.fact_orders;

-- SCD2 history: customers who relocated
SELECT customer_id, scd_version, city, valid_from, valid_to, is_current
FROM food_dw.dim_customer
WHERE customer_id IN (SELECT customer_id FROM food_dw.dim_customer WHERE scd_version > 1)
ORDER BY customer_id, scd_version;

-- Why rows were rejected
SELECT source_table, rejection_reason, COUNT(*) FROM food_staging.stg_rejected_records
GROUP BY source_table, rejection_reason;

-- Pipeline health
SELECT job_name, status, rows_read, rows_inserted, rows_updated, rows_rejected, duration_seconds
FROM food_control.etl_job_log ORDER BY job_id DESC LIMIT 15;

-- Calendar: 1826 days, 15 national holidays, 35 festival days
SELECT COUNT(*), SUM(is_holiday), SUM(is_festival) FROM food_dw.dim_date;
```

**Adminer** (browser UI): http://localhost:8080. Use System `MySQL`, Server
`mysql`, and the `etl_user` credentials from `.env`.

---

## Connecting Power BI

1. In Power BI Desktop, go to **Get Data → MySQL database**.
2. **Server:** `localhost:3306` (or the `HOST_MYSQL_PORT` you set). **Database:** `food_dw`.
3. **Data connectivity mode:** Import (recommended for this data volume).
4. On the credentials screen choose the **Database** tab and enter
   `POWERBI_USER` / `POWERBI_PASSWORD` from your `.env`.
5. Load the `fact_*` and `dim_*` tables. Power BI picks up the relationships from
   the foreign keys. Mark `dim_date` as the date table.
6. For the pipeline-health page, add a second MySQL source with database
   `food_control` (`etl_job_log`, `etl_error_log`, `dq_results`, `etl_batch_hold`).

If the connector reports a missing driver, install **MySQL Connector/NET** and
restart Power BI Desktop.

---

## Suggested DAX measures

Order status values are `DELIVERED`, `CANCELLED` and `REFUNDED`.

```dax
Total Orders = COUNTROWS ( fact_orders )

Delivered Orders =
CALCULATE ( [Total Orders], fact_orders[order_status] = "DELIVERED" )

GMV =
CALCULATE ( SUM ( fact_orders[gross_amount] ), fact_orders[order_status] = "DELIVERED" )

Net Revenue =
CALCULATE ( SUM ( fact_orders[net_amount] ), fact_orders[order_status] = "DELIVERED" )

AOV = DIVIDE ( [GMV], [Delivered Orders] )

Cancellation Rate =
DIVIDE (
    CALCULATE ( [Total Orders], fact_orders[order_status] = "CANCELLED" ),
    [Total Orders]
)

On-Time % =
DIVIDE (
    CALCULATE ( [Delivered Orders], fact_orders[is_late] = 0 ),
    [Delivered Orders]
)

Avg Rating = AVERAGE ( fact_orders[rating] )   -- blanks (unrated orders) are ignored

Repeat Customer % =
VAR CustomerOrders =
    ADDCOLUMNS (
        VALUES ( dim_customer[customer_id] ),     -- natural key, so SCD2 versions count once
        "@orders", CALCULATE ( COUNTROWS ( fact_orders ) )
    )
RETURN
    DIVIDE (
        COUNTROWS ( FILTER ( CustomerOrders, [@orders] > 1 ) ),
        COUNTROWS ( FILTER ( CustomerOrders, [@orders] > 0 ) )
    )
```

---

## Suggested report pages

| Page | Contents |
|---|---|
| **Executive Overview** | KPI cards (Total Orders, GMV, AOV, Cancellation Rate, On-Time %, Avg Rating), daily GMV trend, orders by city |
| **Sales** | GMV by month, weekday × hour heatmap (lunch/dinner peaks), payment-method mix, discount impact, festival vs. normal days |
| **Customers** | New vs. repeat customers, Repeat Customer %, top customers, orders by city/state, relocations (SCD2) |
| **Restaurants** | Top restaurants and cuisines by GMV, ratings vs. delivery time, top-selling menu items (from `fact_order_items`) |
| **Pipeline Health** | Runs per day by status, rows read/inserted/rejected per job, run duration trend, DQ outcomes by rule and severity, held batches (from `food_control`) |

---

## What's built

- [x] Docker Compose stack for Windows + Docker Desktop: MySQL 8, ETL scheduler, mock API, Adminer
- [x] Staging, control and warehouse databases with re-runnable DDL; read-only Power BI user
- [x] `dim_date` 2023–2027 with weekend, national-holiday and festival flags
- [x] Seeded data generator with realistic patterns and ~2–3% dirty data; paginated FastAPI order feed
- [x] Ingestion package: extract, validate, parse, idempotent bulk load, archive/quarantine
- [x] Stored procedures: cleansing functions, SCD1 and SCD2 dimensions, facts with business rules, watermarks, job logging and error handling
- [x] Table-driven DQ engine with WARN/FAIL severity, batch holds and staging profiling
- [x] `run_pipeline.py` with `--date`, `--step`, `--full-refresh`, `--schedule`; pluggable failure alerts
- [x] Structured JSON logging; full audit trail in `food_control`
- [x] 64 pytest tests (unit + MySQL integration) and a reconciliation script

## Next steps

1. **Build the Power BI report** with the five pages and measures above, then
   publish it to Power BI Service with a scheduled refresh through a gateway.
2. **Migrate orchestration to Apache Airflow:** one task per pipeline step,
   retries, backfills from the UI, and SLA alerting.
3. **Deploy to the cloud:** managed MySQL (AWS RDS / Azure Database for MySQL),
   the ETL image on ECS / Azure Container Apps, and secrets in a vault.

## Future enhancements

- **Apache Airflow** to replace APScheduler with DAG-based orchestration and a UI.
- **Apache Kafka** for streaming order events instead of daily batch drops.
- **Apache Spark** to transform at scale once volumes outgrow a single MySQL instance.
- **dbt** for version-controlled, tested SQL models alongside or instead of stored procedures.
- **CI/CD** with GitHub Actions: run pytest against a MySQL service container on every push.

---

## Author

**Amit Yadav** · [GitHub @amity6118](https://github.com/amity6118)
