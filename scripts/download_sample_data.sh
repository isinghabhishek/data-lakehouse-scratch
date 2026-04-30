#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# download_sample_data.sh
# Downloads NYC Yellow Taxi trip data (January 2024) into
# data/raw/yellow_taxi_2024_01.csv
# ============================================================

OUTPUT_FILE="data/raw/yellow_taxi_2024_01.csv"
PARQUET_URL="https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2024-01.parquet"
PARQUET_TMP="/tmp/yellow_taxi_2024_01.parquet"

# ------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------
echo "==> Checking prerequisites..."

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is not installed or not in PATH. Please install curl and retry." >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is not installed or not in PATH. Please install Python 3 and retry." >&2
  exit 1
fi

echo "    curl:    $(curl --version | head -1)"
echo "    python3: $(python3 --version)"

# ------------------------------------------------------------
# Idempotency check
# ------------------------------------------------------------
if [[ -f "$OUTPUT_FILE" ]]; then
  echo "==> Output file already exists: $OUTPUT_FILE"
  echo "    Skipping download. Delete the file to re-download."
  exit 0
fi

# ------------------------------------------------------------
# Ensure output directory exists
# ------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_FILE")"

# ------------------------------------------------------------
# Download Parquet file
# ------------------------------------------------------------
echo "==> Downloading NYC Yellow Taxi data (January 2024)..."
echo "    Source : $PARQUET_URL"
echo "    Dest   : $PARQUET_TMP"

curl \
  --fail \
  --location \
  --progress-bar \
  --output "$PARQUET_TMP" \
  "$PARQUET_URL"

echo "    Download complete."

# ------------------------------------------------------------
# Convert Parquet → CSV using pandas
# ------------------------------------------------------------
echo "==> Converting Parquet to CSV..."
echo "    Output : $OUTPUT_FILE"

python3 -c "
import pandas as pd
df = pd.read_parquet('$PARQUET_TMP')
df.to_csv('$OUTPUT_FILE', index=False)
print(f'    Rows   : {len(df):,}')
"

# ------------------------------------------------------------
# Cleanup temp file
# ------------------------------------------------------------
echo "==> Cleaning up temporary Parquet file..."
rm -f "$PARQUET_TMP"

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
echo "==> Success! Sample data written to: $OUTPUT_FILE"
