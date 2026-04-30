#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# demo_branching.sh — Demonstrates Nessie catalog branching by creating a
# feature branch, writing data to it in isolation, verifying the main branch
# is unaffected, merging the branch into main, and verifying the merged data
# is visible on main.
#
# Requirements: 10.1, 10.2, 10.3, 10.4, 10.5
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (read from env with defaults)
# ---------------------------------------------------------------------------
TRINO_HOST="${TRINO_HOST:-localhost}"
TRINO_PORT="${TRINO_PORT:-8080}"
TRINO_CLI="${TRINO_CLI:-trino}"
NESSIE_HOST="${NESSIE_HOST:-localhost}"
NESSIE_PORT="${NESSIE_PORT:-19120}"
BRANCH_NAME="${BRANCH_NAME:-feature/branching-demo}"

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
# Helper: run a Trino query with a specific Nessie branch set via session
# ---------------------------------------------------------------------------
run_trino_on_branch() {
  local branch="$1"
  local query="$2"
  "${TRINO_CLI}" \
    --server "http://${TRINO_HOST}:${TRINO_PORT}" \
    --catalog iceberg \
    --schema bronze \
    --output-format TSV \
    --session "iceberg.nessie_reference_name=${branch}" \
    --execute "${query}"
}

# ---------------------------------------------------------------------------
# Helper: call the Nessie REST API
# ---------------------------------------------------------------------------
nessie_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  curl -s -X "${method}" \
    "http://${NESSIE_HOST}:${NESSIE_PORT}/api/v1${path}" \
    -H "Content-Type: application/json" \
    ${data:+-d "${data}"}
}

# ---------------------------------------------------------------------------
# Helper: get row count for a table on a specific branch
# ---------------------------------------------------------------------------
get_row_count_on_branch() {
  local branch="$1"
  local table="$2"
  run_trino_on_branch "${branch}" "SELECT COUNT(*) FROM ${table}" \
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
# Setup — get main branch hash from Nessie REST API
# ---------------------------------------------------------------------------
echo "==> Nessie Catalog Branching Demo"

MAIN_HASH=$(nessie_api GET "/branches/main" | python3 -c "import sys,json; print(json.load(sys.stdin)['hash'])")
echo "==> main branch hash: ${MAIN_HASH}"

# ---------------------------------------------------------------------------
# Create a test table on main (baseline for isolation check)
# ---------------------------------------------------------------------------
run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.branch_demo_main"

run_trino_query "CREATE TABLE iceberg.bronze.branch_demo_main (
  id INTEGER,
  source VARCHAR
) WITH (format='PARQUET')"

run_trino_query "INSERT INTO iceberg.bronze.branch_demo_main VALUES
  (1,'main'),(2,'main'),(3,'main'),(4,'main'),(5,'main'),
  (6,'main'),(7,'main'),(8,'main'),(9,'main'),(10,'main')"

MAIN_COUNT=$(get_row_count_on_branch "main" "iceberg.bronze.branch_demo_main")
assert_equals "${MAIN_COUNT}" "10" "Row count of branch_demo_main on main"

echo "==> Created branch_demo_main on main with 10 rows"

# ---------------------------------------------------------------------------
# Create the feature branch from main
# ---------------------------------------------------------------------------
nessie_api POST "/branches" \
  "{\"name\": \"${BRANCH_NAME}\", \"hash\": \"${MAIN_HASH}\", \"type\": \"BRANCH\"}"

echo "==> Created branch '${BRANCH_NAME}' from main"

# ---------------------------------------------------------------------------
# Write to the feature branch (isolation test)
# ---------------------------------------------------------------------------
run_trino_on_branch "${BRANCH_NAME}" \
  "CREATE TABLE iceberg.bronze.branch_demo_feature (id INTEGER, source VARCHAR) WITH (format='PARQUET')"

run_trino_on_branch "${BRANCH_NAME}" \
  "INSERT INTO iceberg.bronze.branch_demo_feature VALUES (1,'feature'),(2,'feature'),(3,'feature'),(4,'feature'),(5,'feature')"

echo "==> Wrote branch_demo_feature table to branch '${BRANCH_NAME}' (5 rows)"

# ---------------------------------------------------------------------------
# Verify branch isolation — main should NOT see the feature table
# ---------------------------------------------------------------------------
MAIN_TABLES=$(run_trino_query "SHOW TABLES IN iceberg.bronze")

if echo "${MAIN_TABLES}" | grep -q "branch_demo_feature"; then
  echo "ERROR: Branch isolation FAILED — branch_demo_feature is visible on main before merge" >&2
  exit 1
fi

echo "==> Branch isolation PASSED: branch_demo_feature not visible on main ✓"

# ---------------------------------------------------------------------------
# Merge the feature branch into main
# ---------------------------------------------------------------------------
FEATURE_HASH=$(nessie_api GET "/branches/${BRANCH_NAME}" | python3 -c "import sys,json; print(json.load(sys.stdin)['hash'])")

nessie_api POST "/branches/main/merge" \
  "{\"fromRefName\": \"${BRANCH_NAME}\", \"fromHash\": \"${FEATURE_HASH}\"}"

echo "==> Merged '${BRANCH_NAME}' into main"

# ---------------------------------------------------------------------------
# Verify merge visibility — main should now see the feature table
# ---------------------------------------------------------------------------
MAIN_TABLES_AFTER=$(run_trino_query "SHOW TABLES IN iceberg.bronze")

if ! echo "${MAIN_TABLES_AFTER}" | grep -q "branch_demo_feature"; then
  echo "ERROR: Merge visibility FAILED — branch_demo_feature not visible on main after merge" >&2
  exit 1
fi

FEATURE_COUNT_ON_MAIN=$(get_row_count_on_branch "main" "iceberg.bronze.branch_demo_feature")
assert_equals "${FEATURE_COUNT_ON_MAIN}" "5" "Row count of branch_demo_feature on main after merge"

echo "==> Merge visibility PASSED: branch_demo_feature visible on main with 5 rows ✓"

# ---------------------------------------------------------------------------
# Cleanup (optional — skip if KEEP_TEST_TABLE=1)
# ---------------------------------------------------------------------------
if [ "${KEEP_TEST_TABLE:-0}" != "1" ]; then
  run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.branch_demo_main"
  run_trino_query "DROP TABLE IF EXISTS iceberg.bronze.branch_demo_feature"
  nessie_api DELETE "/branches/${BRANCH_NAME}?expectedHash=${FEATURE_HASH}"
  echo "==> Cleaned up test tables and deleted branch '${BRANCH_NAME}'"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo "==> Nessie Branching Demo COMPLETE"
echo "    - Branch creation:  ✓ (feature branch created from main)"
echo "    - Write isolation:  ✓ (feature table not visible on main before merge)"
echo "    - Branch merge:     ✓ (feature table visible on main after merge, 5 rows)"

exit 0
