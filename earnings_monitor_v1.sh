#!/bin/bash
# MASCOM Earnings Monitor & Evolution System
# Tracks mining revenue, detects trends, triggers adaptive optimization

EARNINGS_LOG="/Users/johnmobley/mascom/earnings_history.jsonl"
POOL_API="https://api.moneroocean.stream/miner"
WALLET="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
KRAKEN_API_KEY="${KRAKEN_API_KEY:-}"

# Initialize log
touch "$EARNINGS_LOG"

log_earnings() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local stats=$(curl -s "$POOL_API/$WALLET/stats" 2>/dev/null)
  
  if [ -z "$stats" ]; then
    echo "[$timestamp] ERROR: Pool API unreachable"
    return 1
  fi
  
  local hashrate=$(echo "$stats" | jq -r '.hashrate // "null"')
  local amount_due=$(echo "$stats" | jq -r '.amountDue // "null"')
  local total_hashes=$(echo "$stats" | jq -r '.totalHashes // "null"')
  
  # Calculate daily rate if we have amountDue
  local daily_rate="null"
  if [ "$amount_due" != "null" ] && [ "$amount_due" != "0" ]; then
    # Assume payout accumulates daily
    daily_rate=$(echo "$amount_due" | awk '{print $1 * 0.268}')  # Monero rate approx
  fi
  
  # Log entry
  local entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "hashrate": $hashrate,
  "amount_due_xmr": $amount_due,
  "total_hashes": $total_hashes,
  "estimated_daily_eur": $daily_rate,
  "pool": "moneroocean"
}
EOF
)
  
  echo "$entry" >> "$EARNINGS_LOG"
  echo "$entry"
}

# Analyze trends
analyze_trends() {
  echo ""
  echo "====== EARNINGS TREND ANALYSIS ======"
  
  local recent=$(tail -10 "$EARNINGS_LOG" 2>/dev/null)
  if [ -z "$recent" ]; then
    echo "Insufficient data for trend analysis"
    return
  fi
  
  # Extract amountDue values
  local amounts=$(echo "$recent" | jq -r '.amount_due_xmr // "null"' 2>/dev/null | grep -v null)
  
  if [ -z "$amounts" ]; then
    echo "No payout data yet (amountDue still null on pool)"
    echo "Once amountDue > 0, trends will appear here"
    return
  fi
  
  # Calculate average
  local avg=$(echo "$amounts" | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
  echo "Average amountDue: $avg XMR"
  
  # Detect uptrend or downtrend
  local last=$(echo "$amounts" | tail -1)
  local first=$(echo "$amounts" | head -1)
  if (( $(echo "$last > $first" | bc -l) )); then
    echo "Trend: 📈 UPWARD (earnings accelerating)"
  elif (( $(echo "$last < $first" | bc -l) )); then
    echo "Trend: 📉 DOWNWARD (earnings declining)"
  else
    echo "Trend: ➡️ STABLE (consistent earnings)"
  fi
}

# Trigger optimization
trigger_evolution() {
  echo ""
  echo "====== EVOLUTION TRIGGERS ======"
  
  # Get latest stats
  local latest=$(tail -1 "$EARNINGS_LOG" 2>/dev/null)
  local amount_due=$(echo "$latest" | jq -r '.amount_due_xmr // "0"')
  
  # Trigger 1: Payment threshold reached
  if (( $(echo "$amount_due >= 0.5" | bc -l) )); then
    echo "✅ TRIGGER 1: Payment threshold reached ($amount_due XMR)"
    echo "   Action: Set up Kraken auto-deposit"
    # Would trigger kraken integration here
  fi
  
  # Trigger 2: Daily rate >100 EUR
  local daily=$(echo "$latest" | jq -r '.estimated_daily_eur // "0"')
  if (( $(echo "$daily >= 100" | bc -l) )); then
    echo "✅ TRIGGER 2: High daily earnings ($daily EUR/day)"
    echo "   Action: Scale to secondary K-Register topology"
  fi
  
  # Trigger 3: Idle pool connection
  local hashrate=$(echo "$latest" | jq -r '.hashrate // "null"')
  if [ "$hashrate" = "null" ]; then
    echo "⚠️  TRIGGER 3: Pool not reporting hashrate"
    echo "   Action: Check Hetzner machine connection status"
    echo "   Remediation: /tmp/check_deployment.sh"
  fi
}

# Main
echo "MASCOM Earnings Monitor Starting..."
echo ""

log_earnings
analyze_trends
trigger_evolution

echo ""
echo "Earnings log: $EARNINGS_LOG"
echo "Next check: $(date -u +%H:%M:%SZ) + 60 seconds"
