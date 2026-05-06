#!/usr/bin/env python3
"""
Kraken Auto-Sell: Convert XMR to USD
Runs daily at 12:05 AM UTC (5 minutes after Monero withdrawal)
Automatically sells any accumulated XMR for USD at market price
"""

import os
import sys
import json
import time
import sqlite3
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("ERROR: requests library not installed. Install with: pip3 install requests")
    sys.exit(1)

# ============================================================================
# CONFIGURATION
# ============================================================================

LOG_FILE = "/tmp/kraken_auto_sell.log"
KRAKEN_API_URL = "https://api.kraken.com"
KRAKEN_API_VERSION = "0"
MIN_XMR_TO_SELL = 0.01
CONVERSION_LEDGER = "/tmp/kraken_conversions.jsonl"

# ============================================================================
# CREDENTIALS MANAGEMENT
# ============================================================================

def load_kraken_credentials():
    """Load Kraken API credentials from keys.mobdb"""
    try:
        keys_db = Path.home() / "mascom" / "keys.mobdb"
        if not keys_db.exists():
            log_msg("ERROR: Keys database not found")
            return None, None, None

        conn = sqlite3.connect(str(keys_db))
        cursor = conn.cursor()

        # Query Kraken credentials
        api_key_query = cursor.execute(
            "SELECT value FROM keys WHERE id = 'kraken_api_key' LIMIT 1"
        )
        api_key = api_key_query.fetchone()
        api_key = api_key[0] if api_key else None

        api_secret_query = cursor.execute(
            "SELECT value FROM keys WHERE id = 'kraken_api_secret' LIMIT 1"
        )
        api_secret = api_secret_query.fetchone()
        api_secret = api_secret[0] if api_secret else None

        api_password_query = cursor.execute(
            "SELECT value FROM keys WHERE id = 'kraken_api_password' LIMIT 1"
        )
        api_password = api_password_query.fetchone()
        api_password = api_password[0] if api_password else None

        conn.close()

        if not api_key or not api_secret:
            log_msg("ERROR: Kraken credentials not found in database")
            log_msg("Store with: sqlite3 ~/mascom/keys.mobdb")
            log_msg("  INSERT INTO keys VALUES ('kraken_api_key', '<key>', 'kraken_key', datetime('now'))")
            log_msg("  INSERT INTO keys VALUES ('kraken_api_secret', '<secret>', 'kraken_secret', datetime('now'))")
            return None, None, None

        return api_key, api_secret, api_password

    except Exception as e:
        log_msg(f"ERROR loading credentials: {e}")
        return None, None, None

# ============================================================================
# KRAKEN API INTERACTION
# ============================================================================

def kraken_private_request(endpoint, params, api_key, api_secret):
    """Make authenticated private request to Kraken API"""
    import hmac
    import hashlib
    import base64
    import urllib.parse

    # Add nonce to prevent replay attacks
    nonce = str(int(time.time() * 1000))
    params['nonce'] = nonce

    # Create request string
    data = urllib.parse.urlencode(params)

    # Create message hash
    message = f"{params['nonce']}{data}".encode('utf-8')
    message_hash = hashlib.sha256(message).digest()

    # Create signature
    signature = hmac.new(
        base64.b64decode(api_secret),
        f"{endpoint.encode('utf-8')}{message_hash}",
        hashlib.sha512
    )
    signature_b64 = base64.b64encode(signature.digest()).decode('utf-8')

    # Make request
    headers = {
        'API-Sign': signature_b64,
        'API-Key': api_key,
    }

    url = f"{KRAKEN_API_URL}/{KRAKEN_API_VERSION}/private/{endpoint}"

    try:
        response = requests.post(url, data=params, headers=headers, timeout=10)
        return response.json()
    except Exception as e:
        log_msg(f"ERROR: Kraken API request failed: {e}")
        return None

# ============================================================================
# LOGGING
# ============================================================================

def log_msg(message):
    """Log message with timestamp"""
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    line = f"[{timestamp}] {message}"
    print(line)
    with open(LOG_FILE, 'a') as f:
        f.write(line + '\n')

# ============================================================================
# MAIN FUNCTIONALITY
# ============================================================================

def get_xmr_balance(api_key, api_secret):
    """Get current XMR balance in Kraken account"""
    result = kraken_private_request("Balance", {}, api_key, api_secret)

    if not result or result.get('error'):
        log_msg(f"ERROR: Failed to get balance: {result.get('error', 'Unknown error')}")
        return 0

    # Kraken uses 'XXMZ' for Monero
    balance = result.get('result', {}).get('XXMZ', 0)
    try:
        return float(balance)
    except (ValueError, TypeError):
        return 0

def sell_xmr_for_usd(xmr_amount, api_key, api_secret):
    """Place market sell order: XMR → USD"""
    params = {
        'pair': 'XMRUSD',
        'type': 'sell',
        'ordertype': 'market',
        'volume': str(round(xmr_amount, 8)),
    }

    result = kraken_private_request("AddOrder", params, api_key, api_secret)

    if not result or result.get('error'):
        log_msg(f"ERROR: Failed to place sell order: {result.get('error', 'Unknown error')}")
        return None

    return result.get('result', {})

def record_conversion(xmr_amount, usd_received):
    """Record the conversion in ledger"""
    entry = {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "event": "xmr_sold_to_usd",
        "xmr_amount": round(xmr_amount, 8),
        "usd_amount": round(usd_received, 2),
        "rate": round(usd_received / xmr_amount, 2) if xmr_amount > 0 else 0,
        "status": "complete"
    }

    with open(CONVERSION_LEDGER, 'a') as f:
        f.write(json.dumps(entry) + '\n')

    return entry

# ============================================================================
# EXECUTION
# ============================================================================

def main():
    """Main execution"""
    log_msg("====== Kraken Auto-Sell (XMR → USD) ======")

    # Load credentials
    api_key, api_secret, _ = load_kraken_credentials()
    if not api_key or not api_secret:
        log_msg("ABORT: Cannot proceed without Kraken credentials")
        return 1

    # Get current XMR balance
    xmr_balance = get_xmr_balance(api_key, api_secret)
    log_msg(f"Current Kraken XMR balance: {xmr_balance}")

    if xmr_balance < MIN_XMR_TO_SELL:
        log_msg(f"Balance below minimum ({MIN_XMR_TO_SELL} XMR), skipping sell")
        return 0

    # Place market sell order
    log_msg(f"Placing market sell order: {xmr_balance} XMR → USD")
    order_result = sell_xmr_for_usd(xmr_balance, api_key, api_secret)

    if not order_result:
        log_msg("ERROR: Failed to place sell order")
        return 1

    # Get current XMR→USD rate for logging
    try:
        # Estimate USD received (actual rate will be determined by order fill)
        rate_response = requests.get("https://api.kraken.com/0/public/Ticker?pair=XMRUSD")
        if rate_response.status_code == 200:
            ticker = rate_response.json().get('result', {}).get('XXMRZUSD', {})
            last_price = float(ticker.get('c', [0])[0])
            estimated_usd = xmr_balance * last_price
        else:
            estimated_usd = xmr_balance * 22.50  # Fallback estimate

        log_msg(f"✅ Sell order placed successfully")
        log_msg(f"  XMR sold: {xmr_balance}")
        log_msg(f"  Estimated USD: ${estimated_usd:.2f}")
        log_msg(f"  Actual fill price: Check Kraken dashboard")

        # Record conversion
        record_conversion(xmr_balance, estimated_usd)

        log_msg(f"Next step: ACH withdrawal (Friday 2pm UTC)")
        return 0

    except Exception as e:
        log_msg(f"ERROR: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
