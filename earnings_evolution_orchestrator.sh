#!/bin/bash
# MASCOM Earnings Evolution Orchestrator
# Continuously monitors, reports, and adapts mining operations for maximum profitability

set -e

MONITOR_DIR="/Users/johnmobley/mascom/void_fluxua_mining"
EARNINGS_DB="/Users/johnmobley/mascom/earnings_database.jsonl"
EVOLUTION_STATE="/tmp/earnings_evolution_state.json"

POOL_API="https://api.moneroocean.stream/miner"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

# Ensure database exists
touch "$EARNINGS_DB"

capture_snapshot() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local pool_response=$(curl -s "$POOL_API/$WALLET/stats" 2>/dev/null)

  if [ -z "$pool_response" ]; then
    return 1
  fi

  # Build JSON directly using jq to ensure proper escaping (compact single line for JSONL)
  local snapshot=$(jq -c -n \
    --arg ts "$timestamp" \
    --argjson pool "$pool_response" \
    --arg hetzner "$(ps aux | grep -c '[x]mrig' || echo 0) xmrig processes" \
    --arg submitter "$(ps aux | grep -c '[s]tratum_share_submitter' || echo 0)" \
    --arg void_flux "$(ps aux | grep -c '[v]oid_flux_bridge' || echo 0)" \
    --arg proxy "$(ps aux | grep -c '[s]tratum_proxy' || echo 0)" \
    '{timestamp: $ts, pool: $pool, hetzner_status: $hetzner, pipeline_status: {submitter: ($submitter | tonumber), void_flux: ($void_flux | tonumber), proxy: ($proxy | tonumber)}}')

  echo "$snapshot" >> "$EARNINGS_DB"
  # Pretty print for console output
  echo "$snapshot" | jq .
}

analyze_profitability() {
  echo ""
  echo "====== PROFITABILITY ANALYSIS ======"

  if [ ! -f "$EARNINGS_DB" ] || [ ! -s "$EARNINGS_DB" ]; then
    echo "Insufficient data"
    return
  fi

  # Get latest entry (last line is most recent)
  local amount_due=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.amtDue // 0' 2>/dev/null)
  local hashrate=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.hash2 // 0' 2>/dev/null)
  local valid_shares=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.validShares // 0' 2>/dev/null)

  if [ -n "$amount_due" ] && [ "$amount_due" != "0" ] && [ "$amount_due" != "null" ]; then
    # Pool returns atomic units (1 XMR = 1e12 atomic units)
    local xmr_earned=$(echo "scale=8; $amount_due / 1000000000000" | bc 2>/dev/null)
    echo "✅ Current pending: $xmr_earned XMR (atomic units: $amount_due)"

    # Convert to EUR (approx €100/XMR)
    local eur_value=$(echo "scale=2; $xmr_earned * 100" | bc 2>/dev/null)
    echo "   Estimated value: €$eur_value EUR"
  fi

  if [ -n "$hashrate" ] && [ "$hashrate" != "0" ] && [ "$hashrate" != "null" ]; then
    echo "📊 Current hashrate: $hashrate H/s"
  fi

  if [ -n "$valid_shares" ] && [ "$valid_shares" != "0" ] && [ "$valid_shares" != "null" ]; then
    echo "✅ Valid shares accumulated: $valid_shares"
  fi
}

detect_opportunities() {
  echo ""
  echo "====== EVOLUTION OPPORTUNITIES ======"

  if [ ! -f "$EARNINGS_DB" ] || [ ! -s "$EARNINGS_DB" ]; then
    return
  fi

  # Check Hetzner status
  local hetzner=$(tail -1 "$EARNINGS_DB" | jq -r '.hetzner_status // "unknown"' 2>/dev/null)
  if [[ "$hetzner" == *"0 xmrig"* ]]; then
    echo "⚠️  OPPORTUNITY 1: Hetzner machines not mining"
    echo "   Action: Run /tmp/verify_systemd_xmrig.sh to check"
  else
    echo "✅ Hetzner machines active ($hetzner)"
  fi

  # Check pipeline status
  local submitter=$(tail -1 "$EARNINGS_DB" | jq -r '.pipeline_status.submitter // 0' 2>/dev/null)
  local void_flux=$(tail -1 "$EARNINGS_DB" | jq -r '.pipeline_status.void_flux // 0' 2>/dev/null)
  local proxy=$(tail -1 "$EARNINGS_DB" | jq -r '.pipeline_status.proxy // 0' 2>/dev/null)

  if [ "$submitter" == "0" ]; then
    echo "⚠️  OPPORTUNITY 2: Stratum submitter not running"
  else
    echo "✅ Mining pipeline active (submitter: $submitter, void_flux: $void_flux, proxy: $proxy)"
  fi

  # Check payout threshold
  local amount_due=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.amtDue // 0' 2>/dev/null)
  if [ -n "$amount_due" ] && [ "$amount_due" != "0" ] && [ "$amount_due" != "null" ]; then
    # 1 XMR = 1e12 atomic units
    if (( $(echo "$amount_due >= 1000000000000" | bc -l 2>/dev/null) )); then
      echo "💰 OPPORTUNITY 3: Payment threshold reached (1+ XMR)!"
      echo "   Action: Run /Users/johnmobley/mascom/void_fluxua_mining/kraken_auto_earn.py"
    else
      local xmr_amount=$(echo "scale=6; $amount_due / 1000000000000" | bc 2>/dev/null)
      echo "   Progress toward payout: $xmr_amount XMR (need 1.0 XMR for threshold)"
    fi
  fi
}

suggest_scaling() {
  echo ""
  echo "====== SCALING RECOMMENDATIONS ======"

  if [ ! -f "$EARNINGS_DB" ] || [ ! -s "$EARNINGS_DB" ]; then
    echo "⏳ Scaling analysis: Need more data to recommend expansion"
    return
  fi

  local valid_shares=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.validShares // 0' 2>/dev/null)
  local amount_due=$(tail -1 "$EARNINGS_DB" | jq -r '.pool.amtDue // 0' 2>/dev/null)

  # At €0.00268/share: 73K shares = ~€196
  if (( $(echo "$valid_shares >= 10000" | bc -l 2>/dev/null) )); then
    echo "📈 SCALING READY: Current earnings justify expansion"
    echo ""
    echo "Option A: Deploy K-Register topology workers"
    echo "  Investment: API deployment (no hardware cost)"
    echo "  Potential: 2-5x hashrate increase"
    echo "  Action: Refresh secondary CF credentials + deploy mining-register workers"
    echo ""
    echo "Option B: Add more Hetzner machines"
    echo "  Investment: €20-30 per machine per month"
    echo "  Potential: Linear revenue increase"
    echo "  Action: Reserve budget from current earnings, deploy new machines"
  else
    echo "⏳ Scaling analysis: Accumulating data ($valid_shares valid shares / 10000 threshold)"
  fi
}

main() {
  echo "MASCOM Earnings Evolution Orchestrator"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  
  # Capture current state
  capture_snapshot
  
  # Analyze what we have
  analyze_profitability
  detect_opportunities
  suggest_scaling
  
  # Save state
  cat > "$EVOLUTION_STATE" << EOF
{
  "last_check": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "earnings_db": "$EARNINGS_DB",
  "snapshots_recorded": $(wc -l < "$EARNINGS_DB" 2>/dev/null || echo 0),
  "next_check": "in 5 minutes"
}
EOF
  
  echo ""
  echo "State saved: $EVOLUTION_STATE"
  echo "Earnings database: $EARNINGS_DB"
}

main "$@"
