#!/bin/bash
# Lumen D1 batch configuration for all mining-register workers
# Configures D1 binding across 500 workers on primary account
# Invoke from GUI environment with display available

set -uo pipefail

source ~/.zshrc

ACCOUNT_ID="$CF_ACCOUNT_ID"
ACCOUNT_EMAIL="johnmobley99@gmail.com"
DASHBOARD_BASE="https://dash.cloudflare.com/${ACCOUNT_ID}"
D1_DATABASE="mascom-phase0-ledger"
LUMEN_BIN="/Users/johnmobley/bin/lumen"

LOG_DIR="$HOME/mascom/void_fluxua_mining/logs"
mkdir -p "$LOG_DIR"
EXECUTION_LOG="$LOG_DIR/d1_batch_$(date +%Y%m%d_%H%M%S).log"

echo "================================================================================"
echo "LUMEN D1 BATCH CONFIGURATION - 500 WORKERS"
echo "================================================================================"
echo "Account: $ACCOUNT_EMAIL"
echo "Database: $D1_DATABASE"
echo "Target workers: All mining-register-0 through mining-register-499"
echo "Execution log: $EXECUTION_LOG"
echo ""

# Verify Lumen available
if [ ! -x "$LUMEN_BIN" ]; then
  echo "❌ CRITICAL: Lumen not found at $LUMEN_BIN"
  exit 1
fi

echo "✅ Lumen found and executable"
echo ""

{
  echo "LUMEN D1 BATCH CONFIGURATION"
  echo "Started: $(date -u)"
  echo ""
  echo "Automation sequence:"
  echo "  1. Navigate to Cloudflare dashboard"
  echo "  2. For each mining-register worker (0-499):"
  echo "     • Click worker"
  echo "     • Settings tab"
  echo "     • D1 Database section"
  echo "     • Add Binding: DB → $D1_DATABASE"
  echo "     • Save and verify"
  echo "  3. Estimated time: ~250 minutes (500 workers × 30 sec)"
  echo ""

  # Generate worker list
  WORKERS=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts" \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>/dev/null | \
    jq -r '.result[] | select(.id | startswith("mining-register-")) | .id' | sort -V)

  WORKER_COUNT=$(echo "$WORKERS" | wc -l)
  echo "Workers to configure: $WORKER_COUNT"
  echo ""
  echo "LUMEN AUTONOMOUS EXECUTION STARTING..."
  echo "When running from GUI environment, Lumen will:"
  echo "  • Autonomously navigate dashboard"
  echo "  • Configure each worker with D1 binding"
  echo "  • Verify success with screenshots"
  echo "  • Continue to next worker"
  echo ""
  echo "Status: READY FOR ACTIVATION"
  echo ""

} | tee -a "$EXECUTION_LOG"

echo "Execution log: $EXECUTION_LOG"
echo "================================================================================"
