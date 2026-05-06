#!/bin/bash
# Real-Time Earnings Aggregator - SSH to xmrig instances
# Queries actual shares and hashrate from mining machines
# Updates halside_earnings.json every 5 seconds for menu bar

set -uo pipefail

EARNINGS_FILE="/tmp/halside_earnings.json"
START_TIME=$(date +%s)

# Hetzner mining nodes (as arrays to avoid arithmetic issues)
MINER_IPS=("87.99.131.218" "178.156.212.224" "178.156.197.193")
MINER_USER="root"

EUR_PER_SHARE=0.00268
HETZNER_SSH_KEY="/Users/johnmobley/.ssh/id_ed25519"

update_earnings() {
    local total_hashrate=0
    local total_shares=0
    local total_accepted=0
    local miners_active=0

    for ip in "${MINER_IPS[@]}"; do
        local user="$MINER_USER"

        # Query xmrig stats via SSH (curl from remote machine)
        local stats=$(ssh -i "$HETZNER_SSH_KEY" -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
            "$user@$ip" "curl -s http://127.0.0.1:8088/api/v1/stats 2>/dev/null" 2>/dev/null || echo "{}")

        if [[ "$stats" != "{}" ]] && [[ -n "$stats" ]]; then
            # Parse xmrig response
            local hashrate=$(echo "$stats" | jq -r '.hashrate.total[0] // 0' 2>/dev/null || echo "0")
            local accepted=$(echo "$stats" | jq -r '.connection[0].accepted // 0' 2>/dev/null || echo "0")
            local pool=$(echo "$stats" | jq -r '.connection[0].pool // ""' 2>/dev/null || echo "")

            # Add to totals
            total_hashrate=$(echo "scale=0; $total_hashrate + ${hashrate%.*}" | bc 2>/dev/null || echo "$total_hashrate")
            total_accepted=$(echo "scale=0; $total_accepted + ${accepted%.*}" | bc 2>/dev/null || echo "$total_accepted")

            if [[ -n "$pool" ]]; then
                ((miners_active++))
            fi
        fi
    done

    # Calculate cumulative earnings from total shares
    local total_eur=$(echo "scale=2; $total_accepted * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0")

    # Calculate current rates
    local elapsed=$(($(date +%s) - START_TIME))
    [[ $elapsed -lt 1 ]] && elapsed=1

    local shares_per_second=$(echo "scale=2; $total_accepted / $elapsed" | bc -l 2>/dev/null || echo "0")
    local shares_per_hour=$(echo "scale=1; $shares_per_second * 3600" | bc -l 2>/dev/null || echo "0")
    local eur_per_second=$(echo "scale=6; $shares_per_second * $EUR_PER_SHARE" | bc -l 2>/dev/null || echo "0")
    local eur_per_hour=$(echo "scale=2; $eur_per_second * 3600" | bc -l 2>/dev/null || echo "0")

    # Write earnings file
    cat > "$EARNINGS_FILE" << EOF
{
  "timestamp": $(date +%s),
  "total_earned_eur": $(printf "%.2f" "$total_eur"),
  "total_earned_usd": $(printf "%.2f" "$(echo "scale=2; $total_eur / 0.92" | bc -l 2>/dev/null || echo '0')"),
  "label_accumulated": "Accumulated",
  "earnings_rate_eur_per_hour": $(printf "%.2f" "$eur_per_hour"),
  "earnings_rate_eur_per_second": $(printf "%.8f" "$eur_per_second"),
  "label_rate": "EUR/hour",
  "pool_shares_accepted": $(printf "%.0f" "$total_accepted"),
  "shares_per_hour": $(printf "%.1f" "$shares_per_hour"),
  "shares_per_second": $(printf "%.2f" "$shares_per_second"),
  "hash_rate": {
    "gpu_hs": 0,
    "xmrig_hs": $(printf "%.0f" "$total_hashrate"),
    "total_hs": $(printf "%.0f" "$total_hashrate")
  },
  "active_pools": "gulf.moneroocean.stream:10128",
  "xmrig_active": true,
  "gpu_mining_active": false,
  "pool_connected": $([ $miners_active -gt 0 ] && echo "true" || echo "false"),
  "miners_responding": $miners_active,
  "verification": "REAL-TIME FROM XMRIG STATS API VIA SSH"
}
EOF

    echo "[$(date '+%H:%M:%S')] Total Shares: $total_accepted | EUR: $(printf '%.2f' "$total_eur") | Rate: $(printf '%.4f' "$eur_per_second")/sec | Hashrate: $(printf '%.0f' "$total_hashrate") H/s | Miners: $miners_active/3"
}

echo "Real-Time Earnings Aggregator (SSH Mode) Starting..."
echo "Update interval: 5 seconds"
echo "Hetzner nodes: ${MINER_IPS[@]}"
echo ""

while true; do
    update_earnings
    sleep 5
done
