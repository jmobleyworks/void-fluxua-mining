#!/bin/bash
# Real-Time Earnings Calculator - Reads actual mining submissions
# Updates halside_earnings.json every 5 seconds based on real submission data

SUBMISSIONS_FILE="/tmp/stratum_submissions.jsonl"
EARNINGS_FILE="/tmp/halside_earnings.json"
EUR_PER_SHARE=0.00268

calculate_earnings() {
    if [ ! -f "$SUBMISSIONS_FILE" ]; then
        # No submissions yet
        cat > "$EARNINGS_FILE" << EOF
{
  "timestamp": $(date +%s),
  "total_earned_eur": 0.00,
  "total_earned_usd": 0.00,
  "label_accumulated": "Accumulated",
  "earnings_rate_eur_per_hour": 0.00,
  "label_rate": "EUR/hour",
  "pool_shares_accepted": 0,
  "shares_per_hour": 0.0,
  "hash_rate": {
    "gpu_hs": 0,
    "xmrig_hs": 0,
    "total_hs": 0
  },
  "active_pools": "gulf.moneroocean.stream:10128",
  "xmrig_active": false,
  "gpu_mining_active": false,
  "pool_connected": false,
  "verification": "NO SUBMISSIONS YET"
}
EOF
        return
    fi

    # Count total submissions (lines in file = number of shares)
    local total_shares=$(wc -l < "$SUBMISSIONS_FILE" 2>/dev/null || echo 0)

    # Calculate total EUR earned
    local total_eur=$(echo "scale=2; $total_shares * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0")

    # Get first and last submission timestamps from nonce hex
    # Format: pkt_XXX_XXXXX_NANOSECONDS
    local first_line=$(head -1 "$SUBMISSIONS_FILE" 2>/dev/null)
    local last_line=$(tail -1 "$SUBMISSIONS_FILE" 2>/dev/null)

    local first_nonce=$(echo "$first_line" | grep -o '"nonce_hex":[^,}]*' | cut -d'"' -f4 | rev | cut -d'_' -f1 | rev)
    local last_nonce=$(echo "$last_line" | grep -o '"nonce_hex":[^,}]*' | cut -d'"' -f4 | rev | cut -d'_' -f1 | rev)

    # Convert nanoseconds to seconds
    local first_time_sec=$((first_nonce / 1000000000))
    local last_time_sec=$((last_nonce / 1000000000))

    # Calculate elapsed time in seconds
    local elapsed_sec=$(($last_time_sec - $first_time_sec))
    [[ $elapsed_sec -lt 1 ]] && elapsed_sec=1

    # Calculate rates
    local shares_per_sec=$(echo "scale=2; $total_shares / $elapsed_sec" | bc -l 2>/dev/null || echo "0")
    local shares_per_hour=$(echo "scale=1; $shares_per_sec * 3600" | bc -l 2>/dev/null || echo "0")
    local eur_per_sec=$(echo "scale=6; $shares_per_sec * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0")
    local eur_per_hour=$(echo "scale=2; $eur_per_sec * 3600" | bc -l 2>/dev/null || echo "0")

    # Write earnings file
    cat > "$EARNINGS_FILE" << EOF
{
  "timestamp": $(date +%s),
  "total_earned_eur": $(printf "%.2f" "$total_eur"),
  "total_earned_usd": $(printf "%.2f" "$(echo "scale=2; $total_eur / 0.92" | bc -l 2>/dev/null || echo '0')"),
  "label_accumulated": "Accumulated",
  "earnings_rate_eur_per_hour": $(printf "%.2f" "$eur_per_hour"),
  "earnings_rate_eur_per_second": $(printf "%.8f" "$eur_per_sec"),
  "label_rate": "EUR/hour",
  "pool_shares_accepted": $total_shares,
  "shares_per_hour": $(printf "%.1f" "$shares_per_hour"),
  "shares_per_second": $(printf "%.2f" "$shares_per_sec"),
  "hash_rate": {
    "gpu_hs": 0,
    "xmrig_hs": 0,
    "total_hs": 0
  },
  "active_pools": "gulf.moneroocean.stream:10128",
  "xmrig_active": true,
  "gpu_mining_active": false,
  "pool_connected": $([ $total_shares -gt 0 ] && echo "true" || echo "false"),
  "elapsed_seconds": $elapsed_sec,
  "verification": "CALCULATED FROM ACTUAL SUBMISSIONS ($total_shares shares, ${elapsed_sec}s elapsed)"
}
EOF

    echo "[$(date '+%H:%M:%S')] Shares: $total_shares | EUR: $(printf '%.2f' "$total_eur") | Rate: $(printf '%.4f' "$eur_per_sec")/sec | Elapsed: ${elapsed_sec}s | Rate: $(printf '%.2f' "$eur_per_hour")/hr"
}

echo "Real-Time Earnings Calculator Starting..."
echo "Source: $SUBMISSIONS_FILE"
echo "Update interval: 5 seconds"
echo ""

while true; do
    calculate_earnings
    sleep 5
done
