#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# benchmark.sh — Runs representative SQL queries against Gold Iceberg tables,
# records wall-clock execution time for each, and writes benchmark_results.md.
#
# Requirements: 11.1, 11.2, 11.3
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (read from env with defaults)
# ---------------------------------------------------------------------------
TRINO_HOST="${TRINO_HOST:-localhost}"
TRINO_PORT="${TRINO_PORT:-8080}"
TRINO_CLI="${TRINO_CLI:-trino}"
OUTPUT_FILE="${OUTPUT_FILE:-benchmark_results.md}"

# Maximum allowed execution time per query (60 seconds in milliseconds)
MAX_ELAPSED_MS=60000

# ---------------------------------------------------------------------------
# Helper: run a Trino query against the gold schema and return output
# ---------------------------------------------------------------------------
run_trino_query() {
  local query="$1"
  "${TRINO_CLI}" \
    --server "http://${TRINO_HOST}:${TRINO_PORT}" \
    --catalog iceberg \
    --schema gold \
    --output-format TSV \
    --execute "${query}"
}

# ---------------------------------------------------------------------------
# Helper: time a query and store results in LAST_* variables
# ---------------------------------------------------------------------------
# Sets: LAST_LABEL, LAST_ELAPSED_MS, LAST_ROW_COUNT, LAST_QUERY
time_query() {
  local label="$1"
  local query="$2"

  local START_MS END_MS OUTPUT ROW_COUNT ELAPSED_MS

  START_MS=$(date +%s%3N)
  OUTPUT=$(run_trino_query "${query}")
  END_MS=$(date +%s%3N)

  ELAPSED_MS=$(( END_MS - START_MS ))
  ROW_COUNT=$(echo "${OUTPUT}" | tail -n +2 | wc -l | tr -d ' ')

  LAST_LABEL="${label}"
  LAST_ELAPSED_MS="${ELAPSED_MS}"
  LAST_ROW_COUNT="${ROW_COUNT}"
  LAST_QUERY="${query}"

  echo "    [${label}] ${ELAPSED_MS}ms — ${ROW_COUNT} rows"
}

# ---------------------------------------------------------------------------
# Arrays to accumulate results
# ---------------------------------------------------------------------------
RESULT_LABELS=()
RESULT_ELAPSED=()
RESULT_ROWS=()
RESULT_QUERIES=()

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
echo "==> Running benchmarks against Gold Iceberg tables..."

# Q1: Top 10 busiest days
time_query \
  "Q1: Top 10 busiest days" \
  "SELECT trip_date, total_trips, total_revenue
FROM iceberg.gold.daily_trip_summary
ORDER BY total_trips DESC
LIMIT 10"

RESULT_LABELS+=("${LAST_LABEL}")
RESULT_ELAPSED+=("${LAST_ELAPSED_MS}")
RESULT_ROWS+=("${LAST_ROW_COUNT}")
RESULT_QUERIES+=("${LAST_QUERY}")

if [ "${LAST_ELAPSED_MS}" -gt "${MAX_ELAPSED_MS}" ]; then
  echo "ERROR: [${LAST_LABEL}] exceeded 60-second limit (${LAST_ELAPSED_MS}ms)" >&2
  exit 1
fi

# Q2: Monthly revenue trend
time_query \
  "Q2: Monthly revenue trend" \
  "SELECT DATE_TRUNC('month', trip_date) AS trip_month,
       SUM(total_trips) AS monthly_trips,
       SUM(total_revenue) AS monthly_revenue
FROM iceberg.gold.daily_trip_summary
GROUP BY DATE_TRUNC('month', trip_date)
ORDER BY trip_month"

RESULT_LABELS+=("${LAST_LABEL}")
RESULT_ELAPSED+=("${LAST_ELAPSED_MS}")
RESULT_ROWS+=("${LAST_ROW_COUNT}")
RESULT_QUERIES+=("${LAST_QUERY}")

if [ "${LAST_ELAPSED_MS}" -gt "${MAX_ELAPSED_MS}" ]; then
  echo "ERROR: [${LAST_LABEL}] exceeded 60-second limit (${LAST_ELAPSED_MS}ms)" >&2
  exit 1
fi

# Q3: Vendor tip percentage ranking
time_query \
  "Q3: Vendor tip percentage ranking" \
  "SELECT vendor_id,
       SUM(total_trips) AS total_trips,
       AVG(avg_tip_pct) AS avg_tip_pct
FROM iceberg.gold.vendor_performance
GROUP BY vendor_id
ORDER BY avg_tip_pct DESC"

RESULT_LABELS+=("${LAST_LABEL}")
RESULT_ELAPSED+=("${LAST_ELAPSED_MS}")
RESULT_ROWS+=("${LAST_ROW_COUNT}")
RESULT_QUERIES+=("${LAST_QUERY}")

if [ "${LAST_ELAPSED_MS}" -gt "${MAX_ELAPSED_MS}" ]; then
  echo "ERROR: [${LAST_LABEL}] exceeded 60-second limit (${LAST_ELAPSED_MS}ms)" >&2
  exit 1
fi

# Q4: Average fare by day of week
time_query \
  "Q4: Average fare by day of week" \
  "SELECT day_of_week(trip_date) AS day_of_week,
       SUM(total_trips) AS total_trips,
       AVG(avg_fare) AS avg_fare
FROM iceberg.gold.daily_trip_summary
GROUP BY day_of_week(trip_date)
ORDER BY day_of_week"

RESULT_LABELS+=("${LAST_LABEL}")
RESULT_ELAPSED+=("${LAST_ELAPSED_MS}")
RESULT_ROWS+=("${LAST_ROW_COUNT}")
RESULT_QUERIES+=("${LAST_QUERY}")

if [ "${LAST_ELAPSED_MS}" -gt "${MAX_ELAPSED_MS}" ]; then
  echo "ERROR: [${LAST_LABEL}] exceeded 60-second limit (${LAST_ELAPSED_MS}ms)" >&2
  exit 1
fi

# Q5: Full table scan — daily summary
time_query \
  "Q5: Full table scan — daily summary" \
  "SELECT COUNT(*) AS total_days,
       SUM(total_trips) AS grand_total_trips,
       SUM(total_revenue) AS grand_total_revenue,
       AVG(avg_fare) AS overall_avg_fare
FROM iceberg.gold.daily_trip_summary"

RESULT_LABELS+=("${LAST_LABEL}")
RESULT_ELAPSED+=("${LAST_ELAPSED_MS}")
RESULT_ROWS+=("${LAST_ROW_COUNT}")
RESULT_QUERIES+=("${LAST_QUERY}")

if [ "${LAST_ELAPSED_MS}" -gt "${MAX_ELAPSED_MS}" ]; then
  echo "ERROR: [${LAST_LABEL}] exceeded 60-second limit (${LAST_ELAPSED_MS}ms)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Write benchmark_results.md
# ---------------------------------------------------------------------------
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NUM_QUERIES=${#RESULT_LABELS[@]}

{
  cat <<EOF
# Benchmark Results — Data Lakehouse from Scratch

**Generated:** ${GENERATED_AT}
**Trino endpoint:** http://${TRINO_HOST}:${TRINO_PORT}
**Catalog:** iceberg
**Dataset:** NYC Yellow Taxi (January 2024)

---

## Results Summary

| Query | Execution Time | Rows Returned |
|-------|----------------|---------------|
EOF

  for i in $(seq 0 $(( NUM_QUERIES - 1 ))); do
    echo "| ${RESULT_LABELS[$i]} | ${RESULT_ELAPSED[$i]}ms | ${RESULT_ROWS[$i]} |"
  done

  cat <<'EOF'

---

## Query Details

EOF

  for i in $(seq 0 $(( NUM_QUERIES - 1 ))); do
    cat <<EOF
### ${RESULT_LABELS[$i]}
**Execution time:** ${RESULT_ELAPSED[$i]}ms
**Rows returned:** ${RESULT_ROWS[$i]}

\`\`\`sql
${RESULT_QUERIES[$i]}
\`\`\`

EOF
  done

} > "${OUTPUT_FILE}"

echo "==> All benchmarks complete. Results written to ${OUTPUT_FILE}"

exit 0
