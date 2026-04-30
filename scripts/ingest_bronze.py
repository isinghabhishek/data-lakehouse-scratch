#!/usr/bin/env python3
"""
ingest_bronze.py — Ingest a CSV file into an Iceberg Bronze table via Trino.

Usage:
    python scripts/ingest_bronze.py [--source <path>] [--table <name>] [--branch <name>]
"""

import argparse
import glob
import logging
import os
import sys

import pandas as pd
import trino.dbapi

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BATCH_SIZE = 500


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Ingest a CSV file into an Iceberg Bronze table via Trino."
    )
    parser.add_argument(
        "--source",
        default=None,
        help="Path to the CSV file. Defaults to the first .csv found in data/raw/.",
    )
    parser.add_argument(
        "--table",
        default="yellow_taxi_raw",
        help="Iceberg table name in the bronze schema (default: yellow_taxi_raw).",
    )
    parser.add_argument(
        "--branch",
        default="main",
        help="Nessie branch to write to (default: main).",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Source file resolution
# ---------------------------------------------------------------------------
def resolve_source(source: str | None) -> str:
    if source is not None:
        return source
    matches = sorted(glob.glob("data/raw/*.csv"))
    if not matches:
        log.error("No CSV file found in data/raw/ and --source was not provided.")
        sys.exit(1)
    return matches[0]


# ---------------------------------------------------------------------------
# CSV reading
# ---------------------------------------------------------------------------
def read_csv(path: str) -> pd.DataFrame:
    try:
        df = pd.read_csv(path, dtype=str)
        log.info("Source file: %s  |  rows: %d  |  columns: %d", path, len(df), len(df.columns))
        return df
    except Exception as exc:
        log.error("Failed to read CSV file '%s': %s", path, exc)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Trino connection
# ---------------------------------------------------------------------------
def connect_trino(branch: str) -> trino.dbapi.Connection:
    host = os.environ.get("TRINO_HOST", "localhost")
    port = int(os.environ.get("TRINO_PORT", "8080"))
    try:
        conn = trino.dbapi.connect(
            host=host,
            port=port,
            user="ingest",
            catalog="iceberg",
            schema="bronze",
            http_scheme="http",
        )
        cur = conn.cursor()
        cur.execute(f"SET SESSION iceberg.nessie_reference_name = '{branch}'")
        cur.fetchall()
        log.info("Connected to Trino at %s:%d (branch: %s)", host, port, branch)
        return conn
    except Exception as exc:
        log.error("Failed to connect to Trino at %s:%d: %s", host, port, exc)
        sys.exit(1)


# ---------------------------------------------------------------------------
# DDL helpers
# ---------------------------------------------------------------------------
def ensure_schema(cursor: trino.dbapi.Cursor) -> None:
    cursor.execute("CREATE SCHEMA IF NOT EXISTS iceberg.bronze")
    cursor.fetchall()


def ensure_table(cursor: trino.dbapi.Cursor, table: str, columns: list[str]) -> None:
    col_defs = ",\n    ".join(f'"{col}" VARCHAR' for col in columns)
    ddl = f"""CREATE TABLE IF NOT EXISTS iceberg.bronze.{table} (
    {col_defs},
    _ingested_at TIMESTAMP(6),
    _source_file VARCHAR
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(_ingested_at)']
)"""
    cursor.execute(ddl)
    cursor.fetchall()
    log.info("Table iceberg.bronze.%s is ready.", table)


# ---------------------------------------------------------------------------
# Row value formatting
# ---------------------------------------------------------------------------
def format_value(val) -> str:
    """Return a SQL literal for a single cell value."""
    if val is None or (isinstance(val, float) and pd.isna(val)):
        return "NULL"
    # Escape single quotes by doubling them
    escaped = str(val).replace("'", "''")
    return f"'{escaped}'"


def build_insert(table: str, columns: list[str], batch: pd.DataFrame, source_filename: str) -> str:
    """Build a single INSERT … VALUES statement for a batch of rows."""
    escaped_filename = source_filename.replace("'", "''")
    rows_sql = []
    for _, row in batch.iterrows():
        col_vals = ", ".join(format_value(row[col]) for col in columns)
        rows_sql.append(f"({col_vals}, CURRENT_TIMESTAMP, '{escaped_filename}')")
    values_clause = ",\n    ".join(rows_sql)
    col_list = ", ".join(f'"{c}"' for c in columns) + ", _ingested_at, _source_file"
    return f"INSERT INTO iceberg.bronze.{table} ({col_list})\nVALUES\n    {values_clause}"


# ---------------------------------------------------------------------------
# Snapshot query
# ---------------------------------------------------------------------------
def fetch_snapshot_id(cursor: trino.dbapi.Cursor, table: str) -> str | None:
    try:
        cursor.execute(
            f"""SELECT snapshot_id
                FROM iceberg.iceberg_metadata.snapshots
                WHERE table_name = '{table}'
                ORDER BY committed_at DESC
                LIMIT 1"""
        )
        rows = cursor.fetchall()
        if rows:
            return str(rows[0][0])
        return None
    except Exception as exc:
        log.warning("Could not retrieve snapshot ID: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Main ingestion logic
# ---------------------------------------------------------------------------
def ingest(source_path: str, table: str, branch: str) -> None:
    # 1. Read CSV
    df = read_csv(source_path)
    total_rows = len(df)
    source_filename = os.path.basename(source_path)
    columns = list(df.columns)

    # 2. Connect to Trino
    conn = connect_trino(branch)
    cursor = conn.cursor()

    rows_inserted = 0
    try:
        # 3. Ensure schema and table exist
        ensure_schema(cursor)
        ensure_table(cursor, table, columns)

        # 4. Insert in batches
        num_batches = (total_rows + BATCH_SIZE - 1) // BATCH_SIZE
        for batch_idx in range(num_batches):
            start = batch_idx * BATCH_SIZE
            end = min(start + BATCH_SIZE, total_rows)
            batch = df.iloc[start:end]

            insert_sql = build_insert(table, columns, batch, source_filename)
            cursor.execute(insert_sql)
            cursor.fetchall()

            rows_inserted += len(batch)
            log.info(
                "Inserted batch %d/%d (%d rows)",
                batch_idx + 1,
                num_batches,
                len(batch),
            )

        # 5. Fetch snapshot ID
        snapshot_id = fetch_snapshot_id(cursor, table)
        if snapshot_id:
            log.info(
                "Ingestion complete. Rows inserted: %d. Snapshot ID: %s",
                rows_inserted,
                snapshot_id,
            )
        else:
            log.info(
                "Ingestion complete. Rows inserted: %d. Snapshot ID unavailable.",
                rows_inserted,
            )

    except Exception as exc:
        log.error(
            "Ingestion failed for '%s' after %d rows: %s",
            source_path,
            rows_inserted,
            exc,
        )
        sys.exit(1)
    finally:
        cursor.close()
        conn.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    args = parse_args()
    source_path = resolve_source(args.source)
    ingest(source_path=source_path, table=args.table, branch=args.branch)


if __name__ == "__main__":
    main()
