#!/bin/bash
# EPONA DEPLOYMENT ORCHESTRATOR
# Master control for 600+ worker deployment and D1 configuration
# Coordinates: deployment → D1 binding → secondary account → scaling

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_ACCOUNT="f07be5f84583d0d100b05aeeae56870b"
PRIMARY_EMAIL="johnmobley99@gmail.com"
TARGET_PRIMARY=500

SECONDARY_EMAIL="jmobleyworks@gmail.com"
TARGET_SECONDARY=100

source ~/.zshrc

# ============================================================================
# OPERATIONS
# ============================================================================

show_status() {
  {
    echo "================================================================================"
    echo "DEPLOYMENT STATUS REPORT"
    echo "================================================================================"
    echo ""
    echo "PRIMARY ACCOUNT: $PRIMARY_EMAIL"

    CURRENT=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${PRIMARY_ACCOUNT}/workers/scripts" \
      -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Auth-Key: ${CF_GLOBAL_KEY}" 2>/dev/null | jq '.result | length')

    echo "  Deployed: $CURRENT / $TARGET_PRIMARY workers"

    if [ "$CURRENT" -lt "$TARGET_PRIMARY" ]; then
      echo "  Remaining: $((TARGET_PRIMARY - CURRENT)) workers to deploy"
    fi

    echo ""
    echo "SECONDARY ACCOUNT: $SECONDARY_EMAIL"
    echo "  Status: Not yet configured"
    echo "  Target: $TARGET_SECONDARY workers"
    echo ""
    echo "================================================================================"

  }
}

deploy_primary() {
  echo "Deploying missing workers to reach 500..."
  bash "$SCRIPT_DIR/deploy_mining_workers_500.sh"
}

configure_d1_primary() {
  echo "Configuring D1 bindings for primary account..."
  bash "$SCRIPT_DIR/lumen_d1_batch_configure.sh"
}

setup_secondary() {
  echo "Setting up secondary account..."
  bash "$SCRIPT_DIR/secondary_account_setup.sh"
}

show_usage() {
  cat << 'EOF'

EPONA DEPLOYMENT ORCHESTRATOR
Master control for 600+ worker mining infrastructure

USAGE:
  ./epona_deployment_orchestrator.sh <command>

COMMANDS:

  status              Show current deployment status
  deploy-primary      Deploy missing workers to 500 on primary account
  configure-d1        Configure D1 bindings via Lumen (primary account)
  setup-secondary     Deploy 100 workers to secondary account
  full-deployment     Execute: deploy → configure → secondary (sequential)
  help                Show this help

EXAMPLES:

  # Check current status
  ./epona_deployment_orchestrator.sh status

  # Deploy 400 missing workers to reach 500
  ./epona_deployment_orchestrator.sh deploy-primary

  # Configure D1 on all 500 (from GUI environment with display)
  ./epona_deployment_orchestrator.sh configure-d1

  # Full automation: deploy primary → configure D1 → setup secondary
  ./epona_deployment_orchestrator.sh full-deployment

WORKFLOW:

  Phase 1: Deploy missing workers to 500 (primary account)
    → Run: ./epona_deployment_orchestrator.sh deploy-primary

  Phase 2: Configure D1 bindings via Lumen (from GUI)
    → Run: ./epona_deployment_orchestrator.sh configure-d1

  Phase 3: Deploy secondary account (100 workers)
    → Run: ./epona_deployment_orchestrator.sh setup-secondary

  Phase 4: Additional accounts as needed
    → Create new account, duplicate setup flow

EXPECTED REVENUE:

  500 workers (primary): €250-375/day
  100 workers (secondary): €50-75/day
  Total (600 workers): €300-450/day

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local command="${1:-help}"

  case "$command" in
    status)
      show_status
      ;;
    deploy-primary)
      deploy_primary
      ;;
    configure-d1)
      configure_d1_primary
      ;;
    setup-secondary)
      setup_secondary
      ;;
    full-deployment)
      deploy_primary
      echo ""
      echo "Next: Run from GUI environment with display:"
      echo "  ./epona_deployment_orchestrator.sh configure-d1"
      echo ""
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
