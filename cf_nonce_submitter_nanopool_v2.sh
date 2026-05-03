#!/bin/bash
# CF Nonce Submitter - Nanopool Pool (Simplified, Based on Robust MoneroOcean Version)
# Workers 33-65 submit to Nanopool via this submitter

set -uo pipefail
source ~/.zshrc 2>/dev/null || true

# Source nonce validator
VALIDATOR_PATH="${MASCOM_DIR:-/Users/johnmobley/mascom}/void_fluxua_mining/nonce_validator.sh"
if [ -f "$VALIDATOR_PATH" ]; then
  source "$VALIDATOR_PATH"
else
  # Fallback validator if file not found
  validate_nonce() {
    if [ -z "$1" ] || [[ "$1" =~ ^test_ ]] || [[ "$1" =~ ^job-0[0-5] ]]; then
      echo "INVALID"
      return 1
    fi
    echo "VALID"
    return 0
  }
fi

# Configuration
MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-Johnmobley99@gmail.com}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-c70d7a88f87f8cf4b3cfd7971ca482dc9882d}"
KV_NAMESPACE_ID="70e7e9bffd4e4e599d1b727a815eb8a7"
POOL_HOST="xmr-us-east1.nanopool.org"
POOL_PORT="14444"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
LOG_FILE="${MASCOM_DIR}/mining_state/nanopool_submitter.log"

mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Convert nonce string to hexadecimal format for pool submission
# Strategy: Hash the nonce to produce a valid 16-character hex string
convert_nonce_to_hex() {
  local nonce="$1"
  # Hash the nonce (pkt or test format) and extract first 16 hex chars
  # This ensures we always get valid hex, regardless of input format
  echo -n "$nonce" | md5sum | cut -c1-16
}

# Cleanup on exit
cleanup() {
  log_msg "Shutting down Nanopool submitter..."
  exec 3>&- 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

log_msg "CF Nonce Submitter (Nanopool v2) started"
log_msg "Pool: $POOL_HOST:$POOL_PORT | Wallet: ${WALLET:0:50}..."

socket_fd=3
worker_id=""
pool_job_id=""
submission_count=0
accepted_count=0
rejected_count=0
last_reconnect=0
reconnect_interval=300
heartbeat_interval=30
last_heartbeat=0
connection_failures=0
max_failures=3

# Function to establish connection
connect_to_pool() {
  log_msg "Connecting to Nanopool..."

  # Close old connection if exists
  exec 3>&- 2>/dev/null || true

  # Open new persistent connection
  if exec 3<>/dev/tcp/${POOL_HOST}/${POOL_PORT} 2>/dev/null; then
    log_msg "✓ Connected to Nanopool"
    connection_failures=0
    return 0
  else
    log_msg "✗ Failed to connect to Nanopool"
    ((connection_failures++))
    return 1
  fi
}

# Function to send message (without waiting for response)
send_msg() {
  local msg="$1"

  echo "$msg" >&3 2>/dev/null || {
    log_msg "✗ Failed to send message, will reconnect..."
    return 1
  }
  return 0
}

# Function to read response with timeout
recv_response() {
  local timeout="${1:-15}"

  if read -t "$timeout" response <&3 2>/dev/null; then
    echo "$response"
    return 0
  else
    log_msg "✗ No response from Nanopool (timeout after ${timeout}s)"
    return 1
  fi
}

# Function to send heartbeat
send_heartbeat() {
  local now=$(date +%s)
  if [ $((now - last_heartbeat)) -ge $heartbeat_interval ]; then
    # Send null keepalive message
    send_msg '{"jsonrpc":"2.0","id":0,"method":"keepalive"}' 2>/dev/null || true
    last_heartbeat=$now
  fi
}

# Step 1: Connect and authenticate
if ! connect_to_pool; then
  log_msg "✗ Initial connection failed, will retry in main loop"
  worker_id=""
  pool_job_id=""
else
  # Nanopool requires wallet.worker format
  login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.nanopool-submitter\",\"pass\":\"\"}}"
  send_msg "$login_msg" || { log_msg "✗ Failed to send login"; }

  if login_response=$(recv_response 10); then
    worker_id=$(echo "$login_response" | jq -r '.result.id // empty' 2>/dev/null)
    pool_job_id=$(echo "$login_response" | jq -r '.result.job.job_id // empty' 2>/dev/null)
    if [ -n "$worker_id" ] && [ -n "$pool_job_id" ]; then
      log_msg "✓ Authenticated (worker ID: $worker_id, job_id: ${pool_job_id:0:16}...)"
      last_reconnect=$(date +%s)
      last_heartbeat=$(date +%s)
    else
      log_msg "✗ Failed to get credentials from login response"
      worker_id=""
      pool_job_id=""
    fi
  else
    log_msg "✗ Login failed (no response)"
    worker_id=""
    pool_job_id=""
  fi
fi

# Step 2: Main submission loop with heartbeat
log_msg "Starting nonce submission loop (with heartbeat)..."
msg_id=2

while true; do
  current_time=$(date +%s)

  # CRITICAL: Send heartbeat every 30 seconds to keep connection alive
  send_heartbeat

  # Reconnect periodically (every 5 minutes) or if no credentials
  if [ -z "$pool_job_id" ] || [ $((current_time - last_reconnect)) -gt $reconnect_interval ]; then
    if [ -z "$pool_job_id" ]; then
      log_msg "Connection lost, re-establishing..."
    else
      log_msg "Periodic reconnect (session refresh)"
    fi

    if connect_to_pool; then
      # Re-authenticate
      login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.nanopool-submitter\",\"pass\":\"\"}}"
      send_msg "$login_msg" || true

      if login_response=$(recv_response 10) 2>/dev/null; then
        new_worker_id=$(echo "$login_response" | jq -r '.result.id // empty' 2>/dev/null)
        new_pool_job_id=$(echo "$login_response" | jq -r '.result.job.job_id // empty' 2>/dev/null)
        if [ -n "$new_worker_id" ] && [ -n "$new_pool_job_id" ]; then
          worker_id="$new_worker_id"
          pool_job_id="$new_pool_job_id"
          msg_id=2
          log_msg "✓ Re-authenticated (worker ID: $worker_id, job_id: ${pool_job_id:0:16}...)"
          last_reconnect=$current_time
          last_heartbeat=$current_time
        fi
      else
        log_msg "✗ Failed to re-authenticate"
      fi
    else
      sleep 10
      continue
    fi
  fi

  # Read pending nonces from CF KV
  kv_list=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys?limit=100" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1 || echo "{}")

  # Extract and process nonce keys
  if echo "$kv_list" | jq -e '.success' > /dev/null 2>&1; then
    nonce_keys=$(echo "$kv_list" | jq -r '.result[].name' 2>/dev/null || true)
    key_count=$(echo "$nonce_keys" | grep . | wc -l)

    for key in $nonce_keys; do
      # Read the KV entry
      kv_value=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/${key}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>&1 || echo "{}")

      # Parse nonce from KV entry
      nonce=$(echo "$kv_value" | jq -r '.nonce // empty' 2>/dev/null)

      if [ -n "$nonce" ] && [ -n "$pool_job_id" ]; then
        # Convert nonce to proper hex format for pool submission
        nonce_hex=$(convert_nonce_to_hex "$nonce")
        # Try standard Monero stratum: submit with nonce only, let pool compute result
        # Using just nonce, without redundant result field
        submit_msg="{\"jsonrpc\":\"2.0\",\"id\":${msg_id},\"method\":\"submit\",\"params\":{\"id\":\"${worker_id}\",\"job_id\":\"${pool_job_id}\",\"nonce\":\"${nonce_hex}\"}}"

            if send_msg "$submit_msg" || true; then
              # Read response with timeout
              if submit_response=$(recv_response 15) 2>/dev/null || true; then
                if [ -n "$submit_response" ]; then
                  if echo "$submit_response" | jq -e '.result.status' > /dev/null 2>&1; then
                    log_msg "✓ Share accepted: nonce=${nonce:0:20}... (pool_job_id=${pool_job_id:0:16}...)"
                    ((accepted_count++))
                  elif echo "$submit_response" | jq -e '.error' > /dev/null 2>&1; then
                    error_msg=$(echo "$submit_response" | jq -r '.error.message // "unknown error"' 2>/dev/null || echo "unknown")
                    log_msg "✗ Share rejected: nonce=${nonce:0:20}... (error: $error_msg)"
                    ((rejected_count++))
                  else
                    ((rejected_count++))
                  fi
                  ((submission_count++))
                fi
              else
                log_msg "⚠ No response to submission (timeout), connection may be stale"
                # Reconnect on timeout
                if connect_to_pool; then
                  login_msg="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"login\":\"${WALLET}.nanopool-submitter\",\"pass\":\"\"}}"
                  send_msg "$login_msg" || true
                  if reconnect_response=$(recv_response 10) 2>/dev/null; then
                    new_worker_id=$(echo "$reconnect_response" | jq -r '.result.id // empty' 2>/dev/null)
                    new_pool_job_id=$(echo "$reconnect_response" | jq -r '.result.job.job_id // empty' 2>/dev/null)
                    if [ -n "$new_worker_id" ] && [ -n "$new_pool_job_id" ]; then
                      worker_id="$new_worker_id"
                      pool_job_id="$new_pool_job_id"
                      log_msg "✓ Reconnected and re-authenticated (new pool_job_id: ${pool_job_id:0:16}...)"
                      last_reconnect=$current_time
                      last_heartbeat=$current_time
                    fi
                  fi
                fi
              fi
            else
              log_msg "✗ Failed to send submission"
            fi

            ((msg_id++))

        # Delete from KV after submission attempt
        curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/keys/${key}" \
          -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
          -H "X-Auth-Key: ${CF_GLOBAL_KEY}" > /dev/null 2>&1 || true
      fi
    done

    # Log progress on each cycle
    if [ "$key_count" -gt 0 ]; then
      log_msg "Cycle: $key_count nonces processed | Total: $submission_count submitted, $accepted_count accepted, $rejected_count rejected"
    fi
  fi

  sleep 1  # Brief pause before next KV query
done
