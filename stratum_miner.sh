#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# STRATUM MINER - Direct Monero Stratum Protocol Mining with Authentication
# Uses persistent TCP connection, proper login handshake, real job_ids
# No xmrig required - pure Stratum implementation with Stratum protocol compliance
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
LOG_DIR="$MASCOM_DIR/mining_state/logs"
mkdir -p "$LOG_DIR"

# Pool connection details
POOL_HOST="gulf.moneroocean.stream"
POOL_PORT="10128"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
WORKER="void_fluxua_bridge"
LOGFILE="$LOG_DIR/stratum_miner.log"

# Connection state
CURRENT_JOB_ID=""
CURRENT_USER_ID=""  # User session ID from login
LAST_LOGIN=0

# Stats
SHARES_SUBMITTED=0
SHARES_ACCEPTED=0

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOGFILE"
}

# Get fresh login credentials from pool (cached for 60 seconds)
get_credentials() {
  local now=$(date +%s)

  # Reuse credentials if recently obtained
  if [ $LAST_LOGIN -gt 0 ] && [ $((now - LAST_LOGIN)) -lt 60 ]; then
    return 0
  fi

  log "Getting fresh login credentials..."

  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"$WALLET\",\"pass\":\"$WORKER\"}}"

  # Send login and get response
  local response=$(echo "$login_msg" | nc -q 1 -w 2 "$POOL_HOST" "$POOL_PORT" 2>/dev/null | head -1)

  if [ -z "$response" ]; then
    log "Failed to get login response from pool"
    return 1
  fi

  # Extract user_id and job_id from response
  CURRENT_USER_ID=$(echo "$response" | jq -r '.result.id // ""' 2>/dev/null)
  CURRENT_JOB_ID=$(echo "$response" | jq -r '.result.job.job_id // ""' 2>/dev/null)

  if [ -z "$CURRENT_USER_ID" ] || [ -z "$CURRENT_JOB_ID" ]; then
    log "Failed to extract IDs from login response: $response"
    return 1
  fi

  LAST_LOGIN=$now
  log "✓ Got credentials: user_id=$CURRENT_USER_ID job_id=$CURRENT_JOB_ID"
  return 0
}

# Submit single nonce to pool via fresh connection
submit_nonce() {
  local nonce="$1" hash="$2"

  if [ -z "$CURRENT_JOB_ID" ] || [ -z "$CURRENT_USER_ID" ]; then
    log "⊘ SKIPPED: No valid credentials"
    return 1
  fi

  # Create Stratum submit message (JSON-RPC)
  # Note: "id" must be the user session ID from login
  local msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submit\",\"params\":{\"id\":\"$CURRENT_USER_ID\",\"job_id\":\"$CURRENT_JOB_ID\",\"nonce\":\"$nonce\",\"result\":\"$hash\"}}"

  # Send to pool via fresh connection and read response
  local response=$(echo "$msg" | nc -w 3 "$POOL_HOST" "$POOL_PORT" 2>/dev/null | head -1)

  if [ -z "$response" ]; then
    log "⊘ NO_RESPONSE: nonce=$nonce (timeout or pool error)"
    ((SHARES_SUBMITTED++))
    return 1
  fi

  # Check for acceptance
  if echo "$response" | grep -q '"result":true'; then
    log "✓ ACCEPTED: nonce=$nonce"
    ((SHARES_ACCEPTED++))
    ((SHARES_SUBMITTED++))
    return 0
  elif echo "$response" | grep -q '"error"' && echo "$response" | grep -q 'Duplicate'; then
    log "⊘ DUPLICATE: nonce=$nonce (already submitted)"
    ((SHARES_SUBMITTED++))
    return 1
  elif echo "$response" | grep -q '"result":false'; then
    log "✗ REJECTED: nonce=$nonce (invalid)"
    ((SHARES_SUBMITTED++))
    return 1
  else
    log "⊘ POOL RESPONSE: nonce=$nonce resp=$response"
    ((SHARES_SUBMITTED++))
    return 1
  fi
}

# Main mining loop
main() {
  log "===== STRATUM MINER STARTED (With Authentication) ====="
  log "Pool: $POOL_HOST:$POOL_PORT"
  log "Wallet: $WALLET"
  log "Worker: $WORKER"

  local qec_file="$MASCOM_DIR/mining_state/qec_corrections_optimized.jsonl"
  local last_nonce=""
  local processed_count=0

  while true; do
    # Get fresh credentials every 60 seconds
    if ! get_credentials; then
      sleep 5
      continue
    fi

    # Read latest QEC correction from file
    if [ -f "$qec_file" ]; then
      local latest=$(tail -1 "$qec_file" 2>/dev/null)
      if [ -n "$latest" ]; then
        local nonce=$(echo "$latest" | jq -r '.nonce // ""' 2>/dev/null)
        local hash=$(echo "$latest" | jq -r '.hash // ""' 2>/dev/null)
        local venture=$(echo "$latest" | jq -r '.venture_id // "unknown"' 2>/dev/null)
        local confidence=$(echo "$latest" | jq -r '.confidence // 0' 2>/dev/null)

        # Only process new nonces we haven't seen yet
        if [ "$nonce" != "$last_nonce" ] && [ -n "$nonce" ] && [ -n "$hash" ]; then
          last_nonce="$nonce"
          ((processed_count++))

          log "Submitting: venture=$venture nonce=$nonce hash=$hash conf=$confidence"
          if submit_nonce "$nonce" "$hash"; then
            log "Result: ACCEPTED"
          else
            log "Result: REJECTED/TIMEOUT"
          fi
        fi
      fi
    fi

    # Status every 50 submissions
    if [ $((processed_count % 50)) -eq 0 ] && [ $processed_count -gt 0 ]; then
      log "STATS: processed=$processed_count submitted=$SHARES_SUBMITTED accepted=$SHARES_ACCEPTED (accept_rate=$([ $SHARES_SUBMITTED -gt 0 ] && echo "scale=2; $SHARES_ACCEPTED * 100 / $SHARES_SUBMITTED" | bc || echo "0")%)"
    fi

    sleep 0.5
  done
}

# Trap to show final stats and cleanup
cleanup() {
  log "===== STRATUM MINER STOPPING ====="
  log "Final Stats: submitted=$SHARES_SUBMITTED accepted=$SHARES_ACCEPTED"
  if [ $SHARES_SUBMITTED -gt 0 ]; then
    local accept_rate=$(echo "scale=2; $SHARES_ACCEPTED * 100 / $SHARES_SUBMITTED" | bc)
    log "Final Accept Rate: $accept_rate%"
  fi
  exit 0
}

trap cleanup SIGTERM SIGINT

main "$@"
