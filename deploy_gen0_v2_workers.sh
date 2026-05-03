#!/bin/bash
#
# STEP 3: Deploy gen0_worker_miner_v2.js to 5 test workers
# Deploys mining-register-0 through mining-register-4 with corrected code
#

set -e

source ~/.zshrc

if [ -z "$CF_ACCOUNT_ID" ] || [ -z "$CF_GLOBAL_KEY" ] || [ -z "$CLOUDFLARE_EMAIL" ]; then
  echo "❌ ERROR: CF credentials not loaded"
  echo "   Set CF_ACCOUNT_ID, CF_GLOBAL_KEY, CLOUDFLARE_EMAIL"
  exit 1
fi

DEPLOY_DIR="/Users/johnmobley/mascom/void_fluxua_mining/gen0_stage2_deployment"
WORKER_CODE="$DEPLOY_DIR/gen0_worker_miner.js"
WORKERS=(0 1 2 3 4)

echo "========================================================================"
echo "STEP 3: DEPLOY GEN0 V2 WORKER CODE TO 5 TEST WORKERS"
echo "========================================================================"
echo ""
echo "Configuration:"
echo "  CF Account: $CF_ACCOUNT_ID"
echo "  Workers: mining-register-{0..4}"
echo "  Code: gen0_worker_miner_v2.js (7.3KB)"
echo "  Database: D1 (UUID: 20da851f-2876-4113-bdae-9f99582ea0e2)"
echo ""

if [ ! -f "$WORKER_CODE" ]; then
  echo "❌ ERROR: Worker code not found at $WORKER_CODE"
  exit 1
fi

echo "Starting deployments..."
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for WORKER_NUM in "${WORKERS[@]}"; do
  WORKER_NAME="mining-register-$WORKER_NUM"

  echo "────────────────────────────────────────────────────────────"
  echo "Deploying: $WORKER_NAME"
  echo "────────────────────────────────────────────────────────────"

  # Deploy via CF API multipart upload
  DEPLOY_URL="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER_NAME"

  echo "  [1/3] Uploading worker code..."

  # Build metadata from wrangler config
  METADATA=$(cat <<EOF
{
  "main_module": "gen0_worker_miner.js",
  "bindings": [
    {
      "type": "d1",
      "name": "DB",
      "database_id": "20da851f-2876-4113-bdae-9f99582ea0e2"
    }
  ],
  "plain_text_bindings": [
    {"name": "WORKER_ID", "text": "mining-register-$WORKER_NUM"},
    {"name": "POOL_HOST", "text": "gulf.moneroocean.stream"},
    {"name": "POOL_PORT", "text": "10128"},
    {"name": "WALLET", "text": "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"}
  ]
}
EOF
)

  # Use temp files for response and metadata
  TEMP_RESPONSE=$(mktemp)
  TEMP_METADATA=$(mktemp)
  echo "$METADATA" > "$TEMP_METADATA"

  HTTP_CODE=$(curl -s -X PUT "$DEPLOY_URL" \
    -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
    -H "X-Auth-Key: $CF_GLOBAL_KEY" \
    -F "main_module=@$WORKER_CODE" \
    -F "metadata=@$TEMP_METADATA;type=application/json" \
    -o "$TEMP_RESPONSE" \
    -w "%{http_code}")

  RESPONSE_BODY=$(cat "$TEMP_RESPONSE")
  rm -f "$TEMP_RESPONSE" "$TEMP_METADATA"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "  ✅ Deploy HTTP $HTTP_CODE: Success"
    (( SUCCESS_COUNT++ ))
  else
    echo "  ❌ Deploy HTTP $HTTP_CODE: Failed"
    echo "     Response: $(echo "$RESPONSE_BODY" | jq -c '.errors[0].message // .error' 2>/dev/null || echo "$RESPONSE_BODY" | head -c 100)"
    (( FAIL_COUNT++ ))

    # Don't continue if deployment failed
    echo "     Stopping deployment loop"
    break
  fi

  # Test worker endpoint
  echo "  [2/3] Testing worker endpoint..."
  WORKER_URL="https://$WORKER_NAME.johnmobley99.workers.dev/"

  TEST_RESPONSE=$(curl -s -m 5 "$WORKER_URL" 2>&1 || true)

  if echo "$TEST_RESPONSE" | grep -q "Gen 0 Worker Miner V2"; then
    echo "  ✅ Endpoint responding correctly"
  elif echo "$TEST_RESPONSE" | grep -q "error"; then
    echo "  ⚠️  Endpoint returned error (common after fresh deploy): $(echo "$TEST_RESPONSE" | head -c 80)"
  else
    echo "  ⚠️  Endpoint test response: $(echo "$TEST_RESPONSE" | head -c 80)"
  fi

  # Check status endpoint
  echo "  [3/3] Checking status endpoint..."
  STATUS_URL="https://$WORKER_NAME.johnmobley99.workers.dev/status"

  STATUS_RESPONSE=$(curl -s -m 5 "$STATUS_URL" 2>&1 || true)

  if echo "$STATUS_RESPONSE" | grep -q "pending_nonces\|mining"; then
    echo "  ✅ Status endpoint responding"
    echo "     $(echo "$STATUS_RESPONSE" | jq -c '.status // .message' 2>/dev/null || echo "$STATUS_RESPONSE" | head -c 60)"
  elif echo "$STATUS_RESPONSE" | grep -q "error"; then
    echo "  ⚠️  Status endpoint error: $(echo "$STATUS_RESPONSE" | jq -c '.error // .' 2>/dev/null || echo "$STATUS_RESPONSE" | head -c 80)"
  else
    echo "  ⚠️  Status response: $(echo "$STATUS_RESPONSE" | head -c 80)"
  fi

  echo ""

  # Wait between deployments (avoid rate limiting)
  if [ "$WORKER_NUM" -lt 4 ]; then
    echo "  Waiting 5 seconds before next deployment..."
    sleep 5
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
  echo "Next steps:"
  echo "  1. Monitor worker endpoints for functionality"
  echo "  2. Check D1 database for accumulating nonces"
  echo "  3. Verify stratum bridge integration"
  echo "  4. Monitor pool for accepted shares"
  echo ""
  exit 0
elif [ $SUCCESS_COUNT -gt 0 ]; then
  echo "STATUS: ⚠️  PARTIAL DEPLOYMENT ($SUCCESS_COUNT of 5 successful)"
  echo ""
  echo "Action required:"
  echo "  1. Debug failed workers"
  echo "  2. Retry failed deployments after checking for issues"
  echo ""
  exit 1
else
  echo "STATUS: ❌ DEPLOYMENT FAILED"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Check CF credentials (CF_ACCOUNT_ID, CF_GLOBAL_KEY, CLOUDFLARE_EMAIL)"
  echo "  2. Verify worker code syntax"
  echo "  3. Check for CF rate limiting"
  echo "  4. Review error messages above"
  echo ""
  exit 1
fi
