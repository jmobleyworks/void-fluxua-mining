#!/bin/bash
#
# CF Nonce Submitter - Reads nonces queued by CF workers and submits to MoneroOcean
# Implements proper Monero Stratum authentication + submission
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
LOG_FILE="${MASCOM_DIR}/mining_state/cf_submissions.log"

mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Authenticate with Monero stratum pool and return session ID
stratum_login() {
  local login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}\",\"pass\":\"x\"}}"

  # Send login message to pool and capture response
  local response=$(echo "$login_msg" | nc -w 3 "$POOL_HOST" "$POOL_PORT" 2>/dev/null || echo "{}")

  # Extract session ID from response
  echo "$response" | jq -r '.result.id // empty' 2>/dev/null || echo ""
}

# Submit nonce to pool using session ID
submit_nonce_authenticated() {
  local nonce="$1"
  local session_id="$2"
  local job_id="$3"

  local submit_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submit\",\"params\":{\"id\":\"${session_id}\",\"job_id\":\"${job_id}\",\"nonce\":\"${nonce}\",\"result\":\"${nonce}\"}}"

  # Submit to pool
  local response=$(echo "$submit_msg" | nc -w 3 "$POOL_HOST" "$POOL_PORT" 2>/dev/null || echo "{}")

  # Check response for success
  if echo "$response" | jq -e '.result | select(.status == "OK")' > /dev/null 2>&1; then
    log_msg "✓ Share accepted: $nonce"
    return 0
  elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    local error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
    log_msg "✗ Share rejected: $nonce ($error_msg)"
    return 1
  else
    log_msg "✗ Pool response invalid: $response"
    return 1
  fi
}

# Main loop
log_msg "CF Nonce Submitter started"
log_msg "Pool: $POOL_HOST:$POOL_PORT"
log_msg "Wallet: ${WALLET:0:50}..."

submission_count=0
accepted_count=0
rejected_count=0
session_id=""
session_refresh_time=0

while true; do
  current_time=$(date +%s)

  # Refresh authentication every 10 minutes
  if [ $((current_time - session_refresh_time)) -gt 600 ] || [ -z "$session_id" ]; then
    session_id=$(stratum_login)
    session_refresh_time=$current_time
    if [ -n "$session_id" ]; then
      log_msg "✓ Authenticated with pool (session: ${session_id:0:20}...)"
    else
      log_msg "✗ Failed to authenticate with pool, retrying in 10s..."
      sleep 10
      continue
    fi
  fi

  # Read pending nonces from CF KV API
  kv_list=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

  # Extract and process nonce keys
  if echo "$kv_list" | jq -e '.success' > /dev/null 2>&1; then
    nonce_keys=$(echo "$kv_list" | jq -r '.result[].name' 2>/dev/null | head -10 || true)

    for key in $nonce_keys; do
      # Read the KV entry
      kv_value=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1)

      # Parse nonce from KV entry
      nonce=$(echo "$kv_value" | jq -r '.nonce // empty' 2>/dev/null)
      job_id=$(echo "$kv_value" | jq -r '.job_id // "job-unknown"' 2>/dev/null)

      if [ -n "$nonce" ]; then
        # Submit to pool
        if submit_nonce_authenticated "$nonce" "$session_id" "$job_id"; then
          ((accepted_count++))
        else
          ((rejected_count++))
        fi

        ((submission_count++))

        # Delete from KV after submission attempt
        curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys/${key}" \
          -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
          -H "X-Auth-Key: ${CF_GLOBAL_KEY}" > /dev/null 2>&1
      fi
    done
  fi

  # Log progress periodically
  if [ $((submission_count % 50)) -eq 0 ] && [ $submission_count -gt 0 ]; then
    log_msg "Progress: $submission_count submitted, $accepted_count accepted, $rejected_count rejected"
  fi

  sleep 5
done
