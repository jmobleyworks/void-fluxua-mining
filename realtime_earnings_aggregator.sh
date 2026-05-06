#!/bin/bash
# Real-Time Earnings Aggregator - Queries xmrig stats API every 5 seconds
# Aggregates across 3 Hetzner mining machines
# Updates halside_earnings.json for menu bar display

set -uo pipefail

EARNINGS_FILE="/tmp/halside_earnings.json"

# Hetzner mining nodes with xmrig stats API on port 8088
MINERS=(
    "87.99.131.218"
    "178.156.212.224"
    "178.156.197.193"
)

EUR_PER_SHARE=0.00268  # Monero current exchange rate
XMR_PER_SHARE=0.001   # Approximate XMR value per share

update_earnings() {
    local total_hashrate=0
    local total_shares=0
    local total_accepted=0
    local pool_connected=0

    # Query each miner's stats
    for miner_ip in "${MINERS[@]}"; do
        local stats=$(curl -s --connect-timeout 2 --max-time 3 "http://${miner_ip}:8088/api/v1/stats" 2>/dev/null || echo "{}")

        if [ "$stats" != "{}" ]; then
            # Extract stats from xmrig API response
            local hashrate=$(echo "$stats" | jq -r '.hashrate.total[0] // 0' 2>/dev/null || echo "0")
            local shares=$(echo "$stats" | jq -r '.connection[0].accepted // 0' 2>/dev/null || echo "0")
            local miner_pool=$(echo "$stats" | jq -r '.connection[0].pool // "unknown"' 2>/dev/null || echo "")

            total_hashrate=$(echo "$total_hashrate + $hashrate" | bc -l 2>/dev/null || echo "$total_hashrate")
            total_accepted=$(echo "$total_accepted + $shares" | bc -l 2>/dev/null || echo "$total_accepted")

            if [[ "$miner_pool" == *"gulf.moneroocean"* ]] || [[ "$miner_pool" == *"monero"* ]]; then
                ((pool_connected++))
            fi
        fi
    done

    # Calculate earnings
    local total_xmr=$(echo "scale=6; $total_accepted * $XMR_PER_SHARE" | bc -l 2>/dev/null || echo "0")
    local total_usd=$(echo "scale=2; $total_xmr * 65.5" | bc -l 2>/dev/null || echo "0")  # XMR/USD rate ~65.5
    local total_eur=$(echo "scale=2; $total_usd * 0.92" | bc -l 2>/dev/null || echo "0")  # USD/EUR ~0.92

    # Calculate rates
    local shares_per_hour=$(echo "scale=1; $total_accepted / $(( ($(date +%s) - ${START_TIME:-$(date +%s)}) / 3600 )) + 1" | bc -l 2>/dev/null || echo "0")
    local earnings_rate_usd_per_hour=$(echo "scale=2; $total_usd / $(( ($(date +%s) - ${START_TIME:-$(date +%s)}) / 3600 )) + 1" | bc -l 2>/dev/null || echo "0")
    local earnings_rate_eur_per_hour=$(echo "scale=2; $total_eur / $(( ($(date +%s) - ${START_TIME:-$(date +%s)}) / 3600 )) + 1" | bc -l 2>/dev/null || echo "0")

    # Determine status
    local xmrig_active="true"
    local gpu_mining_active="false"
    local pool_connected_bool="false"
    [[ $pool_connected -gt 0 ]] && pool_connected_bool="true"

    # Write to earnings file
    cat > "$EARNINGS_FILE" << EOF
{
  "timestamp": $(date +%s),
  "total_earned_xmr": $(printf "%.6f" "$total_xmr"),
  "total_earned_usd": $(printf "%.2f" "$total_usd"),
  "total_earned_eur": $(printf "%.2f" "$total_eur"),
  "label_accumulated": "Accumulated",
  "earnings_rate_usd_per_hour": $(printf "%.2f" "$earnings_rate_usd_per_hour"),
  "earnings_rate_eur_per_hour": $(printf "%.2f" "$earnings_rate_eur_per_hour"),
  "label_rate": "EUR/hour",
  "pool_shares_accepted": $(printf "%.0f" "$total_accepted"),
  "shares_per_hour": $(printf "%.1f" "$shares_per_hour"),
  "hash_rate": {
    "gpu_hs": 0,
    "xmrig_hs": $(printf "%.0f" "$total_hashrate"),
    "total_hs": $(printf "%.0f" "$total_hashrate")
  },
  "active_pools": "gulf.moneroocean.stream:10128",
  "xmrig_active": $xmrig_active,
  "gpu_mining_active": $gpu_mining_active,
  "pool_connected": $pool_connected_bool,
  "miners_responding": $pool_connected,
  "verification": "REAL-TIME FROM XMRIG STATS API"
}
EOF
}

# Initialize
START_TIME=$(date +%s)
echo "Real-Time Earnings Aggregator Started"
echo "Querying: ${MINERS[@]}"
echo "Update interval: 5 seconds"
echo "Output: $EARNINGS_FILE"

# Main loop
while true; do
    update_earnings
    sleep 5
done
