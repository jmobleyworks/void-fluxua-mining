#!/bin/bash
#
# NONCE FEEDER - Reads from QEC generator and seeds job queue
# Takes nonces from qec_generator_optimized.sh output
# Inserts them into D1 job_queue for workers to pull
#

set -euo pipefail

source ~/.zshrc 2>/dev/null || true

# Configuration
MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-Johnmobley99@gmail.com}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-c70d7a88f87f8cf4b3cfd7971ca482dc9882d}"
D1_DATABASE_ID="20da851f-2876-4113-bdae-9f99582ea0e2"
QEC_OUTPUT="${MASCOM_DIR}/mining_state/qec_corrections_optimized.jsonl"
LOG_FILE="${MASCOM_DIR}/mining_state/nonce_feeder.log"
STATE_FILE="${MASCOM_DIR}/mining_state/nonce_feeder_state.json"

mkdir -p "$(dirname "$LOG_FILE")"

# Initialize state
if [ ! -f "$STATE_FILE" ]; then
  echo '{"last_line": 0, "total_fed": 0, "last_run": null}' > "$STATE_FILE"
fi

log_msg() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

insert_job_to_d1() {
  local nonce="$1"
  local difficulty="${2:-1000000}"
  local job_id="job-$(date +%s)-$(echo "$RANDOM" | md5sum | cut -c1-8)"

  # Use curl to call D1 API to insert into job_queue table
  # POST /accounts/{CF_ACCOUNT_ID}/d1/database/{D1_DATABASE_ID}/query

  local sql="INSERT INTO job_queue (job_id, status, task_type, task_data, difficulty, created_at) VALUES ('$job_id', 'pending', 'monero_nonce', '$nonce', $difficulty, datetime('now'))"

  # Call D1 API to insert into job_queue table
  local response=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${D1_DATABASE_ID}/query" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"sql\": \"$sql\"}" 2>&1)

  # Check if insert was successful
  if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
    log_msg "✓ Inserted job: $job_id with nonce: $nonce (difficulty: $difficulty)"
    return 0
  else
    log_msg "✗ Failed to insert job: $job_id"
    return 1
  fi
}

log_msg "Nonce feeder started"
log_msg "QEC output file: $QEC_OUTPUT"
log_msg "D1 database: $D1_DATABASE_ID"

# Main loop: monitor QEC output and feed nonces
jobs_fed=0
last_check=0

while true; do
  if [ -f "$QEC_OUTPUT" ]; then
    # Count lines in QEC output
    current_lines=$(wc -l < "$QEC_OUTPUT")

    # If new lines available
    if [ "$current_lines" -gt "$last_check" ]; then
      # Read new lines and insert as jobs
      tail -n "+$((last_check+1))" "$QEC_OUTPUT" | while read -r line; do
        # Parse JSON: {"nonce": "abc123", "syndrome_magnitude": 0.95, ...}
        nonce=$(echo "$line" | jq -r '.nonce // empty' 2>/dev/null)
        difficulty=$(echo "$line" | jq -r '.difficulty // 1000000' 2>/dev/null)

        if [ -n "$nonce" ]; then
          insert_job_to_d1 "$nonce" "$difficulty"
          ((jobs_fed++))
        fi
      done

      last_check="$current_lines"

      if [ $((jobs_fed % 100)) -eq 0 ]; then
        log_msg "Progress: $jobs_fed nonces fed to job queue"
      fi
    fi
  else
    log_msg "Waiting for QEC output: $QEC_OUTPUT"
  fi

  # Update state
  jq --arg last_line "$last_check" --arg total_fed "$jobs_fed" --arg last_run "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '.last_line = ($last_line | tonumber) | .total_fed = ($total_fed | tonumber) | .last_run = $last_run' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

  sleep 1
done
