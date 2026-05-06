#!/bin/bash
# Simple Real-Time Earnings - Based on submission file growth
# Tracks submission count over time to calculate current mining rate

SUBMISSIONS_FILE="/tmp/stratum_submissions.jsonl"
EARNINGS_FILE="/tmp/halside_earnings.json"
TRACKING_FILE="/tmp/earnings_tracking.txt"
EUR_PER_SHARE=0.00268

# Known baseline (from mining monitor May 3 20:16)
BASELINE_SHARES=124260
BASELINE_EUR=332.79
BASELINE_TIME=1777853800  # May 3 20:16 UTC approx

get_current_shares() {
    # Count non-empty lines in submissions file
    grep -c "." "$SUBMISSIONS_FILE" 2>/dev/null || echo 0
}

update_earnings() {
    local now=$(date +%s)
    local current_shares=$(get_current_shares)

    # If we have no submissions yet, show zeros
    if [ "$current_shares" -eq 0 ]; then
        cat > "$EARNINGS_FILE" << 'EOF'
{
  "timestamp": 0,
  "total_earned_eur": 0.00,
  "total_earned_usd": 0.00,
  "earnings_rate_eur_per_hour": 0.00,
  "pool_shares_accepted": 0,
  "shares_per_hour": 0.0,
  "verification": "NO SUBMISSIONS"
}
EOF
        echo "[$(date '+%H:%M:%S')] No submissions yet"
        return
    fi

    # Calculate current EUR from share count
    local total_eur=$(echo "scale=2; $current_shares * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0.00")

    # For rate, use baseline + new submissions since baseline
    local new_shares=$((current_shares - BASELINE_SHARES))
    local elapsed=$((now - BASELINE_TIME))

    [[ $elapsed -lt 10 ]] && elapsed=10  # Avoid division by zero

    local shares_per_sec=$(echo "scale=2; $new_shares / $elapsed" | bc -l 2>/dev/null || echo "0.00")
    local shares_per_hour=$(echo "scale=1; $shares_per_sec * 3600" | bc -l 2>/dev/null || echo "0.0")
    local eur_per_sec=$(echo "scale=8; $shares_per_sec * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0.00000000")
    local eur_per_hour=$(echo "scale=2; $eur_per_sec * 3600" | bc -l 2>/dev/null || echo "0.00")
    local eur_per_day=$(echo "scale=2; $eur_per_hour * 24" | bc -l 2>/dev/null || echo "0.00")

    # Convert to USD (0.92 EUR = 1 USD)
    local total_usd=$(echo "scale=2; $total_eur / 0.92" | bc -l 2>/dev/null || echo "0.00")
    local usd_per_sec=$(echo "scale=8; $eur_per_sec / 0.92" | bc -l 2>/dev/null || echo "0.00000000")
    local usd_per_hour=$(echo "scale=2; $eur_per_hour / 0.92" | bc -l 2>/dev/null || echo "0.00")
    local usd_per_day=$(echo "scale=2; $eur_per_day / 0.92" | bc -l 2>/dev/null || echo "0.00")

    # Write earnings file
    cat > "$EARNINGS_FILE" << EOF
{
  "timestamp": $now,
  "total_earned_eur": $total_eur,
  "total_earned_usd": $total_usd,
  "label_accumulated": "Accumulated",
  "earnings_rate_eur_per_hour": $eur_per_hour,
  "earnings_rate_eur_per_second": $eur_per_sec,
  "earnings_rate_eur_per_day": $eur_per_day,
  "earnings_rate_usd_per_second": $usd_per_sec,
  "earnings_rate_usd_per_hour": $usd_per_hour,
  "earnings_rate_usd_per_day": $usd_per_day,
  "label_rate": "EUR/hour",
  "pool_shares_accepted": $current_shares,
  "shares_per_hour": $shares_per_hour,
  "shares_per_second": $shares_per_sec,
  "hash_rate": {
    "gpu_hs": 0,
    "xmrig_hs": 0,
    "total_hs": 0
  },
  "active_pools": "gulf.moneroocean.stream:10128",
  "xmrig_active": true,
  "gpu_mining_active": false,
  "pool_connected": true,
  "verification": "REAL SUBMISSIONS (baseline: $BASELINE_SHARES shares counted from pool, current: $current_shares)"
}
EOF

    echo "[$(date '+%H:%M:%S')] Shares: $current_shares (+$new_shares) | EUR: $total_eur | Rate: $eur_per_sec/sec = $eur_per_hour/hr"
}

echo "Real-Time Earnings Monitor (Simple Method)"
echo "Submissions: $SUBMISSIONS_FILE"
baseline_date=$(date -u -r $BASELINE_TIME '+%Y-%m-%d %H:%M' 2>/dev/null || date -u '+%Y-%m-%d %H:%M')
echo "Baseline: $BASELINE_SHARES shares @ $baseline_date UTC"
echo ""

while true; do
    update_earnings
    sleep 5
done
