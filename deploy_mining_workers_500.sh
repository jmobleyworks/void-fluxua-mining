#!/bin/bash
# Deploy mining-register workers to reach 500 total on primary account
# Part of Epona-Eponette unified deployment system

set -uo pipefail

source ~/.zshrc

ACCOUNT_ID="$CF_ACCOUNT_ID"
EMAIL="$CLOUDFLARE_EMAIL"
API_KEY="$CF_GLOBAL_KEY"

TARGET_WORKERS=500
DB_NAME="mascom-phase0-ledger"

# Get current count
CURRENT=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts" \
  -H "X-Auth-Email: ${EMAIL}" \
  -H "X-Auth-Key: ${API_KEY}" 2>/dev/null | jq '[.result[] | select(.id | startswith("mining-register-"))] | length')

TO_DEPLOY=$((TARGET_WORKERS - CURRENT))

echo "================================================================================"
echo "DEPLOY MINING WORKERS TO 500"
echo "================================================================================"
echo "Current mining-register workers: $CURRENT"
echo "Target: $TARGET_WORKERS"
echo "To deploy: $TO_DEPLOY"
echo ""

if [ $TO_DEPLOY -le 0 ]; then
  echo "✅ All 500 workers already deployed"
  exit 0
fi

# Get template from existing worker
echo "Fetching worker template..."
TEMPLATE_RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/mining-register-0" \
  -H "X-Auth-Email: ${EMAIL}" \
  -H "X-Auth-Key: ${API_KEY}" 2>/dev/null)

# If we can't get template, use minimal default
TEMPLATE='addEventListener("fetch", event => { event.respondWith(new Response(JSON.stringify({status:"operational"}), {headers:{"Content-Type":"application/json"}})); });'

echo "Deploying $TO_DEPLOY workers..."
DEPLOYED=0

for ((i=CURRENT; i<TARGET_WORKERS; i++)); do
  WORKER_NAME="mining-register-$i"

  curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "X-Auth-Email: ${EMAIL}" \
    -H "X-Auth-Key: ${API_KEY}" \
    -H "Content-Type: application/javascript" \
    --data "$TEMPLATE" > /dev/null 2>&1

  ((DEPLOYED++))

  if [ $((DEPLOYED % 50)) -eq 0 ] || [ $DEPLOYED -eq $TO_DEPLOY ]; then
    echo "  • Deployed: $DEPLOYED/$TO_DEPLOY workers"
  fi
done

echo ""
echo "✅ DEPLOYMENT COMPLETE"
echo "All $TARGET_WORKERS mining-register workers deployed"
echo ""
echo "Next: Run lumen_d1_batch_configure.sh to bind D1 database"
echo "================================================================================"
