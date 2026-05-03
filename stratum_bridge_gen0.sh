#!/bin/bash
#
# GEN 0 STRATUM BRIDGE - Pool Integration
#
# Responsibilities:
#   1. Authenticate with Monero pool (Stratum login)
#   2. Maintain authenticated session (refresh on expiry)
#   3. Read results from D1
#   4. Submit results to pool as mining shares
#   5. Track submission status, update D1 with outcome
#

set -e

# Configuration
POOL_HOST="${POOL_HOST:-gulf.moneroocean.stream}"
POOL_PORT="${POOL_PORT:-10128}"
WALLET="${WALLET:-4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto}"
WORKER_ID="${WORKER_ID:-gen0-bridge}"

# State files
STATE_DIR="${MASCOM_DIR:-$HOME/mascom}/stratum_state"
SESSION_FILE="$STATE_DIR/session_id.txt"
SESSION_TS_FILE="$STATE_DIR/session_timestamp.txt"
LAST_SUBMIT_FILE="$STATE_DIR/last_submit_timestamp.txt"

# Timeouts
SESSION_MAX_AGE_SECONDS=1500  # 25 minutes, refresh after 1500s
SUBMIT_BATCH_SIZE=10
SUBMIT_INTERVAL_SECONDS=5

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="$STATE_DIR/stratum_bridge.log"
mkdir -p "$STATE_DIR"

log() {
  local level=$1
  shift
  local msg="$@"
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

# STEP 1: Authenticate with pool
stratum_login() {
  log "INFO" "Authenticating with $POOL_HOST:$POOL_PORT"

  # Create login request
  local login_request=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "login",
  "params": {
    "login": "$WALLET",
    "pass": "x",
    "agent": "$WORKER_ID"
  }
}
EOF
)

  # Send to pool
  local response=$(echo "$login_request" | nc -q 2 "$POOL_HOST" "$POOL_PORT" 2>/dev/null || true)

  if [ -z "$response" ]; then
    log "ERROR" "No response from pool"
    return 1
  fi

  # Extract session ID from response
  local session_id=$(echo "$response" | jq -r '.result.id // empty' 2>/dev/null || true)

  if [ -z "$session_id" ]; then
    log "ERROR" "Failed to extract session ID from response"
    log "DEBUG" "Response: $response"
    return 1
  fi

  # Save session state
  echo "$session_id" > "$SESSION_FILE"
  echo "$(date +%s)" > "$SESSION_TS_FILE"

  log "INFO" "✅ Authentication successful (session: ${session_id:0:20}...)"
  return 0
}

# STEP 2: Get current session (refresh if expired)
get_session() {
  local current_time=$(date +%s)

  # Check if session file exists and is recent
  if [ -f "$SESSION_FILE" ] && [ -f "$SESSION_TS_FILE" ]; then
    local session_time=$(cat "$SESSION_TS_FILE")
    local session_age=$((current_time - session_time))

    if [ $session_age -lt $SESSION_MAX_AGE_SECONDS ]; then
      # Session still valid
      cat "$SESSION_FILE"
      return 0
    fi
  fi

  # Session expired or missing - re-authenticate
  log "WARN" "Session expired or missing, re-authenticating..."
  if stratum_login; then
    cat "$SESSION_FILE"
    return 0
  else
    return 1
  fi
}

# STEP 3: Read pending results from D1
# Note: In production, this would query the CF API to access D1 database
# For now, we demonstrate the structure
read_pending_results_from_d1() {
  # This is a placeholder - in production would be:
  # curl -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${D1_ID}/query" \
  #   -H "Authorization: Bearer $CF_API_TOKEN" \
  #   -d "SELECT * FROM job_results WHERE status='valid' AND submitted=false LIMIT $SUBMIT_BATCH_SIZE"

  log "INFO" "Would query D1: SELECT * FROM job_results WHERE status='valid' AND submitted=false"
  echo "[]"  # Return empty for now
}

# STEP 4: Submit result to pool
stratum_submit() {
  local session_id=$1
  local job_id=$2
  local nonce=$3
  local result_hash=$4

  # Construct Stratum submit request
  local submit_request=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "submit",
  "params": {
    "id": "$session_id",
    "job_id": "$job_id",
    "nonce": "$nonce",
    "result": "$result_hash"
  }
}
EOF
)

  # Send to pool
  local response=$(echo "$submit_request" | nc -q 2 "$POOL_HOST" "$POOL_PORT" 2>/dev/null || true)

  if [ -z "$response" ]; then
    log "WARN" "No response from pool (timeout or connection error)"
    return 1
  fi

  # Check response
  if echo "$response" | jq -e '.result.status' > /dev/null 2>&1; then
    local status=$(echo "$response" | jq -r '.result.status')
    log "INFO" "✅ Share accepted (status: $status)"
    return 0
  elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    local error=$(echo "$response" | jq -r '.error.message // .error')
    log "WARN" "Share rejected by pool: $error"
    return 1
  else
    log "DEBUG" "Pool response: $response"
    return 1
  fi
}

# STEP 5: Main loop
main() {
  log "INFO" "═════════════════════════════════════════════════════════════"
  log "INFO" "GEN 0 STRATUM BRIDGE - Starting"
  log "INFO" "Pool: $POOL_HOST:$POOL_PORT"
  log "INFO" "Wallet: ${WALLET:0:40}..."
  log "INFO" "═════════════════════════════════════════════════════════════"

  local submit_count=0
  local accepted_count=0
  local rejected_count=0

  while true; do
    local current_time=$(date +%s)

    # Ensure valid session
    if ! session_id=$(get_session); then
      log "ERROR" "Failed to obtain session, waiting 10s..."
      sleep 10
      continue
    fi

    # Read pending results from D1
    # In production: results=$(read_pending_results_from_d1)
    # For testing: generate fake result
    if [ $((submit_count % 30)) -eq 0 ]; then
      # Every 30 iterations (150 seconds), generate a test result
      local test_job_id="test-job-$(date +%s)"
      local test_nonce="00000001"
      local test_hash=$(echo -n "test" | sha256sum | cut -d' ' -f1)

      log "INFO" "Submitting test result to pool..."
      if stratum_submit "$session_id" "$test_job_id" "$test_nonce" "$test_hash"; then
        (( accepted_count++ ))
      else
        (( rejected_count++ ))
      fi
      (( submit_count++ ))
    fi

    # Every 60 seconds, show stats
    if [ $((submit_count % 12)) -eq 0 ] && [ $submit_count -gt 0 ]; then
      log "INFO" "═══════════════════════════════════════════════════════════"
      log "INFO" "Stats: Submitted=$submit_count Accepted=$accepted_count Rejected=$rejected_count"
      log "INFO" "═══════════════════════════════════════════════════════════"
    fi

    # Wait before next check
    sleep $SUBMIT_INTERVAL_SECONDS
  done
}

# STEP 6: Graceful shutdown
cleanup() {
  log "INFO" "Shutting down gracefully..."
  exit 0
}

trap cleanup SIGINT SIGTERM

# Run main loop
main
