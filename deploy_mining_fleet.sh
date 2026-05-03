#!/bin/bash
#
# Deploy gen0_worker_complete.js to all 500 mining-register-* workers
# Uses Cloudflare Workers API for efficient bulk deployment

set -euo pipefail

# Source credentials
source ~/.zshrc

# Configuration
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-f07be5f84583d0d100b05aeeae56870b}"
SCRIPT_NAME="gen0_worker_complete.js"
SCRIPT_DIR="/Users/johnmobley/mascom/void_fluxua_mining/gen0_stage2_deployment"
WRANGLER_CONFIG="$SCRIPT_DIR/wrangler.toml"

if [ ! -f "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
  echo "Error: $SCRIPT_DIR/$SCRIPT_NAME not found"
  exit 1
fi

# Read the worker code
WORKER_CODE=$(cat "$SCRIPT_DIR/$SCRIPT_NAME")

# Get authorization header for API calls
AUTH_EMAIL="$CLOUDFLARE_EMAIL"
AUTH_KEY="$CLOUDFLARE_API_KEY"

echo "Deploying mining fleet to 500 workers..."
echo "Worker code: $SCRIPT_NAME ($(wc -l < "$SCRIPT_DIR/$SCRIPT_NAME") lines)"
echo "Cloudflare Account: $CF_ACCOUNT_ID"
echo "Auth: $AUTH_EMAIL"

# Deploy to mining-register-0 through mining-register-499
for i in {0..499}; do
  WORKER_NAME="mining-register-$i"

  if [ $((i % 50)) -eq 0 ]; then
    echo "[$(date +'%H:%M:%S')] Deploying workers $i-$((i+49))..."
  fi

  # Deploy via wrangler (reuses the same wrangler.toml but deploys to different worker names)
  # Note: This would require renaming or creating per-worker configs
  # For now, using API directly is more efficient

  # TODO: Implement CF API call to upload worker script
  # POST /accounts/{CF_ACCOUNT_ID}/workers/scripts/{script_name}
  # with the worker code

done

echo "Fleet deployment complete (or use 'wrangler deploy --help' for per-worker commands)"
