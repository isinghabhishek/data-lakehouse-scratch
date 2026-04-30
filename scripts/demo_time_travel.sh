#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# demo_time_travel.sh — Demonstrates Iceberg time travel by inserting two
# batches of data, recording the snapshot ID and timestamp after the first
# batch, then querying the table at that historical point using both
# FOR VERSION AS OF and FOR TIMESTAMP AS OF syntax.
#
# Requirements: 8.1, 8.2, 8.3, 8.4
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
echo "==> Iceberg Time Travel Demo"

run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.time_travel_test"

run_trino_query "CREATE TABLE iceberg.bronze.time_travel_test (
  id INTEGER,
  label VARCHAR,
  created_at TIMESTAMP(6)
) WITH (format='PARQUET')"

echo "==> Created clean test table: iceberg.bronze.time_travel_test"

# ---------------------------------------------------------------------------
# Insert Batch A — 10 rows, label='batch_a', id 1–10
# ---------------------------------------------------------------------------
VALUES_A=""
for i in $(seq 1 10); do
  if [ -n "$VALUES_A" ]; then VALUES_A="$VALUES_A, "; fi
  VALUES_A="$VALUES_A($i, 'batch_a', CURRENT_TIMESTAMP)"
done

run_trino_query "INSERT INTO iceberg.bronze.time_travel_test (id, label, created_at) VALUES $VALUES_A"

echo "==> Inserted Batch A (10 rows)"

# ---------------------------------------------------------------------------
# Record snapshot ID and timestamp after Batch A
# ---------------------------------------------------------------------------
SNAPSHOT_ROW=$(run_trino_query \
  "SELECT snapshot_id, to_iso8601(CAST(committed_at AS TIMESTAMP(6)))
   FROM iceberg.\"time_travel_test\$snapshots\"
   ORDER BY committed_at DESC
   LIMIT 1" \
  | tail -n +2)

SNAPSHOT_ID=$(echo "$SNAPSHOT_ROW" | cut -f1)
SNAPSHOT_TS=$(echo "$SNAPSHOT_ROW" | cut -f2)

echo "==> Recorded snapshot after Batch A: ID=${SNAPSHOT_ID}, TS=${SNAPSHOT_TS}"

# Sleep to ensure timestamp separation between batches
sleep 2

# ---------------------------------------------------------------------------
# Insert Batch B — 15 rows, label='batch_b', id 11–25
# ---------------------------------------------------------------------------
VALUES_B=""
for i in $(seq 11 25); do
  if [ -n "$VALUES_B" ]; then VALUES_B="$VALUES_B, "; fi
  VALUES_B="$VALUES_B($i, 'batch_b', CURRENT_TIMESTAMP)"
done

run_trino_query "INSERT INTO iceberg.bronze.time_travel_test (id, label, created_at) VALUES $VALUES_B"

echo "==> Inserted Batch B (15 rows)"

# ---------------------------------------------------------------------------
# Verify current state — should be 25 rows
# ---------------------------------------------------------------------------
CURRENT_COUNT=$(run_trino_query \
  "SELECT COUNT(*) FROM iceberg.bronze.time_travel_test" \
  | tail -n +2 \
  | tr -d '[:space:]')

if [ "${CURRENT_COUNT}" != "25" ]; then
  echo "ERROR: Expected 25 rows after both batches but found ${CURRENT_COUNT}" >&2
  exit 1
fi

echo "==> Current table has 25 rows (Batch A + Batch B) ✓"

# ---------------------------------------------------------------------------
# Time travel by snapshot ID — FOR VERSION AS OF
# ---------------------------------------------------------------------------
VERSION_COUNT=$(run_trino_query \
  "SELECT COUNT(*) FROM iceberg.bronze.time_travel_test FOR VERSION AS OF ${SNAPSHOT_ID}" \
  | tail -n +2 \
  | tr -d '[:space:]')

if [ "${VERSION_COUNT}" != "10" ]; then
  echo "ERROR: Time travel by snapshot ID FAILED — expected 10 rows but found ${VERSION_COUNT}" >&2
  exit 1
fi

echo "==> Time travel by snapshot ID PASSED: 10 rows at snapshot ${SNAPSHOT_ID} ✓"

# ---------------------------------------------------------------------------
# Time travel by timestamp — FOR TIMESTAMP AS OF
# ---------------------------------------------------------------------------
TIMESTAMP_COUNT=$(run_trino_query \
  "SELECT COUNT(*) FROM iceberg.bronze.time_travel_test FOR TIMESTAMP AS OF TIMESTAMP '${SNAPSHOT_TS}'" \
  | tail -n +2 \
  | tr -d '[:space:]')

if [ "${TIMESTAMP_COUNT}" != "10" ]; then
  echo "ERROR: Time travel by timestamp FAILED — expected 10 rows but found ${TIMESTAMP_COUNT}" >&2
  exit 1
fi

echo "==> Time travel by timestamp PASSED: 10 rows at timestamp ${SNAPSHOT_TS} ✓"

# ---------------------------------------------------------------------------
# Demonstrate invalid snapshot ID error (informational only)
# ---------------------------------------------------------------------------
INVALID_OUTPUT=$("${TRINO_CLI}" \
  --server "http://${TRINO_HOST}:${TRINO_PORT}" \
  --catalog iceberg \
  --schema bronze \
  --output-format TSV \
  --execute "SELECT COUNT(*) FROM iceberg.bronze.time_travel_test FOR VERSION AS OF 999999999999" \
  2>&1 || true)

echo "==> Invalid snapshot ID returns error (expected): ${INVALID_OUTPUT}"

# ---------------------------------------------------------------------------
# Cleanup (optional — skip if KEEP_TEST_TABLE=1)
# ---------------------------------------------------------------------------
if [ "${KEEP_TEST_TABLE:-0}" != "1" ]; then
  run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.time_travel_test"
  echo "==> Cleaned up test table"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo "==> Time Travel Demo COMPLETE"
echo "    - FOR VERSION AS OF ${SNAPSHOT_ID}: ✓"
echo "    - FOR TIMESTAMP AS OF TIMESTAMP '${SNAPSHOT_TS}': ✓"

exit 0
