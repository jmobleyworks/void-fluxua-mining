#!/bin/bash
#
# REDEPLOY 500 MINING WORKERS - Fix error 1042 with correct code
# Uses gen0_worker_miner_v2.js which has proper Stratum protocol
#

set -euo pipefail

source ~/.zshrc

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
WORKER_CODE="$MASCOM_DIR/void_fluxua_mining/gen0_worker_miner_v2.js"
POOL_HOST="gulf.moneroocean.stream"
POOL_PORT="10128"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

echo "═══════════════════════════════════════════════════════════"
echo "Redeploying 500 mining workers with corrected code"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Worker code: $WORKER_CODE"
echo "Pool: $POOL_HOST:$POOL_PORT"
echo "Wallet: ${WALLET:0:50}..."
echo ""

# Check if worker code exists
if [ ! -f "$WORKER_CODE" ]; then
  echo "ERROR: Worker code not found at $WORKER_CODE"
  exit 1
fi

TEMP_DIR="/tmp/mining_deploy_$$"
mkdir -p "$TEMP_DIR"
cp "$WORKER_CODE" "$TEMP_DIR/index.js"

success_count=0
fail_count=0

for i in {0..499}; do
  WORKER_NAME="mining-register-$i"

  # Create wrangler.toml for this worker
  cat > "$TEMP_DIR/wrangler.toml" <<EOF
name = "$WORKER_NAME"
compatibility_date = "2026-04-30"
main = "index.js"
workers_dev = true

[env.production]

[env.production.vars]
WORKER_ID = "$WORKER_NAME"
POOL_HOST = "$POOL_HOST"
POOL_PORT = "$POOL_PORT"
WALLET = "$WALLET"

[[env.production.d1_databases]]
binding = "DB"
database_id = "20da851f-2876-4113-bdae-9f99582ea0e2"
database_name = "worker-nonces"

[[env.production.kv_namespaces]]
binding = "KV"
id = "70e7e9bffd4e4e599d1b727a815eb8a7"
preview_id = "70e7e9bffd4e4e599d1b727a815eb8a7"

[[env.production.services]]
binding = "JOB_DISPATCHER"
service = "gen0-job-dispatcher-production"
environment = "production"

[build]
command = ""
cwd = ""
EOF

  # Deploy using wrangler
  if (cd "$TEMP_DIR" && wrangler deploy --env production > /dev/null 2>&1); then
    ((success_count++))
    if [ $((success_count % 50)) -eq 0 ]; then
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Progress: $success_count deployed"
    fi
  else
    ((fail_count++))
    echo "ERROR deploying $WORKER_NAME"
  fi

  # Rate limiting to avoid CF API throttle
  sleep 0.2
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Redeployment complete!"
echo "Success: $success_count / 500"
echo "Failed: $fail_count / 500"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Cleanup
rm -rf "$TEMP_DIR"

if [ $fail_count -eq 0 ]; then
  echo "✓ All 500 workers successfully redeployed"
  echo "Testing worker endpoint..."
  sleep 5
  curl -s "https://mining-register-0.johnmobley99.workers.dev/" | head -20
else
  echo "✗ Some workers failed to deploy. Check logs above."
  exit 1
fi
