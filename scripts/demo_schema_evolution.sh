#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# demo_schema_evolution.sh — Demonstrates Iceberg schema evolution by adding,
# renaming, and dropping columns on a live table without rewriting existing
# Parquet data files.
#
# Requirements: 9.1, 9.2, 9.3, 9.4, 9.5
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (read from env with defaults)
# ---------------------------------------------------------------------------
TRINO_HOST="${TRINO_HOST:-localhost}"
TRINO_PORT="${TRINO_PORT:-8080}"
TRINO_CLI="${TRINO_CLI:-trino}"

# ---------------------------------------------------------------------------
# Helper: run a Trino query and return output
# ---------------------------------------------------------------------------
run_trino_query() {
  local query="$1"
  "${TRINO_CLI}" \
    --server "http://${TRINO_HOST}:${TRINO_PORT}" \
    --catalog iceberg \
    --schema bronze \
    --output-format TSV \
    --execute "${query}"
}

# ---------------------------------------------------------------------------
# Helper: get row count for a table
# ---------------------------------------------------------------------------
get_row_count() {
  local table="$1"
  run_trino_query "SELECT COUNT(*) FROM ${table}" \
    | tail -n +2 \
    | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Helper: assert two values are equal
# ---------------------------------------------------------------------------
assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [ "${actual}" != "${expected}" ]; then
    echo "ERROR: ${message} — expected '${expected}' but got '${actual}'" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Setup — create a clean test table with 3 columns
# ---------------------------------------------------------------------------
echo "==> Iceberg Schema Evolution Demo"

run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.schema_evo_test"

run_trino_query "CREATE TABLE iceberg.bronze.schema_evo_test (
  id INTEGER,
  name VARCHAR,
  score DOUBLE
) WITH (format='PARQUET')"

run_trino_query "INSERT INTO iceberg.bronze.schema_evo_test VALUES
  (1, 'row_1', 1.5),
  (2, 'row_2', 3.0),
  (3, 'row_3', 4.5),
  (4, 'row_4', 6.0),
  (5, 'row_5', 7.5)"

INITIAL_COUNT=$(get_row_count "iceberg.bronze.schema_evo_test")
assert_equals "${INITIAL_COUNT}" "5" "Initial row count"

echo "==> Created table with 5 initial rows (columns: id, name, score)"

# ---------------------------------------------------------------------------
# Step 1 — ADD COLUMN
# ---------------------------------------------------------------------------
echo "==> Step 1: ADD COLUMN (adding 'category VARCHAR')"

run_trino_query "ALTER TABLE iceberg.bronze.schema_evo_test ADD COLUMN category VARCHAR"

ROW_COUNT=$(get_row_count "iceberg.bronze.schema_evo_test")
assert_equals "${ROW_COUNT}" "5" "Row count after ADD COLUMN"

NULL_COUNT=$(run_trino_query \
  "SELECT COUNT(*) FROM iceberg.bronze.schema_evo_test WHERE category IS NULL" \
  | tail -n +2 \
  | tr -d '[:space:]')
assert_equals "${NULL_COUNT}" "5" "NULL count for new column on existing rows"

echo "==> ADD COLUMN PASSED: row count unchanged (5), new column returns NULL for existing rows ✓"

# ---------------------------------------------------------------------------
# Step 2 — RENAME COLUMN
# ---------------------------------------------------------------------------
echo "==> Step 2: RENAME COLUMN ('name' → 'display_name')"

run_trino_query "ALTER TABLE iceberg.bronze.schema_evo_test RENAME COLUMN name TO display_name"

ROW_COUNT=$(get_row_count "iceberg.bronze.schema_evo_test")
assert_equals "${ROW_COUNT}" "5" "Row count after RENAME COLUMN"

PRESERVED_COUNT=$(run_trino_query \
  "SELECT COUNT(*) FROM iceberg.bronze.schema_evo_test WHERE display_name LIKE 'row_%'" \
  | tail -n +2 \
  | tr -d '[:space:]')
assert_equals "${PRESERVED_COUNT}" "5" "Values preserved under renamed column"

echo "==> RENAME COLUMN PASSED: row count unchanged (5), all values preserved under 'display_name' ✓"

# ---------------------------------------------------------------------------
# Step 3 — DROP COLUMN
# ---------------------------------------------------------------------------
echo "==> Step 3: DROP COLUMN (dropping 'category')"

run_trino_query "ALTER TABLE iceberg.bronze.schema_evo_test DROP COLUMN category"

ROW_COUNT=$(get_row_count "iceberg.bronze.schema_evo_test")
assert_equals "${ROW_COUNT}" "5" "Row count after DROP COLUMN"

DESCRIBE_OUTPUT=$(run_trino_query "DESCRIBE iceberg.bronze.schema_evo_test")
if echo "${DESCRIBE_OUTPUT}" | grep -q "category"; then
  echo "ERROR: DROP COLUMN FAILED — 'category' still appears in DESCRIBE output" >&2
  exit 1
fi

echo "==> DROP COLUMN PASSED: row count unchanged (5), 'category' absent from schema ✓"

# ---------------------------------------------------------------------------
# Cleanup (optional — skip if KEEP_TEST_TABLE=1)
# ---------------------------------------------------------------------------
if [ "${KEEP_TEST_TABLE:-0}" != "1" ]; then
  run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.schema_evo_test"
  echo "==> Cleaned up test table"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo "==> Schema Evolution Demo COMPLETE"
echo "    - ADD COLUMN:    ✓ (no data rewrite, NULL for existing rows)"
echo "    - RENAME COLUMN: ✓ (all values preserved under new name)"
echo "    - DROP COLUMN:   ✓ (column removed, row count unchanged)"

exit 0
