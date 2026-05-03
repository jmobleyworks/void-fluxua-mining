#!/bin/bash
#
# Deploy gen0_worker_complete.js to all 500 mining-register-* workers using wrangler
# Creates temporary wrangler.toml for each worker and deploys

set -euo pipefail

source ~/.zshrc

SCRIPT_DIR="/Users/johnmobley/mascom/void_fluxua_mining/gen0_stage2_deployment"
WORKER_CODE="$SCRIPT_DIR/gen0_worker_complete.js"
TEMPLATE_TOML="$SCRIPT_DIR/wrangler.toml"
TEMP_DIR="/tmp/wrangler_miners_$$"

mkdir -p "$TEMP_DIR"

cp "$WORKER_CODE" "$TEMP_DIR/gen0_worker_complete.js"

echo "Deploying 500 miners using wrangler..."
echo "Temp directory: $TEMP_DIR"

success_count=0
fail_count=0

for i in {0..499}; do
  WORKER_NAME="mining-register-$i"

  # Show progress every 10
  if [ $((i % 10)) -eq 0 ]; then
    echo "[$(date +'%H:%M:%S')] Deploying workers $i-$((i+9))... (Success: $success_count, Failed: $fail_count)"
  fi

  # Create per-worker wrangler.toml
  cat > "$TEMP_DIR/wrangler_$i.toml" <<EOF
name = "$WORKER_NAME"
main = "gen0_worker_complete.js"
compatibility_date = "2024-01-01"

account_id = "f07be5f84583d0d100b05aeeae56870b"
workers_dev = true

[env.production]

[env.production.vars]
WORKER_ID = "$WORKER_NAME"
POOL_HOST = "gulf.moneroocean.stream"
POOL_PORT = "10128"
WALLET = "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

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

  # Deploy using this config
  if (cd "$TEMP_DIR" && wrangler deploy --config "wrangler_$i.toml" --env production gen0_worker_complete.js > /dev/null 2>&1); then
    ((success_count++))
  else
    ((fail_count++))
  fi

  # Rate limiting
  sleep 0.3
done

echo ""
echo "Deploy complete!"
echo "Success: $success_count / 500"
echo "Failed: $fail_count / 500"
echo ""
echo "Cleaning up temp directory: $TEMP_DIR"
# Uncomment to clean up: rm -rf "$TEMP_DIR"
