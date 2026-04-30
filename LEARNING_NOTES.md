# Learning Notes — Data Lakehouse from Scratch

These notes document the key concepts I worked through while building this project. They're written for my own reference and for anyone reviewing the portfolio — the goal is to capture the *why* behind each design decision, not just the *what*.

---

## 1. Apache Iceberg Internals

### The Snapshot Model

The most important mental model for Iceberg is that a table is not a directory of files — it's a sequence of **snapshots**. Each snapshot is a complete, immutable description of the table's state at a point in time. When you INSERT, UPDATE, or DELETE, Iceberg doesn't modify existing files; it writes new data files and creates a new snapshot that points to the current set of files.

This is what makes time travel and ACID semantics possible without a lock manager. Readers always see a consistent snapshot. Writers create a new snapshot atomically. There's no shared mutable state to coordinate.

The metadata chain looks like this:

```
metadata.json
  └── manifest-list (one per snapshot)
        └── manifest-file (one per data file group)
              └── data-file (Parquet, ORC, or Avro)
```

- **`metadata.json`** is the table's root. It records the schema history, partition spec, and a pointer to the current snapshot. Every schema change or write produces a new `metadata.json`.
- **Manifest list** is a file that lists all the manifest files belonging to a snapshot. It also stores partition-level statistics (min/max values per partition) that Trino uses for partition pruning.
- **Manifest file** lists the actual data files in a subset of the table, along with column-level statistics (null counts, min/max values). These statistics are what make predicate pushdown fast — Trino can skip entire files without reading them.
- **Data files** are the Parquet files on MinIO. They're never modified in place.

This chain is why time travel is cheap: querying a historical snapshot just means pointing the reader at an older manifest list. No data is copied or rewritten.

### Metadata File Structure

A simplified `metadata.json` looks like this:

```json
{
  "format-version": 2,
  "table-uuid": "...",
  "location": "s3://lakehouse/bronze/yellow_taxi_raw",
  "current-snapshot-id": 8765432109876543210,
  "schemas": [{ "schema-id": 0, "fields": [...] }],
  "current-schema-id": 0,
  "snapshots": [
    {
      "snapshot-id": 1234567890123456789,
      "timestamp-ms": 1700000000000,
      "manifest-list": "s3://lakehouse/.../snap-1234-manifest-list.avro"
    },
    {
      "snapshot-id": 8765432109876543210,
      "timestamp-ms": 1700001000000,
      "manifest-list": "s3://lakehouse/.../snap-8765-manifest-list.avro"
    }
  ]
}
```

The key insight: the `snapshots` array grows with every write, but old snapshots are never deleted (until you run `EXPIRE SNAPSHOTS`). This is what makes the full history queryable.

### Why Parquet + Iceberg > Plain Parquet

Raw Parquet files on S3 give you columnar storage and compression, but nothing else. You can't do ACID writes, you can't time travel, and schema changes require rewriting every file. Iceberg adds:

- **ACID semantics** via optimistic concurrency control on the metadata layer
- **Time travel** via the snapshot chain
- **Schema evolution** without data rewrites (add/rename/drop columns are metadata-only operations)
- **Partition evolution** — you can change how a table is partitioned without rewriting data
- **Hidden partitioning** — Iceberg tracks partition values in metadata, so queries don't need to know the partition scheme
- **Statistics-based pruning** — manifest-level min/max stats let the query engine skip files before reading them

The storage format (Parquet) handles efficient columnar reads. Iceberg handles everything above the file level.

---

## 2. Project Nessie — Git for Data

### How Nessie Differs from Hive Metastore

The Hive Metastore (HMS) is the traditional catalog for Hadoop-era data lakes. It works, but it has fundamental limitations:

- **No branching**: HMS has a single mutable namespace. Every table change is immediately visible to all readers.
- **No versioning**: There's no history of what the catalog looked like at a previous point in time.
- **Mutable state**: Table metadata is stored in a relational database (usually MySQL or PostgreSQL). Concurrent writes can corrupt state.
- **No atomic multi-table operations**: You can't atomically rename two tables or move a set of tables from one schema to another.

Nessie solves all of these by treating the catalog as a **commit log**, exactly like Git treats a repository. Every table creation, schema change, or drop is a commit on a branch. The catalog's state at any point in time is fully reproducible by replaying the commit log up to that point.

### The Branching Model

Nessie branches work exactly like Git branches:

1. **Create a branch** from `main` — the new branch starts with the same table state as `main` at that moment.
2. **Write to the branch** — dbt runs, ingestion scripts, or manual SQL statements create new commits on the branch. `main` is completely unaffected.
3. **Inspect the branch** — you can query tables on the branch, run dbt tests, validate data quality, all in isolation.
4. **Merge to main** — once you're satisfied, merge the branch. All commits from the branch are replayed onto `main` atomically.

This is enormously useful for dbt workflows. Instead of running `dbt run` directly against production tables, you run it on a feature branch, validate the output, and only merge when the results are correct. If something goes wrong, you just delete the branch — `main` is untouched.

The Trino session property that controls which branch you're on:

```sql
SET SESSION iceberg.nessie_reference_name = 'feature/silver-v2';
```

### Nessie vs Delta Lake vs Iceberg REST Catalog

| Catalog | Branching | Open Standard | Persistence |
|---------|-----------|---------------|-------------|
| Nessie | Yes (Git-like) | Yes (REST API) | Embedded RocksDB or external DB |
| Delta Lake | No (single timeline) | Partially | Delta log on object storage |
| Iceberg REST Catalog | No branching in spec | Yes (REST API) | Implementation-dependent |

Nessie is the only option that gives you true Git-like branching. The trade-off is operational complexity — you're running another service. For a local dev environment, that's a reasonable cost.

---

## 3. dbt + Trino Integration

### How dbt-trino Works

dbt is fundamentally a SQL compiler and runner. You write models as `SELECT` statements, and dbt wraps them in `CREATE TABLE AS` or `INSERT OVERWRITE` statements depending on the materialisation strategy. The `dbt-trino` adapter translates dbt's abstract model execution into Trino-specific SQL.

When you run `dbt run --select silver`, the sequence is:

1. dbt reads `stg_yellow_taxi.sql` and compiles it into a full `CREATE TABLE ... AS SELECT ...` statement
2. The adapter sends that SQL to Trino via the Trino Python client
3. Trino executes the query, reading from `iceberg.bronze.yellow_taxi_raw` and writing to `iceberg.silver.yellow_taxi`
4. Because the catalog is `iceberg` and the connector is configured with Nessie, Trino creates an Iceberg table tracked by Nessie

The materialisation `table` in `dbt_project.yml` is what causes dbt to create a full Iceberg table rather than a view. This matters because Iceberg tables have snapshots, statistics, and partition metadata — views don't.

### Adapter Quirks

A few things that aren't obvious from the dbt docs:

**Session properties for Nessie branch**: To run dbt against a non-`main` branch, you set the `nessie_reference_name` session property in `profiles.yml` or via `--vars`. The adapter passes this as a Trino session property at connection time.

**`method: none` for local dev**: The `dbt-trino` adapter supports several authentication methods. For local development against a Trino instance with no authentication configured, `method: none` is the correct choice. Using `ldap` or `certificate` will cause connection failures.

**DECIMAL precision**: Trino is strict about DECIMAL precision in arithmetic. When computing `tip_amount / fare_amount`, you need explicit casts to avoid precision errors. The Silver model uses `CAST(... AS DECIMAL(10,2))` throughout.

**`TRY_CAST` for resilience**: Bronze data is all VARCHAR. Some rows have empty strings or non-numeric values in numeric columns. Using `TRY_CAST` instead of `CAST` returns NULL for unparseable values rather than failing the entire query. This is the right default for a Silver cleaning layer.

### Surrogate Key Strategy in Silver

The Silver model computes `trip_id` as an MD5 hash of the raw VARCHAR columns that together identify a unique trip. The reason for using raw VARCHAR columns (before casting) is **stability**: the hash is computed on the source values exactly as they appear in Bronze, so the same source data always produces the same `trip_id`, regardless of when the Silver model runs or what type casting rules change in the future.

This is a deliberate trade-off. A natural key (e.g., a combination of vendor_id + pickup_datetime + dropoff_datetime) would be more readable, but it requires those columns to be non-null and correctly typed. The MD5 surrogate key works even when individual columns are null, as long as the concatenated string is unique — and it's deterministic, which is what matters for deduplication.

---

## 4. Medallion Architecture Decisions

### Why All-VARCHAR Bronze

The Bronze layer's job is to be a **faithful, immutable copy of the source**. That means no type assumptions, no filtering, no transformation. Every column is stored as VARCHAR.

This might seem wasteful — why not cast timestamps to TIMESTAMP at ingestion time? The answer is that source data is unreliable. The NYC Taxi CSV has rows with malformed timestamps, empty strings in numeric columns, and values that don't match the documented schema. If you cast at ingestion time, malformed rows either fail silently (with TRY_CAST returning NULL) or fail loudly (with CAST raising an error). Either way, you've lost the original value.

By storing everything as VARCHAR, Bronze is a lossless archive. If the Silver casting logic has a bug, you can fix it and re-run Silver from Bronze without re-ingesting the source. If the source schema changes, Bronze absorbs the change gracefully — new columns just appear as new VARCHAR columns.

This also protects against **schema drift**. If the source adds a column next month, the ingestion script picks it up automatically. If it renames a column, you have the original name in Bronze and can update the Silver mapping without losing history.

### Silver as the Trust Boundary

Silver is where data becomes trustworthy. The Silver model applies:

- **Type casting**: VARCHAR → TIMESTAMP, INTEGER, DECIMAL, etc.
- **Deduplication**: `ROW_NUMBER() OVER (PARTITION BY trip_id ORDER BY _ingested_at DESC) = 1` keeps the most recent version of each trip
- **Null filtering**: Rows where `trip_id IS NULL` are dropped — these are rows where the source data was so malformed that a surrogate key couldn't be computed
- **dbt tests**: `not_null(trip_id)` and `unique(trip_id)` run after every Silver model execution

The dbt test strategy is important. Tests run *after* the model materialises, which means they validate the actual output, not just the SQL logic. If a Silver run produces duplicate `trip_id` values (which would indicate a bug in the deduplication logic), the test catches it and `dbt test` exits non-zero.

### Gold as the Semantic Layer

Gold models are materialised as Iceberg tables, not views. This is a deliberate choice that trades storage cost for query performance.

A view would be cheaper to maintain — no storage, always up to date. But every time an analyst queries a view, Trino has to re-execute the full aggregation against Silver. For a dataset with millions of rows, that's seconds of compute per query.

Pre-aggregated Gold tables mean analysts get sub-second responses on common queries. The trade-off is that Gold tables are only as fresh as the last `dbt run --select gold`. For a portfolio project (and for most batch analytics use cases), that's acceptable. The pipeline runs on a schedule, and analysts know the data is current as of the last run.

The two Gold models reflect different analytical perspectives on the same Silver data:
- `daily_trip_summary` answers time-series questions: "How did trip volume and revenue trend over January?"
- `vendor_performance` answers entity-level questions: "Which vendor had the highest tip percentage?"

Both are pre-computed because these are the queries analysts run most often, and they're the most expensive to compute on the fly.

---

## 5. Key Takeaways

- **Iceberg's value is in the metadata layer, not the file format.** Parquet is just the storage format. The snapshot chain, manifest files, and column statistics are what make Iceberg a table format rather than just a collection of files.

- **Nessie makes dbt safer.** Running dbt on a feature branch means you can validate transformations in isolation before they affect production tables. This is the data engineering equivalent of a pull request.

- **All-VARCHAR Bronze is not laziness — it's a design principle.** Deferring type decisions to Silver means Bronze is always recoverable. You can fix Silver logic and replay from Bronze without touching the source system.

- **Surrogate keys should be stable, not just unique.** An MD5 hash of source VARCHAR columns is deterministic across runs, which is what makes deduplication reliable. A sequence number or UUID would be unique but not stable.

- **Pre-aggregated Gold tables are a deliberate performance trade-off.** The cost is storage and pipeline latency. The benefit is analyst query performance. For batch analytics, this trade-off almost always makes sense.

- **Docker Compose health checks are essential for a multi-service stack.** Without `depends_on: condition: service_healthy`, Trino starts before Nessie is ready and fails to connect. Health checks make the startup sequence deterministic.

- **Property-based testing is the right tool for data pipeline correctness.** Unit tests verify specific examples. Property tests verify that invariants hold across all possible inputs — which is exactly what you need when the input space is "any CSV file" or "any set of concurrent writes."
