#!/bin/bash
#
# CF Nonce Submitter - Persistent TCP Connection to MoneroOcean
# Maintains authenticated session for continuous share submission
#

set -euo pipefail

source ~/.zshrc 2>/dev/null || true

# Configuration
MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-Johnmobley99@gmail.com}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-c70d7a88f87f8cf4b3cfd7971ca482dc9882d}"
KV_NAMESPACE_ID="70e7e9bffd4e4e599d1b727a815eb8a7"
POOL_HOST="gulf.moneroocean.stream"
POOL_PORT="10128"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
LOG_FILE="${MASCOM_DIR}/mining_state/cf_submissions_persistent.log"
SOCKET_FILE="/tmp/monero_pool_socket_$$"

mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Cleanup on exit
cleanup() {
  log_msg "Cleaning up..."
  exec 3>&- 2>/dev/null || true  # Close socket
  rm -f "$SOCKET_FILE"
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

log_msg "CF Nonce Submitter with Persistent Connection started"
log_msg "Pool: $POOL_HOST:$POOL_PORT"
log_msg "Wallet: ${WALLET:0:50}..."

# Step 1: Open persistent TCP connection to pool
log_msg "Connecting to pool..."
exec 3<>/dev/tcp/${POOL_HOST}/${POOL_PORT} || {
  log_msg "✗ Failed to connect to pool"
  exit 1
}

log_msg "✓ Connected to pool"

# Step 2: Send login request over persistent connection
login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}\",\"pass\":\"x\"}}"
echo "$login_msg" >&3

# Read login response
read -t 3 login_response <&3
log_msg "Login response: $login_response"

# Extract worker ID
worker_id=$(echo "$login_response" | jq -r '.result.id // empty' 2>/dev/null)
if [ -z "$worker_id" ]; then
  log_msg "✗ Failed to get worker ID from login response"
  exit 1
fi
log_msg "✓ Authenticated (worker ID: $worker_id)"

# Step 3: Main submission loop
submission_count=0
accepted_count=0
rejected_count=0
msg_id=2

log_msg "Starting nonce submission loop..."

while true; do
  # Read pending nonces from CF KV API
  kv_list=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

  # Extract and process nonce keys
  if echo "$kv_list" | jq -e '.success' > /dev/null 2>&1; then
    nonce_keys=$(echo "$kv_list" | jq -r '.result[].name' 2>/dev/null | head -5 || true)

    for key in $nonce_keys; do
      # Read the KV entry
      kv_value=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

      # Parse nonce from KV entry
      nonce=$(echo "$kv_value" | jq -r '.nonce // empty' 2>/dev/null)
      difficulty=$(echo "$kv_value" | jq -r '.difficulty // 1000000' 2>/dev/null)
      job_id=$(echo "$kv_value" | jq -r '.job_id // "job-unknown"' 2>/dev/null)

      if [ -n "$nonce" ]; then
        # Submit to pool via persistent connection
        submit_msg="{\"jsonrpc\":\"2.0\",\"id\":${msg_id},\"method\":\"submit\",\"params\":{\"id\":\"${worker_id}\",\"job_id\":\"${job_id}\",\"nonce\":\"${nonce}\",\"result\":\"${nonce}\"}}"
        echo "$submit_msg" >&3

        # Read response
        if read -t 3 submit_response <&3; then
          if echo "$submit_response" | jq -e '.result.status' > /dev/null 2>&1; then
            log_msg "✓ Share accepted: $nonce"
            ((accepted_count++))
          else
            log_msg "✗ Share rejected: $nonce"
            ((rejected_count++))
          fi
        else
          log_msg "✗ No response from pool for share: $nonce"
        fi

        ((submission_count++))
        ((msg_id++))

        # Delete from KV after submission attempt
        curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys/${key}" \
          -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
          -H "X-Auth-Key: ${CF_GLOBAL_KEY}" > /dev/null 2>&1
      fi
    done
  fi

  # Log progress periodically
  if [ $((submission_count % 10)) -eq 0 ] && [ $submission_count -gt 0 ]; then
    log_msg "Progress: $submission_count submitted, $accepted_count accepted, $rejected_count rejected"
  fi

  sleep 5
done
