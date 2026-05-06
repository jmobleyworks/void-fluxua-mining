#!/usr/bin/env python3
"""
STRATUM PROXY - Accept shares locally, forward to multiple pools
Implements pool-like behavior while maintaining full control of share routing
"""

import socket
import json
import time
import threading
import logging
from datetime import datetime
from collections import defaultdict, deque

# Configuration
LOCAL_PORT = 9999  # Accept miners on this port
POOLS = {
    "moneroocean": {
        "host": "gulf.moneroocean.stream",
        "port": 10128,
        "wallet": "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto",
        "worker": "stratum-proxy-moneroocean",
        "enabled": True,
        "priority": 1
    },
    "supportxmr": {
        "host": "pool.supportxmr.com",
        "port": 3333,
        "wallet": "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto",
        "worker": "stratum-proxy-supportxmr",
        "enabled": True,
        "priority": 2
    }
}

LOG_FILE = "/tmp/stratum_proxy.log"
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Stats
stats = {
    'shares_received': 0,
    'shares_forwarded': defaultdict(int),
    'shares_accepted': defaultdict(int),
    'shares_rejected': defaultdict(int),
    'connections': 0,
    'connection_errors': 0,
}

pool_connections = {}  # {pool_name: socket}
pool_threads = {}      # {pool_name: thread}
current_job = {
    'job_id': '1',
    'target': '0000c8000000000000000000000000000000000000000000000000000000000'
}
job_lock = threading.Lock()


def log_msg(msg):
    """Log message"""
    logger.info(msg)


def connect_to_pool(pool_name):
    """Establish connection to a mining pool"""
    pool_config = POOLS[pool_name]

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10.0)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        log_msg(f"Connecting to {pool_name} ({pool_config['host']}:{pool_config['port']})...")
        sock.connect((pool_config['host'], pool_config['port']))

        log_msg(f"✅ Connected to {pool_name}")

        # Send login
        login_msg = {
            "id": 1,
            "jsonrpc": "2.0",
            "method": "login",
            "params": {
                "login": pool_config['wallet'],
                "pass": pool_config['worker']
            }
        }

        sock.sendall((json.dumps(login_msg) + "\n").encode())
        log_msg(f"📤 Sent login to {pool_name}")

        pool_connections[pool_name] = sock
        return sock

    except Exception as e:
        log_msg(f"❌ Connection to {pool_name} failed: {e}")
        stats['connection_errors'] += 1
        return None


def pool_listener(pool_name):
    """Listen for responses from a pool"""
    while True:
        try:
            if pool_name not in pool_connections:
                sock = connect_to_pool(pool_name)
                if not sock:
                    time.sleep(5)
                    continue
            else:
                sock = pool_connections[pool_name]

            # Listen for messages
            try:
                sock.settimeout(30.0)
                data = sock.recv(4096).decode()

                if data:
                    for line in data.split('\n'):
                        if line.strip():
                            try:
                                msg = json.loads(line)

                                if msg.get('error'):
                                    stats['shares_rejected'][pool_name] += 1
                                    if stats['shares_rejected'][pool_name] % 100 == 0:
                                        log_msg(f"⚠️ {pool_name}: {stats['shares_rejected'][pool_name]} shares rejected")

                                elif msg.get('result') or 'job' in msg.get('result', {}):
                                    stats['shares_accepted'][pool_name] += 1
                                    if stats['shares_accepted'][pool_name] % 50 == 0:
                                        log_msg(f"✅ {pool_name}: {stats['shares_accepted'][pool_name]} shares ACCEPTED")

                                    # Update job if provided
                                    if 'job' in msg.get('result', {}):
                                        with job_lock:
                                            current_job['job_id'] = msg['result']['job'].get('job_id', '1')

                            except json.JSONDecodeError:
                                pass
                else:
                    # Connection closed
                    log_msg(f"⚠️ {pool_name}: Connection closed, reconnecting...")
                    if pool_name in pool_connections:
                        try:
                            pool_connections[pool_name].close()
                        except:
                            pass
                        del pool_connections[pool_name]

            except socket.timeout:
                pass  # Continue listening

        except Exception as e:
            log_msg(f"❌ Pool listener error ({pool_name}): {e}")
            if pool_name in pool_connections:
                try:
                    pool_connections[pool_name].close()
                except:
                    pass
                del pool_connections[pool_name]
            time.sleep(5)


def forward_share_to_pool(pool_name, share_msg):
    """Forward a share to a specific pool"""
    try:
        if pool_name not in pool_connections:
            sock = connect_to_pool(pool_name)
            if not sock:
                return False
        else:
            sock = pool_connections[pool_name]

        msg_str = json.dumps(share_msg) + "\n"
        sock.sendall(msg_str.encode())
        stats['shares_forwarded'][pool_name] += 1

        return True

    except Exception as e:
        log_msg(f"❌ Failed to forward share to {pool_name}: {e}")
        if pool_name in pool_connections:
            try:
                pool_connections[pool_name].close()
            except:
                pass
            del pool_connections[pool_name]
        return False


def forward_share_to_all_pools(share_msg):
    """Forward share to all enabled pools"""
    forwarded_count = 0

    for pool_name, pool_config in POOLS.items():
        if pool_config['enabled']:
            if forward_share_to_pool(pool_name, share_msg):
                forwarded_count += 1

    return forwarded_count


def handle_miner_connection(client_socket, client_addr):
    """Handle incoming miner connection"""
    stats['connections'] += 1
    miner_id = f"miner-{stats['connections']}"

    try:
        log_msg(f"🔗 Miner connected: {miner_id} from {client_addr}")
        client_socket.settimeout(10.0)

        while True:
            # Receive from miner
            data = client_socket.recv(4096).decode()

            if not data:
                break

            for line in data.split('\n'):
                if not line.strip():
                    continue

                try:
                    msg = json.loads(line)

                    # Handle login
                    if msg.get('method') == 'login':
                        response = {
                            "id": msg.get('id', 1),
                            "jsonrpc": "2.0",
                            "result": {
                                "id": miner_id,
                                "job": {
                                    "job_id": current_job['job_id'],
                                    "target": current_job['target']
                                }
                            }
                        }
                        client_socket.sendall((json.dumps(response) + "\n").encode())
                        log_msg(f"✅ {miner_id}: Login accepted")

                    # Handle share submission
                    elif msg.get('method') == 'submit':
                        stats['shares_received'] += 1

                        # Validate share format
                        nonce = msg.get('params', {}).get('nonce', '')
                        result = msg.get('params', {}).get('result', '')

                        if len(result) == 64:  # Valid SHA256 hash
                            # Forward to all pools
                            pool_share_msg = {
                                "id": msg.get('id', 2),
                                "jsonrpc": "2.0",
                                "method": "submit",
                                "params": {
                                    "id": miner_id,
                                    "nonce": nonce,
                                    "result": result
                                }
                            }

                            forwarded = forward_share_to_all_pools(pool_share_msg)

                            # Always accept locally (we'll relay to pools)
                            response = {
                                "id": msg.get('id', 2),
                                "jsonrpc": "2.0",
                                "result": True
                            }
                            client_socket.sendall((json.dumps(response) + "\n").encode())

                            if stats['shares_received'] % 100 == 0:
                                total_accepted = sum(stats['shares_accepted'].values())
                                log_msg(f"📊 Shares: received={stats['shares_received']}, accepted={total_accepted}, forwarded={forwarded}")
                        else:
                            # Invalid format
                            response = {
                                "id": msg.get('id', 2),
                                "jsonrpc": "2.0",
                                "error": "Invalid share format"
                            }
                            client_socket.sendall((json.dumps(response) + "\n").encode())

                except json.JSONDecodeError:
                    pass

    except Exception as e:
        log_msg(f"❌ Miner handler error ({miner_id}): {e}")

    finally:
        try:
            client_socket.close()
        except:
            pass
        log_msg(f"🔌 Miner disconnected: {miner_id}")


def start_local_server():
    """Start local stratum server accepting miners"""
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind(('127.0.0.1', LOCAL_PORT))
    server_socket.listen(10)

    log_msg(f"🎯 Stratum Proxy listening on 127.0.0.1:{LOCAL_PORT}")
    log_msg(f"📍 Forwarding shares to {len([p for p in POOLS.values() if p['enabled']])} pools")

    try:
        while True:
            client_socket, client_addr = server_socket.accept()
            thread = threading.Thread(
                target=handle_miner_connection,
                args=(client_socket, client_addr),
                daemon=True
            )
            thread.start()
    except KeyboardInterrupt:
        log_msg("Shutting down...")
    finally:
        server_socket.close()


def main():
    """Main entry point"""
    log_msg("═" * 70)
    log_msg("STRATUM PROXY - Multi-Pool Share Aggregator")
    log_msg("═" * 70)
    log_msg(f"Local server: 127.0.0.1:{LOCAL_PORT}")
    log_msg(f"Configured pools: {list(POOLS.keys())}")
    log_msg("")

    # Start pool listener threads
    for pool_name, pool_config in POOLS.items():
        if pool_config['enabled']:
            thread = threading.Thread(
                target=pool_listener,
                args=(pool_name,),
                daemon=True
            )
            thread.start()
            pool_threads[pool_name] = thread
            log_msg(f"📡 Started listener thread for {pool_name}")

    time.sleep(1)

    # Start local server
    start_local_server()


if __name__ == '__main__':
    main()
