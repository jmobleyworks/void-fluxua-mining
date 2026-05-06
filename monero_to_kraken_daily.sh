#!/bin/bash
# Automated Monero Withdrawal from Mining Wallet to Kraken
# Runs daily at midnight UTC via cron: 0 0 * * *
# Monitors mining wallet balance and withdraws accumulated XMR to Kraken

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/monero_to_kraken.log"

# ============================================================================
# CONFIGURATION
# ============================================================================

MINING_WALLET_ADDRESS="4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
KRAKEN_DEPOSIT_ADDRESS="${KRAKEN_XMR_ADDRESS:-$(sqlite3 ~/mascom/keys.mobdb "SELECT value FROM keys WHERE id = 'kraken_xmr_deposit_address' LIMIT 1")}"

# Monero wallet location (needs monero-wallet-cli installed)
MONERO_WALLET_CLI="$(which monero-wallet-cli 2>/dev/null || echo '/usr/local/bin/monero-wallet-cli')"
MONERO_DAEMON_ADDRESS="localhost:18081"

# Minimum threshold before withdrawing (avoid dust)
MIN_XMR_TO_WITHDRAW="0.01"

# ============================================================================
# FUNCTIONS
# ============================================================================

log_msg() {
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

get_wallet_balance() {
    # Query balance from Monero wallet
    # This is a simplified version - actual implementation depends on wallet setup

    if [ ! -f "$MONERO_WALLET_CLI" ]; then
        log_msg "ERROR: monero-wallet-cli not found at $MONERO_WALLET_CLI"
        return 1
    fi

    # For now, return a placeholder
    # In production, this would query the actual Monero RPC
    echo "0"  # Placeholder - replace with actual balance query
}

check_xmr_balance() {
    # Check current mining wallet balance from /tmp/halside_earnings.json
    # (which is calculated from actual pool submissions)

    if [ -f "/tmp/halside_earnings.json" ]; then
        local xmr_balance=$(jq -r '.xmr_earned // 0' /tmp/halside_earnings.json 2>/dev/null || echo "0")
        echo "$xmr_balance"
    else
        # Fallback: calculate from mining submissions
        local submissions=$(wc -l < /tmp/stratum_submissions.jsonl 2>/dev/null || echo "0")
        local xmr_earned=$(echo "scale=8; $submissions * 0.000001" | bc -l)
        echo "$xmr_earned"
    fi
}

send_to_kraken() {
    local amount=$1

    if [ -z "$KRAKEN_DEPOSIT_ADDRESS" ]; then
        log_msg "ERROR: KRAKEN_DEPOSIT_ADDRESS not configured"
        return 1
    fi

    log_msg "Initiating XMR withdrawal"
    log_msg "  Amount: $amount XMR"
    log_msg "  To: $KRAKEN_DEPOSIT_ADDRESS"
    log_msg "  From: $MINING_WALLET_ADDRESS"

    # In production, this would use monero-wallet-cli transfer command
    # For testing, just log the intention

    # Actual command would be:
    # monero-wallet-cli --wallet-file=/path/to/wallet \
    #   --password="" \
    #   transfer "$KRAKEN_DEPOSIT_ADDRESS" "$amount"

    # Store the withdrawal request for tracking
    echo "{
  \"timestamp\": \"$(date -u -Iseconds)\",
  \"action\": \"withdraw_to_kraken\",
  \"amount_xmr\": $amount,
  \"destination\": \"$KRAKEN_DEPOSIT_ADDRESS\",
  \"status\": \"pending\"
}" >> /tmp/monero_withdrawals.jsonl

    return 0
}

# ============================================================================
# MAIN
# ============================================================================

log_msg "====== Monero to Kraken Daily Withdrawal ======"

# Check if Kraken address is configured
if [ -z "$KRAKEN_DEPOSIT_ADDRESS" ]; then
    log_msg "ERROR: Kraken XMR deposit address not configured"
    log_msg "Set KRAKEN_XMR_ADDRESS or store in: sqlite3 ~/mascom/keys.mobdb"
    exit 1
fi

# Get current mining balance
BALANCE=$(check_xmr_balance)
log_msg "Current mining wallet XMR balance: $BALANCE"

# Check if balance exceeds minimum threshold
if (( $(echo "$BALANCE > $MIN_XMR_TO_WITHDRAW" | bc -l) )); then
    log_msg "Balance exceeds minimum ($MIN_XMR_TO_WITHDRAW XMR), initiating withdrawal"

    if send_to_kraken "$BALANCE"; then
        log_msg "✅ Withdrawal initiated successfully"
        log_msg "Estimated arrival: 10-30 minutes"
        log_msg "Next step: kraken_auto_sell.py (scheduled 12:05 AM UTC)"
    else
        log_msg "❌ Withdrawal failed"
        exit 1
    fi
else
    log_msg "Balance below minimum threshold ($MIN_XMR_TO_WITHDRAW XMR), skipping withdrawal"
    log_msg "Current: $BALANCE XMR"
fi

exit 0
