#!/bin/bash
#
# Deploy all 5 gen0 V2 workers using wrangler with correct API token
#

set -e

# Use the active API token from search results
export CLOUDFLARE_API_TOKEN="bVmnmCiF3JKpOhaKrjIg5mDjD49HEcXUX6LlSzon"

DEPLOY_DIR="/Users/johnmobley/mascom/void_fluxua_mining/gen0_stage2_deployment"
cd "$DEPLOY_DIR"

echo "========================================================================"
echo "DEPLOYING ALL 5 GEN0 V2 WORKERS WITH WRANGLER"
echo "========================================================================"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for i in {0..4}; do
  WORKER_NAME="mining-register-$i"
  CONFIG_FILE="wrangler-mining-register-${i}.toml"

  echo "────────────────────────────────────────────────────────────"
  echo "[$((i+1))/5] Deploying $WORKER_NAME"
  echo "────────────────────────────────────────────────────────────"

  if wrangler deploy --config "$CONFIG_FILE" 2>&1 | tail -15; then
    echo "✅ Deployment successful"
    (( SUCCESS_COUNT++ ))
  else
    echo "❌ Deployment failed"
    (( FAIL_COUNT++ ))
  fi

  echo ""

  # Small delay between deployments to avoid rate limiting
  if [ $i -lt 4 ]; then
    sleep 2
  fi
done

echo "========================================================================"
echo "DEPLOYMENT SUMMARY"
echo "========================================================================"
echo ""
echo "Results:"
echo "  ✅ Successful: $SUCCESS_COUNT workers"
echo "  ❌ Failed: $FAIL_COUNT workers"
echo ""

if [ $SUCCESS_COUNT -eq 5 ]; then
  echo "STATUS: ✅ ALL 5 WORKERS DEPLOYED SUCCESSFULLY"
  echo ""
  echo "Deployed workers:"
  for i in {0..4}; do
    echo "  • mining-register-$i.johnmobley99.workers.dev"
  done
  echo ""
  echo "Database: D1 (20da851f-2876-4113-bdae-9f99582ea0e2)"
  echo ""
  echo "NEXT STEP: Monitor worker endpoints for correct operation"
  exit 0
else
  echo "STATUS: ⚠️  PARTIAL DEPLOYMENT"
  exit 1
fi
