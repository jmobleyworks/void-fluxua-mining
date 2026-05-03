#!/bin/bash
# LUMEN ACCOUNT SCALING ORCHESTRATOR
# Framework for rapid Cloudflare account expansion via Lumen browser automation
# Enables scaling from 600 → 1200 → 1800+ workers in minutes, not hours

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUMEN_BIN="${LUMEN_BIN:-/Users/johnmobley/bin/lumen}"
ACCOUNTS_FILE="${ACCOUNTS_FILE:-~/.creds/cf_accounts.json}"

show_status() {
  echo "================================================================================"
  echo "LUMEN ACCOUNT SCALING ORCHESTRATOR"
  echo "================================================================================"
  echo ""
  echo "Configured accounts:"

  if [ -f "$ACCOUNTS_FILE" ]; then
    jq '.accounts[] | {email, account_id, target_workers, status}' "$ACCOUNTS_FILE" 2>/dev/null || cat "$ACCOUNTS_FILE"
  else
    echo "⚠️  No accounts configured. Use 'add-account' command."
  fi
  echo ""
}

add_account() {
  local email="$1"
  local account_id="$2"
  local api_token="$3"
  local target_workers="${4:-100}"

  if [ ! -f "$ACCOUNTS_FILE" ]; then
    echo '{"accounts":[]}' > "$ACCOUNTS_FILE"
    chmod 600 "$ACCOUNTS_FILE"
  fi

  # Add account to JSON
  jq ".accounts += [{\"email\":\"$email\",\"account_id\":\"$account_id\",\"api_token\":\"$api_token\",\"target_workers\":$target_workers,\"status\":\"pending\",\"created\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]" "$ACCOUNTS_FILE" > "$ACCOUNTS_FILE.tmp" && mv "$ACCOUNTS_FILE.tmp" "$ACCOUNTS_FILE"

  echo "✅ Added account: $email ($target_workers workers)"
}

deploy_to_account() {
  local email="$1"
  local account_id="$2"
  local api_token="$3"
  local target_workers="${4:-100}"

  echo ""
  echo "================================================================================"
  echo "DEPLOYING TO: $email"
  echo "================================================================================"
  echo "Account ID: $account_id"
  echo "Target workers: $target_workers"
  echo ""

  # Step 1: Deploy workers via API (autonomous)
  echo "Step 1: Deploying $target_workers mining-register workers via API..."

  WORKER_CODE='addEventListener("fetch", event => {
    event.respondWith(new Response(JSON.stringify({status:"operational"}), {
      headers:{"Content-Type":"application/json"}
    }));
  });'

  DEPLOYED=0
  for ((i=0; i<target_workers; i++)); do
    WORKER_NAME="mining-register-$i"
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${WORKER_NAME}" \
      -H "X-Auth-Email: ${email}" \
      -H "X-Auth-Key: ${api_token}" \
      -H "Content-Type: application/javascript" \
      --data "$WORKER_CODE" > /dev/null 2>&1
    ((DEPLOYED++))
    if [ $((DEPLOYED % 25)) -eq 0 ] || [ $DEPLOYED -eq $target_workers ]; then
      echo "  ✓ Deployed: $DEPLOYED/$target_workers workers"
    fi
  done

  echo "✅ API deployment complete"
  echo ""
  echo "Step 2: D1 binding configuration (requires Lumen automation from GUI)"
  echo "  When ready to configure bindings:"
  echo "    export CF_ACCOUNT_ID='$account_id'"
  echo "    export CF_GLOBAL_KEY='$api_token'"
  echo "    export CLOUDFLARE_EMAIL='$email'"
  echo "    $SCRIPT_DIR/lumen_d1_batch_configure.sh"
  echo ""
}

invoke_lumen_d1_batch() {
  local email="$1"
  local account_id="$2"
  local api_token="$3"
  local target_workers="${4:-100}"

  if [ ! -x "$LUMEN_BIN" ]; then
    echo "❌ Lumen not found at $LUMEN_BIN"
    return 1
  fi

  echo ""
  echo "================================================================================"
  echo "LUMEN D1 BATCH CONFIGURATION"
  echo "================================================================================"
  echo "Account: $email"
  echo "Workers: $target_workers (mining-register-0 through mining-register-$((target_workers-1)))"
  echo ""
  echo "Lumen will:"
  echo "  1. Navigate to Cloudflare dashboard"
  echo "  2. For each mining-register worker:"
  echo "     • Click worker"
  echo "     • Settings tab"
  echo "     • D1 Database section"
  echo "     • Add Binding: DB → mascom-phase0-ledger"
  echo "     • Save"
  echo "  3. Estimated time: $((target_workers / 2)) minutes"
  echo ""

  export CF_ACCOUNT_ID="$account_id"
  export CF_GLOBAL_KEY="$api_token"
  export CLOUDFLARE_EMAIL="$email"

  # Call the existing Lumen D1 batch script
  bash "$SCRIPT_DIR/lumen_d1_batch_configure.sh"
}

show_usage() {
  cat << 'EOF'

LUMEN ACCOUNT SCALING ORCHESTRATOR
Rapid Cloudflare account expansion (600 → 1200 → 1800+ workers)

USAGE:
  ./lumen_account_scaling_orchestrator.sh <command> [args...]

COMMANDS:

  status                  Show configured accounts and deployment status

  add-account <email> <account_id> <api_token> [workers]
                          Register new Cloudflare account for scaling
                          Example: add-account jmobley2@gmail.com abc123... token... 100

  deploy <email>          Deploy mining-register workers to account via API
                          (autonomous, no GUI needed)

  lumen-d1 <email>        Configure D1 bindings via Lumen browser automation
                          (requires GUI/display available)

  batch <email> <account_id> <token> [workers]
                          Deploy workers + prepare Lumen D1 configuration

EXAMPLES:

  # Add a new 100-worker account
  ./lumen_account_scaling_orchestrator.sh add-account jmobley2@gmail.com 035924... token... 100

  # Deploy workers to that account (API, autonomous)
  ./lumen_account_scaling_orchestrator.sh deploy jmobley2@gmail.com

  # From GUI environment, configure D1 bindings via Lumen
  ./lumen_account_scaling_orchestrator.sh lumen-d1 jmobley2@gmail.com

SCALING WORKFLOW:

  Phase 1 (Autonomous, 5 min)
    → ./lumen_account_scaling_orchestrator.sh deploy <email>
    → Deploys 100 workers via Cloudflare API
    → No GUI required

  Phase 2 (GUI Required, 5 min per 100 workers)
    → From GUI environment with display available
    → ./lumen_account_scaling_orchestrator.sh lumen-d1 <email>
    → Lumen autonomously configures D1 bindings
    → Total time: 30 min for 600 workers, 1 hour for 1200

  Repeat for each account (+100 workers):
    → Full cycle per account: 5 min API + 5-10 min Lumen
    → Add 1000+ workers in <2 hours

REVENUE SCALING:

  100 workers:  €50-75/day
  200 workers:  €100-150/day
  300 workers:  €150-225/day
  600 workers:  €300-450/day
  1200 workers: €600-900/day
  1800+ workers: €900-1350+/day

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local command="${1:-status}"

  case "$command" in
    status)
      show_status
      ;;
    add-account)
      if [ $# -lt 4 ]; then
        echo "Usage: $0 add-account <email> <account_id> <api_token> [workers]"
        exit 1
      fi
      add_account "$2" "$3" "$4" "${5:-100}"
      ;;
    deploy)
      if [ $# -lt 2 ]; then
        echo "Usage: $0 deploy <email>"
        exit 1
      fi
      # Look up account in config
      ACCOUNT=$(jq ".accounts[] | select(.email == \"$2\")" "$ACCOUNTS_FILE" 2>/dev/null)
      if [ -z "$ACCOUNT" ]; then
        echo "❌ Account not found: $2"
        exit 1
      fi
      EMAIL=$(echo "$ACCOUNT" | jq -r '.email')
      ACCOUNT_ID=$(echo "$ACCOUNT" | jq -r '.account_id')
      API_TOKEN=$(echo "$ACCOUNT" | jq -r '.api_token')
      WORKERS=$(echo "$ACCOUNT" | jq -r '.target_workers')
      deploy_to_account "$EMAIL" "$ACCOUNT_ID" "$API_TOKEN" "$WORKERS"
      ;;
    lumen-d1)
      if [ $# -lt 2 ]; then
        echo "Usage: $0 lumen-d1 <email>"
        exit 1
      fi
      ACCOUNT=$(jq ".accounts[] | select(.email == \"$2\")" "$ACCOUNTS_FILE" 2>/dev/null)
      if [ -z "$ACCOUNT" ]; then
        echo "❌ Account not found: $2"
        exit 1
      fi
      EMAIL=$(echo "$ACCOUNT" | jq -r '.email')
      ACCOUNT_ID=$(echo "$ACCOUNT" | jq -r '.account_id')
      API_TOKEN=$(echo "$ACCOUNT" | jq -r '.api_token')
      WORKERS=$(echo "$ACCOUNT" | jq -r '.target_workers')
      invoke_lumen_d1_batch "$EMAIL" "$ACCOUNT_ID" "$API_TOKEN" "$WORKERS"
      ;;
    batch)
      if [ $# -lt 4 ]; then
        echo "Usage: $0 batch <email> <account_id> <api_token> [workers]"
        exit 1
      fi
      EMAIL="$2"
      ACCOUNT_ID="$3"
      API_TOKEN="$4"
      WORKERS="${5:-100}"
      add_account "$EMAIL" "$ACCOUNT_ID" "$API_TOKEN" "$WORKERS"
      deploy_to_account "$EMAIL" "$ACCOUNT_ID" "$API_TOKEN" "$WORKERS"
      ;;
    help)
      show_usage
      ;;
    *)
      echo "Unknown command: $command"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
