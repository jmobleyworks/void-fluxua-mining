#!/usr/bin/env python3
"""
Void Fluxua Mining Bridge - v2 with Robust Socket Recovery
Automatically reconnects to pool when socket dies
"""

import socket
import json
import time
import os
import sys
import subprocess
from datetime import datetime

# Configuration
POOL_HOST = "gulf.moneroocean.stream"
POOL_PORT = 10128
WALLET = "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
WORKER_NAME = "void-flux-bridge-v2"

CF_ACCOUNT = os.environ.get('CF_ACCOUNT_ID')
CF_EMAIL = os.environ.get('CF_EMAIL')
CF_KEY = os.environ.get('CF_GLOBAL_KEY')
D1_UUID = "db6adeef-1db0-4973-b4e0-f40413edcb70"

LOG_FILE = f"/tmp/void_fluxua_bridge_v2_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"

# Stats
stats = {'submitted': 0, 'accepted': 0, 'rejected': 0}
current_job_id = "1"
current_target = None

def log_msg(msg):
    """Log message with timestamp"""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    full_msg = f"[{ts}] {msg}"
    print(full_msg)
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(full_msg + "\n")
    except:
        pass

def get_recent_packets(last_packet_id=0, limit=100):
    """Query D1 for recent packets"""
    sql = f"SELECT id, from_worker, to_worker, latency_ms, timestamp FROM packet_arrivals WHERE id > {last_packet_id} ORDER BY id ASC LIMIT {limit}"

    curl_cmd = [
        'curl', '-s',
        f'https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT}/d1/database/{D1_UUID}/query',
        '-H', f'X-Auth-Email: {CF_EMAIL}',
        '-H', f'X-Auth-Key: {CF_KEY}',
        '-H', 'Content-Type: application/json',
        '-d', json.dumps({'sql': sql})
    ]

    try:
        result = subprocess.run(curl_cmd, capture_output=True, text=True, timeout=10)
        response = json.loads(result.stdout)
        packets = response.get('result', [{}])[0].get('results', [])
        return packets
    except Exception as e:
        log_msg(f"Error querying D1: {e}")
        return []

def packet_to_share(packet_id, from_worker, to_worker, latency, timestamp):
    """Convert packet pattern to share"""
    # Extract worker index (handle 'unknown' values)
    try:
        from_idx = int(from_worker.replace('mining-register-', '')) if from_worker and 'mining-register-' in from_worker else 0
        to_idx = int(to_worker.replace('mining-register-', '')) if to_worker and 'mining-register-' in to_worker else 0
    except (ValueError, AttributeError):
        from_idx = 0
        to_idx = 0

    # Convert timestamp to int if needed
    if isinstance(timestamp, str):
        ts_seed = int(timestamp.replace('-', '').replace(':', '').replace('T', '').replace('Z', ''))
    else:
        ts_seed = int(timestamp) if timestamp else 0

    # Deterministic nonce from packet properties
    nonce_seed = (packet_id * 73856093) ^ (from_idx * 19349663) ^ (to_idx * 83492791) ^ (latency % 4096)
    nonce = f"{nonce_seed % 4294967296:08x}"

    # Deterministic hash
    hash_seed = (ts_seed * 2654435761) ^ (nonce_seed * 2246822519)
    hash_val = f"{hash_seed % (2**63):064x}"

    return nonce, hash_val

def connect_to_pool():
    """Create a new connection to the pool"""
    global current_job_id

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.connect((POOL_HOST, POOL_PORT))
        log_msg("✅ Connected to pool")

        # Authorize
        auth_msg = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "mining.authorize",
            "params": [f"{WALLET}.{WORKER_NAME}", "x"]
        }
        sock.sendall((json.dumps(auth_msg) + "\n").encode())

        # Read auth response and any initial messages
        try:
            response = sock.recv(4096).decode('utf-8', errors='ignore').strip()
            if response:
                log_msg(f"Auth response: {response[:80]}")
                # Check if there's a mining.notify in the response
                for line in response.split('\n'):
                    if line.strip():
                        try:
                            msg = json.loads(line)
                            if msg.get('method') == 'mining.notify' and msg.get('params'):
                                current_job_id = msg['params'][0]
                                log_msg(f"🔔 Initial job ID: {current_job_id}")
                        except:
                            pass
        except socket.timeout:
            log_msg("⚠️ No immediate response, continuing...")

        return sock
    except Exception as e:
        log_msg(f"❌ Failed to connect: {e}")
        return None

def read_pool_messages(sock):
    """Try to read pending messages from pool (non-blocking)"""
    global current_job_id, current_target

    try:
        sock.setblocking(False)
        try:
            data = sock.recv(4096).decode('utf-8', errors='ignore')
            sock.setblocking(True)

            if not data:
                return False  # Connection closed

            # Process each line
            for line in data.split('\n'):
                line = line.strip()
                if not line:
                    continue

                try:
                    msg = json.loads(line)
                    if msg.get('method') == 'mining.notify' and msg.get('params'):
                        current_job_id = msg['params'][0]
                        current_target = msg['params'][8] if len(msg['params']) > 8 else None
                        log_msg(f"🔔 Job update: {current_job_id}")
                    elif msg.get('method') == 'mining.set_difficulty':
                        diff = msg['params'][0]
                        log_msg(f"📊 Difficulty: {diff}")
                    elif msg.get('id') == 2:  # Share response
                        if msg.get('result') == True:
                            stats['accepted'] += 1
                            log_msg(f"✅ Share accepted! (total: {stats['accepted']})")
                        elif msg.get('error'):
                            stats['rejected'] += 1
                            log_msg(f"❌ Share rejected: {msg.get('error')}")
                except json.JSONDecodeError:
                    pass

            return True
        except BlockingIOError:
            sock.setblocking(True)
            return True  # No data available, socket is ok
    except Exception as e:
        log_msg(f"⚠️ Message read error: {e}")
        return False

def submit_share(sock, worker, job_id, nonce, result_hash):
    """Submit share via stratum protocol"""
    submit_msg = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "mining.submit",
        "params": [f"{WALLET}.{worker}", job_id, "0", nonce, result_hash]
    }

    try:
        sock.sendall((json.dumps(submit_msg) + "\n").encode())
        stats['submitted'] += 1
        return True
    except (BrokenPipeError, OSError, socket.error) as e:
        log_msg(f"  ⚠️ Socket error on send: {e}")
        return False

def main():
    """Main mining bridge loop"""
    global current_job_id

    log_msg("🌀 VOID FLUXUA MINING BRIDGE - v2 with Socket Recovery")
    log_msg(f"Pool: {POOL_HOST}:{POOL_PORT}")
    log_msg(f"Wallet: {WALLET}")
    log_msg("")

    if not all([CF_ACCOUNT, CF_EMAIL, CF_KEY]):
        log_msg("❌ Missing CloudFlare credentials in environment")
        sys.exit(1)

    last_packet_id = 0
    sync_count = 0
    reconnect_attempts = 0

    sock = None

    try:
        while True:
            # Reconnect if needed
            if sock is None:
                log_msg(f"Attempting to connect (attempt {reconnect_attempts + 1})...")
                sock = connect_to_pool()
                if sock is None:
                    reconnect_attempts += 1
                    if reconnect_attempts > 5:
                        log_msg("❌ Too many reconnection failures, exiting")
                        break
                    log_msg(f"Waiting 5s before retry...")
                    time.sleep(5)
                    continue
                reconnect_attempts = 0

            # Try to read any pending messages
            if not read_pool_messages(sock):
                log_msg("❌ Socket appears dead, will reconnect")
                sock.close()
                sock = None
                time.sleep(1)
                continue

            # Query D1 every 10 seconds
            if sync_count % 10 == 0:
                log_msg(f"📊 Querying D1 (last_id={last_packet_id}, current_job={current_job_id})...")
                packets = get_recent_packets(last_packet_id, limit=100)

                if packets:
                    log_msg(f"Found {len(packets)} new packets")
                    failed_count = 0

                    for packet in packets:
                        packet_id = packet.get('id', 0)
                        from_w = packet.get('from_worker', 'mining-register-0')
                        to_w = packet.get('to_worker', 'mining-register-0')
                        latency = packet.get('latency_ms', 100)
                        timestamp = packet.get('timestamp', 0)

                        # Convert to share
                        nonce, hash_val = packet_to_share(packet_id, from_w, to_w, latency, timestamp)

                        log_msg(f"→ Share (job={current_job_id}, nonce={nonce}, from={from_w})")

                        if not submit_share(sock, WORKER_NAME, current_job_id, nonce, hash_val):
                            failed_count += 1
                            if failed_count > 3:
                                log_msg("❌ Multiple send failures, reconnecting...")
                                sock.close()
                                sock = None
                                break

                        last_packet_id = packet_id

                    log_msg(f"📈 Stats: Submitted={stats['submitted']} | Accepted={stats['accepted']} | Rejected={stats['rejected']}")
                else:
                    log_msg("No new packets in D1")

            sync_count += 1
            time.sleep(1)

    except KeyboardInterrupt:
        log_msg("⏸ Bridge stopped by user")
    except Exception as e:
        log_msg(f"❌ Error: {e}")
        import traceback
        log_msg(traceback.format_exc())
    finally:
        if sock:
            sock.close()
            log_msg("Socket closed")

if __name__ == "__main__":
    main()
