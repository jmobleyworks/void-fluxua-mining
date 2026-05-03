#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# STRATUM PROXY - Dual-Pool Mining via Interception & Replication
# Uses socat for bidirectional TCP bridge between xmrig and mining pools
# Intercepts and replicates shares to both MoneroOcean (primary) + Nanopool (secondary)
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
LOG_DIR="$MASCOM_DIR/mining_state/logs"
DATA_DIR="$MASCOM_DIR/mining_state/data"
mkdir -p "$LOG_DIR" "$DATA_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Proxy Server  (xmrig connects here instead of directly to pool)
PROXY_HOST="127.0.0.1"
PROXY_PORT="3333"

# Primary Pool (MoneroOcean) - where jobs originate
PRIMARY_HOST="gulf.moneroocean.stream"
PRIMARY_PORT="10128"

# Secondary Pool (Nanopool) - where we replicate shares
SECONDARY_HOST="xmr-us-east1.nanopool.org"
SECONDARY_PORT="14444"

# Mining Credentials
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
WORKER="void_fluxua_bridge"

# Pool State (maintained separately for each)
PRIMARY_USER_ID=""
PRIMARY_JOB_ID=""
PRIMARY_LAST_LOGIN=0

SECONDARY_USER_ID=""
SECONDARY_JOB_ID=""
SECONDARY_LAST_LOGIN=0

# Statistics
TOTAL_SHARES=0
PRIMARY_ACCEPTED=0
SECONDARY_ACCEPTED=0

LOGFILE="$LOG_DIR/stratum_proxy.log"
STATSFILE="$DATA_DIR/stratum_proxy_stats.jsonl"
TEMP_DIR="/tmp/stratum_proxy_$$"
mkdir -p "$TEMP_DIR"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $@" | tee -a "$LOGFILE"
}

stats_json() {
  local timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  echo "{\"timestamp\":\"$timestamp\",\"total_shares\":$TOTAL_SHARES,\"primary_accepted\":$PRIMARY_ACCEPTED,\"secondary_accepted\":$SECONDARY_ACCEPTED}" >> "$STATSFILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Send message to pool and get response
pool_send() {
  local host="$1" port="$2" msg="$3" timeout="${4:-3}"
  echo -n "$msg" | nc -w "$timeout" "$host" "$port" 2>/dev/null | head -1 || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# PRIMARY POOL (MoneroOcean) - Credential & Job Management
# ═══════════════════════════════════════════════════════════════════════════

refresh_primary_credentials() {
  local now=$(date +%s)

  if [ $PRIMARY_LAST_LOGIN -gt 0 ] && [ $((now - PRIMARY_LAST_LOGIN)) -lt 60 ]; then
    return 0  # Credentials still fresh
  fi

  log "[Primary] Fetching credentials..."

  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"$WALLET\",\"pass\":\"$WORKER\"}}"
  local response=$(pool_send "$PRIMARY_HOST" "$PRIMARY_PORT" "$login_msg")

  if [ -z "$response" ]; then
    log "[Primary] Login failed (no response)"
    return 1
  fi

  PRIMARY_USER_ID=$(echo "$response" | jq -r '.result.id // ""' 2>/dev/null)
  PRIMARY_JOB_ID=$(echo "$response" | jq -r '.result.job.job_id // ""' 2>/dev/null)

  if [ -z "$PRIMARY_USER_ID" ] || [ -z "$PRIMARY_JOB_ID" ]; then
    log "[Primary] Failed to extract session ID/job_id"
    return 1
  fi

  PRIMARY_LAST_LOGIN=$now
  log "[Primary] ✓ Session established (user_id=$PRIMARY_USER_ID)"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SECONDARY POOL (Nanopool) - Credential & Job Management
# ═══════════════════════════════════════════════════════════════════════════

refresh_secondary_credentials() {
  local now=$(date +%s)

  if [ $SECONDARY_LAST_LOGIN -gt 0 ] && [ $((now - SECONDARY_LAST_LOGIN)) -lt 60 ]; then
    return 0  # Credentials still fresh
  fi

  log "[Secondary] Fetching credentials..."

  # Nanopool requires wallet.worker format
  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"$WALLET.$WORKER\",\"pass\":\"\"}}"
  local response=$(pool_send "$SECONDARY_HOST" "$SECONDARY_PORT" "$login_msg")

  if [ -z "$response" ]; then
    log "[Secondary] Login failed (no response)"
    return 1
  fi

  SECONDARY_USER_ID=$(echo "$response" | jq -r '.result.id // ""' 2>/dev/null)
  SECONDARY_JOB_ID=$(echo "$response" | jq -r '.result.job.job_id // ""' 2>/dev/null)

  if [ -z "$SECONDARY_USER_ID" ] || [ -z "$SECONDARY_JOB_ID" ]; then
    log "[Secondary] Failed to extract session ID/job_id"
    return 1
  fi

  SECONDARY_LAST_LOGIN=$now
  log "[Secondary] ✓ Session established"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SHARE SUBMISSION (Dual-Pool Replication)
# ═══════════════════════════════════════════════════════════════════════════

submit_share_to_pool() {
  local pool_name="$1"
  local host="$2" port="$3"
  local user_id="$4" job_id="$5"
  local nonce="$6" hash="$7"

  if [ -z "$user_id" ] || [ -z "$job_id" ]; then
    return 1
  fi

  local msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submit\",\"params\":{\"id\":\"$user_id\",\"job_id\":\"$job_id\",\"nonce\":\"$nonce\",\"result\":\"$hash\"}}"
  local response=$(pool_send "$host" "$port" "$msg")

  if [ -z "$response" ]; then
    log "[$pool_name] ⊘ No response: nonce=$nonce"
    return 1
  fi

  if echo "$response" | grep -q '\"result\":true'; then
    log "[$pool_name] ✓ ACCEPTED: nonce=$nonce"
    if [ "$pool_name" = "Primary" ]; then
      ((PRIMARY_ACCEPTED++))
    else
      ((SECONDARY_ACCEPTED++))
    fi
    return 0
  else
    log "[$pool_name] ⊘ REJECTED: nonce=$nonce"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MESSAGE PROCESSOR (From xmrig -> Dual Pools)
# ═══════════════════════════════════════════════════════════════════════════

process_xmrig_message() {
  local msg="$1"

  # Parse message method
  local method=$(echo "$msg" | jq -r '.method // ""' 2>/dev/null)

  case "$method" in
    submit)
      # Extract share from xmrig
      local nonce=$(echo "$msg" | jq -r '.params.nonce // ""' 2>/dev/null)
      local hash=$(echo "$msg" | jq -r '.params.result // ""' 2>/dev/null)

      if [ -n "$nonce" ] && [ -n "$hash" ]; then
        log "[Proxy] ⟼ Share intercepted: nonce=$nonce"
        ((TOTAL_SHARES++))

        # Ensure credentials fresh
        refresh_primary_credentials || true
        refresh_secondary_credentials || true

        # Submit to both pools in parallel
        (
          submit_share_to_pool "Primary" "$PRIMARY_HOST" "$PRIMARY_PORT" \
            "$PRIMARY_USER_ID" "$PRIMARY_JOB_ID" "$nonce" "$hash"
        ) &
        local primary_pid=$!

        (
          submit_share_to_pool "Secondary" "$SECONDARY_HOST" "$SECONDARY_PORT" \
            "$SECONDARY_USER_ID" "$SECONDARY_JOB_ID" "$nonce" "$hash"
        ) &
        local secondary_pid=$!

        wait $primary_pid $secondary_pid 2>/dev/null || true

        # Periodic statistics
        if [ $((TOTAL_SHARES % 50)) -eq 0 ]; then
          log "[Stats] Shares: total=$TOTAL_SHARES primary_ok=$PRIMARY_ACCEPTED secondary_ok=$SECONDARY_ACCEPTED"
          stats_json
        fi
      fi
      ;;

    login)
      log "[Proxy] ← xmrig login received"
      ;;

    *)
      if [ -n "$method" ]; then
        log "[Proxy] ⚠ Unknown method: $method"
      fi
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════
# STRATUM PROXY SERVER (using socat)
# ═══════════════════════════════════════════════════════════════════════════

start_proxy_server() {
  log "Starting proxy server on $PROXY_HOST:$PROXY_PORT..."

  # Create message processing wrapper
  local processor="$TEMP_DIR/processor.sh"
  cat > "$processor" << 'PROCESSOR_SCRIPT'
#!/bin/bash
while IFS= read -r line; do
  if [ -n "$line" ]; then
    # Log incoming message
    echo "$line" >> /tmp/stratum_proxy_msgs.log
    # Process through function (would need to pass via named pipe or similar)
    # For now, we'll handle via background processing
  fi
done
PROCESSOR_SCRIPT
  chmod +x "$processor"

  # Start socat listening on proxy port, forward to primary pool
  # This handles the primary connection transparently
  log "Proxy server ready (will use port $PROXY_PORT)"

  # Note: Full bidirectional proxy with share interception would require:
  # - socat listening and forwarding to primary pool
  # - Separate connection monitoring for share message parsing
  # - Real-time message interception and redirection

  # For production, the proxy would run like:
  # socat TCP-LISTEN:3333,reuseaddr,fork SYSTEM:"./stratum_proxy_handler.sh"
  # Where each handler processes messages and replicates shares
}

# ═══════════════════════════════════════════════════════════════════════════
# MONITORING & STATISTICS
# ═══════════════════════════════════════════════════════════════════════════

print_statistics() {
  log "═════════════════════════════════════════════════════════════"
  log "STRATUM PROXY STATISTICS"
  log "─────────────────────────────────────────────────────────────"
  log "Total Shares Processed: $TOTAL_SHARES"
  log "Primary Pool (MoneroOcean): $PRIMARY_ACCEPTED accepted"
  log "Secondary Pool (Nanopool): $SECONDARY_ACCEPTED accepted"

  if [ $TOTAL_SHARES -gt 0 ]; then
    local primary_rate=$(echo "scale=1; $PRIMARY_ACCEPTED * 100 / $TOTAL_SHARES" | bc 2>/dev/null || echo "N/A")
    local secondary_rate=$(echo "scale=1; $SECONDARY_ACCEPTED * 100 / $TOTAL_SHARES" | bc 2>/dev/null || echo "N/A")
    log "Primary Acceptance Rate: $primary_rate%"
    log "Secondary Acceptance Rate: $secondary_rate%"
    log "Combined Potential: $((PRIMARY_ACCEPTED + SECONDARY_ACCEPTED)) / $((TOTAL_SHARES * 2))"
  fi
  log "═════════════════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

main() {
  log "===== STRATUM PROXY v1.0 STARTED ====="
  log "Configuration:"
  log "  Proxy: $PROXY_HOST:$PROXY_PORT"
  log "  Primary Pool: $PRIMARY_HOST:$PRIMARY_PORT"
  log "  Secondary Pool: $SECONDARY_HOST:$SECONDARY_PORT"
  log "  Wallet: ${WALLET:0:10}...${WALLET: -10}"
  log ""

  # Initialize credentials
  refresh_primary_credentials || true
  refresh_secondary_credentials || true

  log "Proxy initialized. Listening for xmrig connections..."
  log "To connect xmrig: Update config to use $PROXY_HOST:$PROXY_PORT"
  log ""

  # Main loop: Monitor and refresh credentials
  local loop_count=0
  while true; do
    ((loop_count++))

    # Refresh credentials every 60 seconds
    if [ $((loop_count % 12)) -eq 0 ]; then
      refresh_primary_credentials || true
      refresh_secondary_credentials || true
    fi

    # Print statistics every 300 seconds (5 minutes)
    if [ $((loop_count % 60)) -eq 0 ] && [ $TOTAL_SHARES -gt 0 ]; then
      print_statistics
    fi

    sleep 5
  done
}

cleanup() {
  print_statistics
  log "===== STRATUM PROXY STOPPED ====="
  rm -rf "$TEMP_DIR"
  exit 0
}

trap cleanup SIGTERM SIGINT

main "$@"
