#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# demo_acid.sh — Demonstrates Iceberg ACID transaction semantics by running
# two concurrent INSERT operations against the same table and verifying the
# final row count equals the sum of both inserts.
#
# Requirements: 7.1, 7.2, 7.3
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
# Setup — create a clean test table
# ---------------------------------------------------------------------------
echo "==> ACID Concurrent Write Demo"

echo "==> Dropping existing test table (if any)..."
run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.acid_test"

echo "==> Creating test table..."
run_trino_query "CREATE TABLE IF NOT EXISTS iceberg.bronze.acid_test (
  id INTEGER,
  batch VARCHAR,
  inserted_at TIMESTAMP(6)
) WITH (format='PARQUET')"

echo "==> Created clean test table: iceberg.bronze.acid_test"

# ---------------------------------------------------------------------------
# Build VALUES clauses for both batches
# ---------------------------------------------------------------------------
BATCH_A_ROWS=50
BATCH_B_ROWS=75

# Build INSERT A: rows 1–50, batch='A'
VALUES_A=""
for i in $(seq 1 ${BATCH_A_ROWS}); do
  if [ -n "$VALUES_A" ]; then VALUES_A="$VALUES_A, "; fi
  VALUES_A="$VALUES_A($i, 'A', CURRENT_TIMESTAMP)"
done
INSERT_A="INSERT INTO iceberg.bronze.acid_test (id, batch, inserted_at) VALUES $VALUES_A"

# Build INSERT B: rows 51–125, batch='B'
VALUES_B=""
for i in $(seq 51 $((50 + BATCH_B_ROWS))); do
  if [ -n "$VALUES_B" ]; then VALUES_B="$VALUES_B, "; fi
  VALUES_B="$VALUES_B($i, 'B', CURRENT_TIMESTAMP)"
done
INSERT_B="INSERT INTO iceberg.bronze.acid_test (id, batch, inserted_at) VALUES $VALUES_B"

# ---------------------------------------------------------------------------
# Launch both inserts as background processes
# ---------------------------------------------------------------------------
run_trino_query "$INSERT_A" &
PID_A=$!
run_trino_query "$INSERT_B" &
PID_B=$!

echo "==> Launched concurrent inserts (Batch A: ${BATCH_A_ROWS} rows, Batch B: ${BATCH_B_ROWS} rows)"

# Wait for both inserts to complete
wait $PID_A && wait $PID_B

echo "==> Both inserts completed"

# ---------------------------------------------------------------------------
# Verification — check final row count
# ---------------------------------------------------------------------------
EXPECTED_TOTAL=$((BATCH_A_ROWS + BATCH_B_ROWS))

echo "==> Verifying row count (expected: ${EXPECTED_TOTAL})..."

ACTUAL_COUNT=$(run_trino_query "SELECT COUNT(*) FROM iceberg.bronze.acid_test" \
  | tail -n +2 \
  | tr -d '[:space:]')

if [ "${ACTUAL_COUNT}" != "${EXPECTED_TOTAL}" ]; then
  echo "ERROR: ACID verification FAILED — expected ${EXPECTED_TOTAL} rows but found ${ACTUAL_COUNT}" >&2
  exit 1
fi

# Per-batch breakdown
echo "==> Per-batch row counts:"
run_trino_query "SELECT batch, COUNT(*) FROM iceberg.bronze.acid_test GROUP BY batch ORDER BY batch" \
  | tail -n +2 \
  | while IFS=$'\t' read -r batch count; do
      echo "    Batch ${batch}: ${count} rows"
    done

echo "==> ACID verification PASSED: ${EXPECTED_TOTAL} rows committed (${BATCH_A_ROWS} from A + ${BATCH_B_ROWS} from B)"

# ---------------------------------------------------------------------------
# Cleanup (optional — skip if KEEP_TEST_TABLE=1)
# ---------------------------------------------------------------------------
if [ "${KEEP_TEST_TABLE:-0}" != "1" ]; then
  run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.acid_test"
  echo "==> Cleaned up test table"
fi

exit 0
