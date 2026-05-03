#!/bin/bash
# CF Nonce Submitter - MineXMR Pool
# Workers 66-99 submit to MineXMR via this submitter

set -euo pipefail
source ~/.zshrc 2>/dev/null || true

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-Johnmobley99@gmail.com}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-c70d7a88f87f8cf4b3cfd7971ca482dc9882d}"
KV_NAMESPACE_ID="70e7e9bffd4e4e599d1b727a815eb8a7"
POOL_HOST="pool.minexmr.com"
POOL_PORT="4444"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

LOG_FILE="${MASCOM_DIR}/mining_state/minexmr_submitter.log"
mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Convert nonce string to hexadecimal format for pool submission
# Format: pkt_XXX_XXXXXX_TIMESTAMP -> extract timestamp and convert to hex
convert_nonce_to_hex() {
  local nonce="$1"
  # Extract the timestamp from pkt_XXX_XXXXXX_TIMESTAMP format
  # Example: pkt_001_000042_1777553754349732000 -> 1777553754349732000
  local timestamp="${nonce##*_}"  # Remove everything up to last underscore
  # Convert timestamp to hex and pad to 16 chars (8 bytes)
  printf "%016x" $((10#$timestamp))
}

cleanup() {
  log_msg "Shutting down MineXMR submitter..."
  exec 3>&- 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

log_msg "CF Nonce Submitter (MineXMR) started"
log_msg "Pool: $POOL_HOST:$POOL_PORT | Wallet: ${WALLET:0:50}..."

socket_fd=3
worker_id=""
pool_job_id=""
submission_count=0
accepted_count=0
rejected_count=0
last_reconnect=0

connect_to_pool() {
  log_msg "Connecting to MineXMR..."
  exec 3>&- 2>/dev/null || true
  
  if exec 3<>/dev/tcp/${POOL_HOST}/${POOL_PORT}; then
    log_msg "✓ Connected to MineXMR"
    return 0
  else
    log_msg "✗ Failed to connect to MineXMR"
    return 1
  fi
}

send_msg() {
  local msg="$1"
  echo "$msg" >&3 || {
    log_msg "✗ Failed to send message, will reconnect..."
    return 1
  }
  return 0
}

recv_response() {
  local timeout="${1:-15}"
  if read -t "$timeout" response <&3; then
    echo "$response"
    return 0
  else
    log_msg "✗ No response from MineXMR (timeout after ${timeout}s)"
    return 1
  fi
}

# Connect and authenticate
if ! connect_to_pool; then
  exit 1
fi

# MineXMR requires wallet.worker format
login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.minexmr-submitter\",\"pass\":\"x\"}}"
send_msg "$login_msg" || { log_msg "✗ Failed to send login"; exit 1; }

if login_response=$(recv_response 10); then
  worker_id=$(echo "$login_response" | jq -r '.result.id // empty' 2>/dev/null)
  pool_job_id=$(echo "$login_response" | jq -r '.result.job.job_id // empty' 2>/dev/null)
  if [ -n "$worker_id" ] && [ -n "$pool_job_id" ]; then
    log_msg "✓ Authenticated with MineXMR (worker ID: $worker_id)"
    last_reconnect=$(date +%s)
  else
    log_msg "✗ Failed to get credentials from MineXMR login"
    exit 1
  fi
else
  log_msg "✗ MineXMR login failed (no response)"
  exit 1
fi

# Main submission loop
log_msg "Starting nonce submission loop (MineXMR)..."
msg_id=2

while true; do
  # Read pending nonces from CF KV (filter for minexmr pool_id)
  kv_list=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys?limit=100" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

  if echo "$kv_list" | jq -e '.success' > /dev/null 2>&1; then
    nonce_keys=$(echo "$kv_list" | jq -r '.result[].name' 2>/dev/null || true)
    
    for key in $nonce_keys; do
      kv_value=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

      nonce=$(echo "$kv_value" | jq -r '.nonce // empty' 2>/dev/null)

      # Process all nonces (we're routed only MineXMR-assigned workers anyway)
      if [ -n "$nonce" ]; then
        nonce_hex=$(convert_nonce_to_hex "$nonce")
        submit_msg="{\"jsonrpc\":\"2.0\",\"id\":${msg_id},\"method\":\"submit\",\"params\":{\"id\":\"${worker_id}\",\"job_id\":\"${pool_job_id}\",\"nonce\":\"${nonce_hex}\",\"result\":\"${nonce_hex}\"}}"

        if send_msg "$submit_msg"; then
          if submit_response=$(recv_response 15); then
            if echo "$submit_response" | jq -e '.result.status' > /dev/null 2>&1; then
              log_msg "✓ Share accepted: nonce=${nonce:0:20}..."
              ((accepted_count++))
            elif echo "$submit_response" | jq -e '.error' > /dev/null 2>&1; then
              error_msg=$(echo "$submit_response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
              log_msg "✗ Share rejected: nonce=${nonce:0:20}... (error: $error_msg)"
              ((rejected_count++))
            fi
            ((submission_count++))
          fi
        fi
        ((msg_id++))

        # Delete from KV after submission attempt
        curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys/${key}" \
          -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
          -H "X-Auth-Key: ${CF_GLOBAL_KEY}" > /dev/null 2>&1
      fi
    done
  fi

  sleep 1
done
