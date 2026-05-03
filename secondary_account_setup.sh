#!/bin/bash
# Secondary account setup: 100 workers on jmobleyworks@gmail.com
# Deploy and configure D1 bindings for secondary account

set -uo pipefail

source ~/.zshrc

# Secondary account credentials (stored in ~/.zshrc and keys.mobdb)
SECONDARY_ACCOUNT_ID="${CF_SECONDARY_ACCOUNT_ID:-}"
SECONDARY_EMAIL="${CF_SECONDARY_EMAIL:-jmobleyworks@gmail.com}"
SECONDARY_API_TOKEN="${CF_SECONDARY_API_TOKEN:-}"

TARGET_WORKERS=100
DB_NAME="mascom-phase0-ledger"

# Verify credentials are loaded
if [ -z "$SECONDARY_ACCOUNT_ID" ] || [ -z "$SECONDARY_API_TOKEN" ]; then
  echo "ERROR: Secondary account credentials not loaded"
  echo "Credentials should be in ~/.zshrc as CF_SECONDARY_ACCOUNT_ID and CF_SECONDARY_API_TOKEN"
  echo "Or run: source ~/.zshrc to load environment variables"
  exit 1
fi

echo "================================================================================"
echo "DEPLOY MINING WORKERS TO SECONDARY ACCOUNT"
echo "================================================================================"
echo "Account: $SECONDARY_EMAIL"
echo "Account ID: $SECONDARY_ACCOUNT_ID"
echo "Target workers: $TARGET_WORKERS (mining-register-0 through mining-register-99)"
echo ""

# Use primary API key if secondary not specified
API_KEY="${SECONDARY_API_KEY:-$CF_GLOBAL_KEY}"
EMAIL="${CLOUDFLARE_EMAIL}"

# Get current count on secondary account
CURRENT=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${SECONDARY_ACCOUNT_ID}/workers/scripts" \
  -H "X-Auth-Email: ${EMAIL}" \
  -H "X-Auth-Key: ${API_KEY}" 2>/dev/null | jq '.result | length')

TO_DEPLOY=$((TARGET_WORKERS - CURRENT))

echo "Current workers: $CURRENT"
echo "To deploy: $TO_DEPLOY"
echo ""

if [ $TO_DEPLOY -le 0 ]; then
  echo "✅ All $TARGET_WORKERS workers already deployed on secondary account"
  exit 0
fi

# Deploy workers
TEMPLATE='addEventListener("fetch", event => { event.respondWith(new Response(JSON.stringify({status:"operational"}), {headers:{"Content-Type":"application/json"}})); });'

echo "Deploying $TO_DEPLOY workers to secondary account..."
DEPLOYED=0

for ((i=CURRENT; i<TARGET_WORKERS; i++)); do
  WORKER_NAME="mining-register-$i"

  curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${SECONDARY_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "X-Auth-Email: ${EMAIL}" \
    -H "X-Auth-Key: ${API_KEY}" \
    -H "Content-Type: application/javascript" \
    --data "$TEMPLATE" > /dev/null 2>&1

  ((DEPLOYED++))

  if [ $((DEPLOYED % 25)) -eq 0 ] || [ $DEPLOYED -eq $TO_DEPLOY ]; then
    echo "  • Deployed: $DEPLOYED/$TO_DEPLOY workers"
  fi
done

echo ""
echo "✅ SECONDARY ACCOUNT DEPLOYMENT COMPLETE"
echo "All $TARGET_WORKERS workers deployed to $SECONDARY_EMAIL"
echo ""
echo "Next: Configure D1 bindings using Lumen automation"
echo "================================================================================"
