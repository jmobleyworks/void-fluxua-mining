#!/bin/zsh
# VOID FLUX → STRATUM BRIDGE
# Converts QEC-resolved syndromes into stratum-compatible share submissions
# Executes continuously, reading corrections and submitting to pool

set -e

LOG_DIR="/tmp/mascom"
mkdir -p "$LOG_DIR"

# Counters
CORRECTIONS_PROCESSED=0
SUBMISSIONS_ATTEMPTED=0
LAST_JOB_ID=""

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Void Flux → Stratum Bridge started" >> "$LOG_DIR/void_flux_bridge.log"

while true; do
  # Read latest QEC corrections
  if [ -f /tmp/qec_corrections.jsonl ]; then
    LATEST_CORRECTION=$(tail -1 /tmp/qec_corrections.jsonl 2>/dev/null)

    if [ -n "$LATEST_CORRECTION" ]; then
      # Extract key fields
      VENTURE_ID=$(echo "$LATEST_CORRECTION" | jq -r '.venture_id // "unknown"' 2>/dev/null)
      SYNDROME=$(echo "$LATEST_CORRECTION" | jq -r '.syndrome_magnitude // 0' 2>/dev/null)
      NONCE=$(echo "$LATEST_CORRECTION" | jq -r '.nonce // ""' 2>/dev/null)
      HASH=$(echo "$LATEST_CORRECTION" | jq -r '.hash // ""' 2>/dev/null)

      # Get current job from field register
      CURRENT_JOB=$(curl -s -X GET "http://127.0.0.1:8789/stratum/current_job" 2>/dev/null || echo '{}')
      JOB_ID=$(echo "$CURRENT_JOB" | jq -r '.job_id // ""' 2>/dev/null)

      if [ -n "$JOB_ID" ] && [ "$JOB_ID" != "$LAST_JOB_ID" ]; then
        LAST_JOB_ID="$JOB_ID"
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] New job: $JOB_ID" >> "$LOG_DIR/void_flux_bridge.log"
      fi

      # If we have valid share components and a job, submit it
      if [ -n "$NONCE" ] && [ -n "$HASH" ] && [ -n "$JOB_ID" ]; then
        # Create stratum share
        SHARE_JSON=$(jq -n \
          --arg nonce "$NONCE" \
          --arg result "$HASH" \
          --arg job "$JOB_ID" \
          '{nonce_hex: $nonce, result_hex: $result, job_id: $job}')

        # Write to stratum.pending_share register
        SUBMIT_RESULT=$(curl -s -X POST "http://127.0.0.1:8789/stratum/pending_share" \
          -H "Content-Type: application/json" \
          --data "$SHARE_JSON" 2>/dev/null || echo '{}')

        # Log submission attempt
        echo "$SHARE_JSON" >> /tmp/stratum_submissions.jsonl
        SUBMISSIONS_ATTEMPTED=$((SUBMISSIONS_ATTEMPTED + 1))

        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Submission #$SUBMISSIONS_ATTEMPTED: venture=$VENTURE_ID syndrome=$SYNDROME" >> "$LOG_DIR/void_flux_bridge.log"
      fi

      CORRECTIONS_PROCESSED=$((CORRECTIONS_PROCESSED + 1))
    fi
  fi

  # Sleep before next cycle
  sleep 0.5
done
