#!/bin/bash
# Deploy gen0_worker_complete.js to all 500 mining-register-* workers via Cloudflare API

set -euo pipefail

source ~/.zshrc

CF_ACCOUNT_ID="f07be5f84583d0d100b05aeeae56870b"
WORKER_CODE_FILE="/Users/johnmobley/mascom/void_fluxua_mining/gen0_stage2_deployment/gen0_worker_complete.js"

if [ ! -f "$WORKER_CODE_FILE" ]; then
  echo "Worker code not found: $WORKER_CODE_FILE"
  exit 1
fi

WORKER_CODE=$(cat "$WORKER_CODE_FILE")

echo "Starting bulk deploy to 500 workers..."
echo "Total lines of code: $(wc -l < "$WORKER_CODE_FILE")"

success_count=0
fail_count=0

for i in {0..499}; do
  WORKER_NAME="mining-register-$i"

  # Show progress every 50
  if [ $((i % 50)) -eq 0 ]; then
    echo "[$(date +'%H:%M:%S')] Deploying workers $i-$((i+49))... (Success: $success_count, Failed: $fail_count)"
  fi

  # Deploy via Cloudflare Workers API
  RESPONSE=$(curl -s -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_API_KEY}" \
    -H "Content-Type: application/javascript" \
    --data "$WORKER_CODE")

  # Check if deployment succeeded
  if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    ((success_count++))
  else
    ((fail_count++))
    if [ $((i % 50)) -eq 0 ]; then
      echo "  Error deploying $WORKER_NAME: $(echo "$RESPONSE" | jq '.errors[0].message // .error' 2>/dev/null || echo 'Unknown')"
    fi
  fi

  # Rate limiting: sleep briefly between deployments
  sleep 0.2
done

echo "Deploy complete!"
echo "Success: $success_count / 500"
echo "Failed: $fail_count / 500"
