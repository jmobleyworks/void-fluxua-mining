#!/bin/bash
#
# CF Nonce Submitter - Multi-Pool (Parallel Submission to Overcome Rate Limits)
#
# Instead of waiting for one pool's rate limit to clear,
# distribute nonces across 3 pools simultaneously:
# 1. Nanopool (xmr-us-east1.nanopool.org:14444)
# 2. MoneroOcean (gulf.moneroocean.stream:10128)
# 3. MineXMR (pool.minexmr.com:4444)
#
set -euo pipefail

source ~/.zshrc 2>/dev/null || true

# Configuration
MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-Johnmobley99@gmail.com}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-c70d7a88f87f8cf4b3cfd7971ca482dc9882d}"
KV_NAMESPACE_ID="70e7e9bffd4e4e599d1b727a815eb8a7"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

# Multi-Pool Targets
declare -A POOLS=(
  [nanopool]="xmr-us-east1.nanopool.org:14444"
  [ocean]="gulf.moneroocean.stream:10128"
  [minexmr]="pool.minexmr.com:4444"
)

LOG_DIR="${MASCOM_DIR}/mining_state"
mkdir -p "$LOG_DIR"
MAIN_LOG="${LOG_DIR}/multipool_submitter.log"

log_msg() {
  local pool="$1"
  local msg="$2"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$pool] $msg" | tee -a "$MAIN_LOG"
}

# Global stats
declare -A pool_worker_id
declare -A pool_job_id
declare -A pool_accepted
declare -A pool_rejected
declare -A pool_socket_fd

for pool in "${!POOLS[@]}"; do
  pool_worker_id[$pool]=""
  pool_job_id[$pool]=""
  pool_accepted[$pool]=0
  pool_rejected[$pool]=0
  pool_socket_fd[$pool]=""
done

submission_count=0
accepted_total=0
rejected_total=0

# Cleanup on exit
cleanup() {
  log_msg "main" "Shutting down all pool connections..."
  for pool in "${!POOLS[@]}"; do
    if [ -n "${pool_socket_fd[$pool]}" ]; then
      eval "exec ${pool_socket_fd[$pool]}>& -" 2>/dev/null || true
    fi
  done
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

log_msg "main" "Multi-Pool Nonce Submitter started"
log_msg "main" "Targets: ${!POOLS[@]}"

# Connect to a pool
connect_to_pool() {
  local pool="$1"
  local host_port="${POOLS[$pool]}"
  local host="${host_port%:*}"
  local port="${host_port#*:}"

  log_msg "$pool" "Connecting to $host:$port..."

  # Allocate new file descriptor (3, 4, 5)
  local fd=$((3 + $(echo "${!POOLS[@]}" | tr ' ' '\n' | sort | grep -n "^$pool" | cut -d: -f1) - 1))
  pool_socket_fd[$pool]=$fd

  if eval "exec $fd<>/dev/tcp/$host/$port"; then
    log_msg "$pool" "✓ Connected"
    return 0
  else
    log_msg "$pool" "✗ Connection failed"
    return 1
  fi
}

# Send message to pool
send_msg() {
  local pool="$1"
  local msg="$2"
  local fd="${pool_socket_fd[$pool]}"

  if [ -z "$fd" ]; then
    log_msg "$pool" "✗ No socket available"
    return 1
  fi

  eval "echo '$msg' >&$fd" || {
    log_msg "$pool" "✗ Send failed"
    return 1
  }
  return 0
}

# Receive response from pool
recv_response() {
  local pool="$1"
  local timeout="${2:-15}"
  local fd="${pool_socket_fd[$pool]}"

  if [ -z "$fd" ]; then
    log_msg "$pool" "✗ No socket available"
    return 1
  fi

  if eval "read -t $timeout response <&$fd"; then
    echo "$response"
    return 0
  else
    log_msg "$pool" "✗ Timeout ($timeout seconds)"
    return 1
  fi
}

# Authenticate with pool
authenticate_pool() {
  local pool="$1"
  local host_port="${POOLS[$pool]}"

  if ! connect_to_pool "$pool"; then
    return 1
  fi

  # Pool-specific login format
  local login_msg
  case "$pool" in
    nanopool)
      login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.multipool-nanopool\",\"pass\":\"\"}}"
      ;;
    ocean)
      login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}\",\"pass\":\"x\"}}"
      ;;
    minexmr)
      login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.multipool-minexmr\",\"pass\":\"x\"}}"
      ;;
  esac

  send_msg "$pool" "$login_msg" || return 1

  if login_response=$(recv_response "$pool" 10); then
    pool_worker_id[$pool]=$(echo "$login_response" | jq -r '.result.id // empty' 2>/dev/null)
    pool_job_id[$pool]=$(echo "$login_response" | jq -r '.result.job.job_id // empty' 2>/dev/null)

    if [ -n "${pool_worker_id[$pool]}" ] && [ -n "${pool_job_id[$pool]}" ]; then
      log_msg "$pool" "✓ Authenticated (worker ID: ${pool_worker_id[$pool]:0:12}..., job_id: ${pool_job_id[$pool]:0:16}...)"
      return 0
    else
      log_msg "$pool" "✗ Auth failed: $login_response"
      return 1
    fi
  else
    log_msg "$pool" "✗ No login response"
    return 1
  fi
}

# Initialize all pools
log_msg "main" "Initializing all pools..."
pools_ready=0
for pool in "${!POOLS[@]}"; do
  if authenticate_pool "$pool"; then
    ((pools_ready++))
  fi
done

if [ $pools_ready -eq 0 ]; then
  log_msg "main" "✗ No pools available!"
  exit 1
fi

log_msg "main" "✓ $pools_ready/${#POOLS[@]} pools ready. Starting submission..."

# Main submission loop
msg_id=2
nonce_batch_size=0

while true; do
  # Read pending nonces from CF KV (batch of 10)
  kv_list=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys?limit=100" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

  if echo "$kv_list" | jq -e '.success' > /dev/null 2>&1; then
    nonce_keys=$(echo "$kv_list" | jq -r '.result[].name' 2>/dev/null || true)
    key_count=$(echo "$nonce_keys" | grep . | wc -l)

    if [ "$key_count" -gt 0 ]; then
      log_msg "main" "Processing batch of $key_count nonces..."
    fi

    for key in $nonce_keys; do
      # Read the KV entry
      kv_value=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

      nonce=$(echo "$kv_value" | jq -r '.nonce // empty' 2>/dev/null)

      if [ -n "$nonce" ]; then
        # ROUND-ROBIN across pools: submit to all pools (not just one)
        for pool in "${!POOLS[@]}"; do
          if [ -z "${pool_worker_id[$pool]}" ]; then
            continue  # Skip if pool not authenticated
          fi

          submit_msg="{\"jsonrpc\":\"2.0\",\"id\":${msg_id},\"method\":\"submit\",\"params\":{\"id\":\"${pool_worker_id[$pool]}\",\"job_id\":\"${pool_job_id[$pool]}\",\"nonce\":\"${nonce}\",\"result\":\"${nonce}\"}}"

          if send_msg "$pool" "$submit_msg"; then
            if submit_response=$(recv_response "$pool" 15); then
              if echo "$submit_response" | jq -e '.result.status' > /dev/null 2>&1; then
                log_msg "$pool" "✓ Share accepted: ${nonce:0:20}..."
                ((pool_accepted[$pool]++))
                ((accepted_total++))
              elif echo "$submit_response" | jq -e '.error' > /dev/null 2>&1; then
                error_msg=$(echo "$submit_response" | jq -r '.error.message // "unknown"' 2>/dev/null)
                # Ignore "Duplicate share" and "Invalid job id" - just log silently
                if ! echo "$error_msg" | grep -q "Duplicate\|Invalid job"; then
                  log_msg "$pool" "✗ Error: ${nonce:0:20}... ($error_msg)"
                fi
                ((pool_rejected[$pool]++))
                ((rejected_total++))
              fi
            fi
            ((submission_count++))
          fi

          ((msg_id++))
        done

        # Delete from KV after submission to all pools
        curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys/${key}" \
          -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
          -H "X-Auth-Key: ${CF_GLOBAL_KEY}" > /dev/null 2>&1
      fi
    done

    # Log progress
    if [ "$key_count" -gt 0 ]; then
      log_msg "main" "Batch summary: $submission_count total submitted, $accepted_total accepted overall"
      for pool in "${!POOLS[@]}"; do
        log_msg "main" "  $pool: ${pool_accepted[$pool]} accepted, ${pool_rejected[$pool]} rejected"
      done
    fi
  fi

  sleep 1
done
