#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# STRATUM MINER - Multi-Pool Direct Monero Stratum Protocol Mining
# Submits shares to multiple pools in parallel for revenue maximization
# Pools: Nanopool (primary), MoneroOcean (secondary)
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
LOG_DIR="$MASCOM_DIR/mining_state/logs"
mkdir -p "$LOG_DIR"

# Mining credentials
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
WORKER="void_fluxua_bridge"

# Pool 1: Nanopool
NANOPOOL_HOST="xmr-us-east1.nanopool.org"
NANOPOOL_PORT="14444"
NANOPOOL_USER_ID=""
NANOPOOL_JOB_ID=""
NANOPOOL_LAST_LOGIN=0
NANOPOOL_SUBMITTED=0
NANOPOOL_ACCEPTED=0

# Pool 2: MoneroOcean
OCEAN_HOST="gulf.moneroocean.stream"
OCEAN_PORT="10128"
OCEAN_USER_ID=""
OCEAN_JOB_ID=""
OCEAN_LAST_LOGIN=0
OCEAN_SUBMITTED=0
OCEAN_ACCEPTED=0

# Global stats
SHARES_SUBMITTED=0
SHARES_ACCEPTED=0

LOGFILE="$LOG_DIR/stratum_miner_multipool.log"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOGFILE"
}

# Get credentials from Nanopool
get_nanopool_credentials() {
  local now=$(date +%s)

  # Reuse if fresh (within 60 seconds)
  if [ $NANOPOOL_LAST_LOGIN -gt 0 ] && [ $((now - NANOPOOL_LAST_LOGIN)) -lt 60 ]; then
    return 0
  fi

  log "[Nanopool] Getting fresh credentials..."

  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"$WALLET.$WORKER\",\"pass\":\"\"}}"
  local response=$(echo "$login_msg" | nc -w 2 "$NANOPOOL_HOST" "$NANOPOOL_PORT" 2>/dev/null | head -1 || echo "")

  if [ -z "$response" ]; then
    log "[Nanopool] Failed to get login response"
    return 1
  fi

  NANOPOOL_USER_ID=$(echo "$response" | jq -r '.result.id // ""' 2>/dev/null)
  NANOPOOL_JOB_ID=$(echo "$response" | jq -r '.result.job.job_id // ""' 2>/dev/null)

  if [ -z "$NANOPOOL_USER_ID" ] || [ -z "$NANOPOOL_JOB_ID" ]; then
    log "[Nanopool] Failed to extract IDs"
    return 1
  fi

  NANOPOOL_LAST_LOGIN=$now
  log "[Nanopool] ✓ Login OK (user_id=$NANOPOOL_USER_ID job_id=$NANOPOOL_JOB_ID)"
  return 0
}

# Get credentials from MoneroOcean
get_ocean_credentials() {
  local now=$(date +%s)

  if [ $OCEAN_LAST_LOGIN -gt 0 ] && [ $((now - OCEAN_LAST_LOGIN)) -lt 60 ]; then
    return 0
  fi

  log "[MoneroOcean] Getting fresh credentials..."

  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"$WALLET\",\"pass\":\"$WORKER\"}}"
  local response=$(echo "$login_msg" | nc -w 2 "$OCEAN_HOST" "$OCEAN_PORT" 2>/dev/null | head -1 || echo "")

  if [ -z "$response" ]; then
    log "[MoneroOcean] Failed to get login response"
    return 1
  fi

  OCEAN_USER_ID=$(echo "$response" | jq -r '.result.id // ""' 2>/dev/null)
  OCEAN_JOB_ID=$(echo "$response" | jq -r '.result.job.job_id // ""' 2>/dev/null)

  if [ -z "$OCEAN_USER_ID" ] || [ -z "$OCEAN_JOB_ID" ]; then
    log "[MoneroOcean] Failed to extract IDs"
    return 1
  fi

  OCEAN_LAST_LOGIN=$now
  log "[MoneroOcean] ✓ Login OK (user_id=$OCEAN_USER_ID job_id=$OCEAN_JOB_ID)"
  return 0
}

# Submit to Nanopool
submit_to_nanopool() {
  local nonce="$1" hash="$2"

  if [ -z "$NANOPOOL_JOB_ID" ] || [ -z "$NANOPOOL_USER_ID" ]; then
    return 1
  fi

  local msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submit\",\"params\":{\"id\":\"$NANOPOOL_USER_ID\",\"job_id\":\"$NANOPOOL_JOB_ID\",\"nonce\":\"$nonce\",\"result\":\"$hash\"}}"
  local response=$(echo "$msg" | nc -w 3 "$NANOPOOL_HOST" "$NANOPOOL_PORT" 2>/dev/null | head -1 || echo "")

  if [ -z "$response" ]; then
    log "[Nanopool] ⊘ NO_RESPONSE: $nonce"
    ((NANOPOOL_SUBMITTED++))
    return 1
  fi

  if echo "$response" | grep -q '"result":true'; then
    log "[Nanopool] ✓ ACCEPTED: $nonce"
    ((NANOPOOL_ACCEPTED++))
    ((NANOPOOL_SUBMITTED++))
    ((SHARES_ACCEPTED++))
    return 0
  else
    log "[Nanopool] ⊘ REJECTED/NO_ACCEPT: $nonce"
    ((NANOPOOL_SUBMITTED++))
    return 1
  fi
}

# Submit to MoneroOcean
submit_to_ocean() {
  local nonce="$1" hash="$2"

  if [ -z "$OCEAN_JOB_ID" ] || [ -z "$OCEAN_USER_ID" ]; then
    return 1
  fi

  local msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submit\",\"params\":{\"id\":\"$OCEAN_USER_ID\",\"job_id\":\"$OCEAN_JOB_ID\",\"nonce\":\"$nonce\",\"result\":\"$hash\"}}"
  local response=$(echo "$msg" | nc -w 3 "$OCEAN_HOST" "$OCEAN_PORT" 2>/dev/null | head -1 || echo "")

  if [ -z "$response" ]; then
    log "[MoneroOcean] ⊘ NO_RESPONSE: $nonce"
    ((OCEAN_SUBMITTED++))
    return 1
  fi

  if echo "$response" | grep -q '"result":true'; then
    log "[MoneroOcean] ✓ ACCEPTED: $nonce"
    ((OCEAN_ACCEPTED++))
    ((OCEAN_SUBMITTED++))
    ((SHARES_ACCEPTED++))
    return 0
  else
    log "[MoneroOcean] ⊘ REJECTED/NO_ACCEPT: $nonce"
    ((OCEAN_SUBMITTED++))
    return 1
  fi
}

# Main mining loop
main() {
  log "===== STRATUM MINER (MULTI-POOL) STARTED ====="
  log "Wallet: $WALLET"
  log "Pools: Nanopool + MoneroOcean"

  local qec_file="$MASCOM_DIR/mining_state/qec_corrections_optimized.jsonl"
  local last_nonce=""
  local processed_count=0

  while true; do
    # Get fresh credentials from both pools
    get_nanopool_credentials || true
    get_ocean_credentials || true

    # Read latest QEC correction
    if [ -f "$qec_file" ]; then
      local latest=$(tail -1 "$qec_file" 2>/dev/null || echo "")
      if [ -n "$latest" ]; then
        local nonce=$(echo "$latest" | jq -r '.nonce // ""' 2>/dev/null)
        local hash=$(echo "$latest" | jq -r '.hash // ""' 2>/dev/null)
        local venture=$(echo "$latest" | jq -r '.venture_id // ""' 2>/dev/null)

        # Only process new nonces
        if [ "$nonce" != "$last_nonce" ] && [ -n "$nonce" ] && [ -n "$hash" ]; then
          last_nonce="$nonce"
          ((processed_count++))

          # Submit to both pools in parallel
          log "Submitting to both pools: venture=$venture nonce=$nonce"

          submit_to_nanopool "$nonce" "$hash" &
          NANO_PID=$!

          submit_to_ocean "$nonce" "$hash" &
          OCEAN_PID=$!

          wait $NANO_PID $OCEAN_PID 2>/dev/null || true

          ((SHARES_SUBMITTED++))
        fi
      fi
    fi

    # Status every 50 submissions
    if [ $((processed_count % 50)) -eq 0 ] && [ $processed_count -gt 0 ]; then
      log "GLOBAL: processed=$processed_count submitted=$SHARES_SUBMITTED accepted=$SHARES_ACCEPTED"
      log "[Nanopool] submitted=$NANOPOOL_SUBMITTED accepted=$NANOPOOL_ACCEPTED"
      log "[MoneroOcean] submitted=$OCEAN_SUBMITTED accepted=$OCEAN_ACCEPTED"
    fi

    sleep 0.5
  done
}

# Cleanup on exit
cleanup() {
  log "===== STRATUM MINER (MULTI-POOL) STOPPING ====="
  log "Global: submitted=$SHARES_SUBMITTED accepted=$SHARES_ACCEPTED"
  log "Nanopool: submitted=$NANOPOOL_SUBMITTED accepted=$NANOPOOL_ACCEPTED"
  log "MoneroOcean: submitted=$OCEAN_SUBMITTED accepted=$OCEAN_ACCEPTED"
  exit 0
}

trap cleanup SIGTERM SIGINT

main "$@"
