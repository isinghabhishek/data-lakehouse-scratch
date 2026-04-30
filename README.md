# Data Lakehouse from Scratch

A fully open-source, locally-runnable data lakehouse built with Apache Iceberg, Project Nessie, Trino, dbt Core, and MinIO. The project implements the Medallion architecture (Bronze → Silver → Gold) and demonstrates ACID transactions, time travel, schema evolution, and catalog branching — all on a developer laptop with no cloud dependencies.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Developer Machine                        │
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐   ┌──────────┐  │
│  │  Source  │    │  Trino   │    │  dbt     │   │  Nessie  │  │
│  │  Files   │    │ :8080    │    │  Core    │   │  :19120  │  │
│  │data/raw/ │    │          │    │          │   │          │  │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘   └────┬─────┘  │
│       │               │               │               │        │
│       │    ┌──────────┴───────────────┘               │        │
│       │    │           SQL / REST                      │        │
│       ▼    ▼                                           │        │
│  ┌─────────────────────────────────────────────────┐  │        │
│  │              Apache Iceberg Layer               │◄─┘        │
│  │  (table format: metadata + data file tracking)  │           │
│  └─────────────────────┬───────────────────────────┘           │
│                        │                                        │
│                        ▼                                        │
│  ┌─────────────────────────────────────────────────┐           │
│  │           MinIO  :9000 / :9001                  │           │
│  │   s3://lakehouse/bronze/  silver/  gold/        │           │
│  │   (Parquet data files + Iceberg metadata JSON)  │           │
│  └─────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

## Tech Stack

| Component | Version | Role |
|-----------|---------|------|
| Apache Iceberg | Latest | Open table format — ACID, time travel, schema evolution |
| Project Nessie | Latest | Git-like catalog — branching, versioning, tagging |
| Trino | 435 | Distributed SQL query engine |
| dbt Core | 1.8.3 | SQL transformation framework |
| dbt-trino | 1.8.1 | dbt adapter for Trino |
| MinIO | Latest | S3-compatible local object storage |
| Docker Compose | v2 | Local service orchestration |

## Prerequisites

- **Docker Desktop** (or Docker Engine + Docker Compose v2)
- **Python 3.10+**
- **Git**
- **8 GB RAM** minimum, 4 CPU cores recommended
- **~5 GB free disk space**

## Quickstart

1. Clone the repository:
   ```bash
   git clone <repo-url>
   cd data-lakehouse-from-scratch
   ```

2. Copy the environment template:
   ```bash
   cp .env.example .env
   ```

3. Start all services:
   ```bash
   make up
   ```

4. Wait until all services are healthy:
   ```bash
   make status
   ```

5. Download the sample dataset (NYC Yellow Taxi, January 2024, ~3M rows):
   ```bash
   make download-data
   ```

6. Install Python dependencies for the ingestion script:
   ```bash
   pip install -r scripts/requirements.txt
   ```

7. Ingest the CSV into the Bronze Iceberg table:
   ```bash
   make ingest
   ```

8. Install dbt and its dependencies:
   ```bash
   pip install -r dbt/requirements.txt
   cd dbt && dbt deps
   cd ..
   ```

9. Run the Silver transformation models:
   ```bash
   make run-silver
   ```

10. Run the Gold aggregation models:
    ```bash
    make run-gold
    ```

11. Run dbt data quality tests:
    ```bash
    make test
    ```

12. Explore the results:
    - **Trino UI**: http://localhost:8080
    - **MinIO Console**: http://localhost:9001 (user: `minioadmin`, password: `minioadmin`)

## Project Structure

```
.
├── data/
│   └── raw/                    # Source CSV files (gitignored)
├── dbt/
│   ├── dbt_project.yml         # dbt project config
│   ├── profiles.yml            # Trino connection profile
│   ├── packages.yml            # dbt package dependencies
│   └── models/
│       ├── silver/             # Cleaning & typing models
│       └── gold/               # Aggregation models
├── scripts/
│   ├── ingest_bronze.py        # Bronze ingestion script
│   ├── download_sample_data.sh # Sample data downloader
│   ├── demo_acid.sh            # ACID demo
│   ├── demo_time_travel.sh     # Time travel demo
│   ├── demo_schema_evolution.sh# Schema evolution demo
│   ├── demo_branching.sh       # Nessie branching demo
│   └── benchmark.sh            # Query benchmark runner
├── trino/
│   └── etc/
│       ├── catalog/
│       │   └── iceberg.properties  # Iceberg+Nessie catalog config
│       ├── config.properties   # Trino coordinator config
│       ├── jvm.config          # JVM settings
│       └── node.properties     # Node identity
├── tests/                      # Property-based tests (pytest + Hypothesis)
├── docker-compose.yml          # Service definitions
├── Makefile                    # Task runner
├── .env.example                # Environment variable template
└── README.md
```

## Data Pipeline

Data flows through three Medallion layers, each stored as Iceberg tables in MinIO and tracked by the Nessie catalog.

**Bronze — Raw Ingestion**
The ingestion script (`scripts/ingest_bronze.py`) reads source CSV files from `data/raw/` and writes them into `iceberg.bronze.yellow_taxi_raw` via Trino. All columns are stored as `VARCHAR` — no type casting, no filtering. Each run appends a new Iceberg snapshot, preserving the full ingestion history. The table is partitioned by ingestion day.

**Silver — Cleaning and Conforming**
The dbt Silver model (`models/silver/stg_yellow_taxi.sql`) reads from Bronze and applies type casting (timestamps, integers, decimals), computes a surrogate `trip_id` via MD5 hash, removes rows with null primary keys, and deduplicates using a window function. dbt tests assert `not_null` and `unique` on `trip_id`.

**Gold — Aggregation and Business Metrics**
Two Gold models aggregate Silver data into analyst-ready tables:
- `gold.daily_trip_summary` — trip counts, average fare, average distance, and total revenue by calendar date
- `gold.vendor_performance` — trip counts, average tip percentage, and average passenger count by vendor and month

## Demo Scripts

| Script | Make Target | What it demonstrates |
|--------|-------------|---------------------|
| `demo_acid.sh` | `make demo-acid` | Concurrent INSERTs, final row count == sum of both |
| `demo_time_travel.sh` | `make demo-time-travel` | `FOR VERSION AS OF` and `FOR TIMESTAMP AS OF` queries |
| `demo_schema_evolution.sh` | `make demo-schema-evolution` | ADD / RENAME / DROP COLUMN without data rewrite |
| `demo_branching.sh` | `make demo-branching` | Create branch → write → isolate → merge → verify |

Each script exits non-zero on assertion failure, making them usable as acceptance tests.

## Benchmarks

Run the benchmark suite against the Gold tables:

```bash
make bench
```

This executes three representative SQL queries against `gold.daily_trip_summary` and `gold.vendor_performance`, records wall-clock execution time per query, and writes the results to `benchmark_results.md`. Each query should complete within 60 seconds on a machine meeting the prerequisites.

The `benchmark_results.md` file documents query text, execution time, and row count for each benchmark run.

## Environment Variables

All variables are defined in `.env.example`. Copy it to `.env` before starting services.

| Variable | Default | Description |
|----------|---------|-------------|
| `MINIO_ROOT_USER` | `minioadmin` | MinIO root username (acts as the S3 access key) |
| `MINIO_ROOT_PASSWORD` | `minioadmin` | MinIO root password (acts as the S3 secret key) |
| `MINIO_API_PORT` | `9000` | Host port for the MinIO S3-compatible API |
| `MINIO_CONSOLE_PORT` | `9001` | Host port for the MinIO web console |
| `NESSIE_PORT` | `19120` | Host port for the Nessie catalog REST API |
| `TRINO_PORT` | `8080` | Host port for the Trino query engine and web UI |

## Port Reference

| Service | Port | Purpose |
|---------|------|---------|
| MinIO API | 9000 | S3-compatible object storage API |
| MinIO Console | 9001 | Web UI for browsing buckets and objects |
| Nessie | 19120 | Iceberg catalog REST API |
| Trino | 8080 | SQL query engine + web UI |

## Troubleshooting

**Services not healthy after `make up`**
Run `make status` to see per-service health. If services are still starting, wait 30–60 seconds and check again. If they remain unhealthy, increase Docker's memory allocation to at least 8 GB in Docker Desktop settings.

**Trino can't connect to Nessie**
Verify Nessie is healthy (`docker compose ps nessie`). Check that `trino/etc/catalog/iceberg.properties` has the correct URI (`http://nessie:19120/api/v1`). Trino and Nessie must be on the same Docker network (`lakehouse-net`).

**MinIO bucket not created**
The `minio-init` container handles bucket creation. Check its logs:
```bash
docker compose logs minio-init
```
If it exited with an error, run `make reset` to restart with clean volumes.

**`make ingest` fails with "file not found"**
The source CSV must exist at `data/raw/yellow_taxi_2024_01.csv`. Run `make download-data` first to fetch it.

**Port conflicts**
If another service is already using a required port, override it in `.env`:
```dotenv
MINIO_API_PORT=9010
MINIO_CONSOLE_PORT=9011
NESSIE_PORT=19121
TRINO_PORT=8081
```
Then run `make reset` to restart with the new ports.

## Learning Resources

- [Apache Iceberg Documentation](https://iceberg.apache.org/docs/latest/)
- [Project Nessie Documentation](https://projectnessie.org/docs/)
- [Trino Documentation](https://trino.io/docs/current/)
- [dbt Core Documentation](https://docs.getdbt.com/)
- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)
