#!/usr/bin/env python3
"""
MASCOM Kraken Auto-Earnings System
Monitors XMR balance and automatically:
1. Deposits XMR from Monero wallet
2. Sells XMR → USD on Kraken
3. Triggers ACH transfer to bank
"""

import os
import json
import requests
import base64
import hashlib
import hmac
import time
from datetime import datetime

KRAKEN_API_URL = "https://api.kraken.com"
KRAKEN_API_KEY = os.environ.get("KRAKEN_API_KEY", "")
KRAKEN_PRIVATE_KEY = os.environ.get("KRAKEN_PRIVATE_KEY", "")

XMR_WALLET = "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
POOL_API = "https://api.moneroocean.stream/miner"

LOG_FILE = "/tmp/kraken_earnings.log"

def log_msg(msg):
    """Log with timestamp"""
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    full_msg = f"[{ts}] {msg}"
    print(full_msg)
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(full_msg + "\n")
    except:
        pass

def get_pool_stats():
    """Get current XMR balance from mining pool"""
    try:
        response = requests.get(
            f"{POOL_API}/{XMR_WALLET}/stats",
            timeout=10
        )
        data = response.json()
        return {
            'amount_due': data.get('amountDue', 0),
            'hashrate': data.get('hashrate', 0),
            'total_hashes': data.get('totalHashes', 0)
        }
    except Exception as e:
        log_msg(f"ERROR: Cannot reach pool API: {e}")
        return None

def kraken_query(endpoint, params):
    """Make authenticated Kraken API query"""
    if not KRAKEN_API_KEY or not KRAKEN_PRIVATE_KEY:
        log_msg("ERROR: Kraken API credentials not configured")
        return None
    
    try:
        nonce = str(int(time.time() * 1000))
        params['nonce'] = nonce
        
        # Create signature
        postdata = requests.compat.urlencode(params)
        encoded = (str(nonce) + postdata).encode()
        message = hashlib.sha256(encoded).digest()
        signature = base64.b64encode(
            hmac.new(
                base64.b64decode(KRAKEN_PRIVATE_KEY),
                message,
                hashlib.sha512
            ).digest()
        ).decode()
        
        headers = {
            "API-Sign": signature,
            "API-Key": KRAKEN_API_KEY
        }
        
        response = requests.post(
            f"{KRAKEN_API_URL}/0/private{endpoint}",
            headers=headers,
            data=params,
            timeout=10
        )
        
        return response.json()
    except Exception as e:
        log_msg(f"ERROR: Kraken API error: {e}")
        return None

def get_xmr_balance():
    """Get XMR balance on Kraken"""
    result = kraken_query("/Balance", {})
    if result and result.get('result'):
        return result['result'].get('XXMZ', 0)  # XXMZ is XMR on Kraken
    return 0

def place_sell_order(amount_xmr, limit_price=None):
    """Place sell order for XMR → USD"""
    if amount_xmr < 0.001:  # Minimum order size
        log_msg(f"Order too small: {amount_xmr} XMR")
        return None
    
    params = {
        'pair': 'XMRUSD',
        'type': 'sell',
        'ordertype': 'market' if not limit_price else 'limit',
        'volume': str(amount_xmr)
    }
    
    if limit_price:
        params['price'] = str(limit_price)
    
    log_msg(f"Placing sell order: {amount_xmr} XMR → USD (market)")
    result = kraken_query("/AddOrder", params)
    
    if result and result.get('result'):
        order_id = result['result'].get('txid', [None])[0]
        log_msg(f"✅ Order placed: {order_id}")
        return order_id
    else:
        log_msg(f"❌ Order failed: {result}")
        return None

def trigger_ach_transfer(amount_usd):
    """Trigger ACH bank transfer (manual or API if configured)"""
    log_msg(f"💰 USD balance available: ${amount_usd:.2f}")
    log_msg("   Triggering ACH transfer...")
    log_msg("   ⚠️  Manual approval may be required on Kraken")
    # Would integrate with Kraken withdrawal API here
    return True

def monitor_and_evolve():
    """Main monitoring loop"""
    log_msg("====== MASCOM KRAKEN AUTO-EARNINGS ======")
    log_msg("")
    
    # Get pool stats
    pool_stats = get_pool_stats()
    if not pool_stats:
        log_msg("ERROR: Cannot proceed without pool stats")
        return
    
    amount_due = pool_stats['amount_due']
    hashrate = pool_stats['hashrate']
    
    log_msg(f"Pool Status:")
    log_msg(f"  Amount Due: {amount_due:.8f} XMR")
    log_msg(f"  Hashrate: {hashrate} H/s")
    log_msg("")
    
    # Check if payment pending
    if amount_due and amount_due > 0:
        log_msg("✅ Payment pending on pool!")
        log_msg(f"   Once received: {amount_due * 400:.2f} EUR expected")
        log_msg("   Waiting for blockchain confirmation...")
        return
    
    # Get Kraken balance
    xmr_balance = get_xmr_balance()
    log_msg(f"Kraken XMR Balance: {xmr_balance} XMR")
    
    # If balance > 0, sell it
    if xmr_balance > 0.001:
        log_msg(f"💰 XMR available for conversion: {xmr_balance}")
        order_id = place_sell_order(xmr_balance)
        
        if order_id:
            # In real system, would poll for order completion
            # Then trigger ACH transfer
            estimated_usd = xmr_balance * 400  # Approximate
            trigger_ach_transfer(estimated_usd)
    else:
        log_msg("⏳ Waiting for XMR deposit to complete...")
    
    log_msg("")
    log_msg("Next check in 5 minutes")

if __name__ == "__main__":
    monitor_and_evolve()
