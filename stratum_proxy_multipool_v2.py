#!/usr/bin/env python3
"""
STRATUM PROXY V2 - Accept shares locally, forward to multiple pools
Improved: Non-blocking I/O, no timeout issues, better connection handling
"""

import socket
import json
import time
import threading
import logging
import select
import ssl
from datetime import datetime
from collections import defaultdict

# Configuration
LOCAL_PORT = 9999
POOLS = {
    "moneroocean": {
        "host": "gulf.moneroocean.stream",
        "port": 10128,
        "wallet": "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto",
        "worker": "stratum-proxy-moneroocean",
        "enabled": True,
        "priority": 1,
        "ssl": False
    },
    "supportxmr": {
        "host": "pool.supportxmr.com",
        "port": 3333,
        "wallet": "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto",
        "worker": "stratum-proxy-supportxmr",
        "enabled": False,
        "priority": 2,
        "ssl": False
    }
}

LOG_FILE = "/Users/johnmobley/mascom/logs/stratum_proxy_v2.log"
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

pool_connections = {}
pool_threads = {}
current_job = {
    'job_id': '1',
    'target': '0000c8000000000000000000000000000000000000000000000000000000000',
    'blob': '0505000000000000000000000000000000000000000000000000000000000000' + '0' * 128
}
job_lock = threading.Lock()

# Track connected miners for broadcasting jobs
connected_miners = {}
miners_lock = threading.Lock()

# Send queue for each miner (for pending messages)
miner_send_queue = {}
queue_lock = threading.Lock()


def log_msg(msg):
    """Log message"""
    logger.info(msg)


def queue_job_for_miner(miner_id, job_data=None):
    """Queue job data to be sent to a miner"""
    if job_data is None:
        job_data = current_job

    with queue_lock:
        if miner_id not in miner_send_queue:
            miner_send_queue[miner_id] = []

        # Queue mining.set_difficulty
        difficulty_msg = {
            "id": None,
            "jsonrpc": "2.0",
            "method": "mining.set_difficulty",
            "params": [1]
        }
        miner_send_queue[miner_id].append(json.dumps(difficulty_msg) + "\n")

        # Queue mining.notify
        notify_msg = {
            "id": None,
            "jsonrpc": "2.0",
            "method": "mining.notify",
            "params": [
                job_data.get('job_id', '1'),
                job_data.get('blob', '0505' + '0' * 126),
                job_data.get('target', '0000c8000000000000000000000000000000000000000000000000000000000'),
                False
            ]
        }
        miner_send_queue[miner_id].append(json.dumps(notify_msg) + "\n")


def broadcast_job_to_all_miners(job_data=None):
    """Queue job to be sent to all connected miners"""
    if job_data is None:
        job_data = current_job

    with miners_lock:
        for miner_id in list(connected_miners.keys()):
            queue_job_for_miner(miner_id, job_data)


def connect_to_pool(pool_name):
    """Establish connection to a mining pool"""
    pool_config = POOLS[pool_name]

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10.0)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        log_msg(f"Connecting to {pool_name} ({pool_config['host']}:{pool_config['port']}) [SSL: {pool_config.get('ssl', False)}]...")
        sock.connect((pool_config['host'], pool_config['port']))

        # Wrap with SSL if required
        if pool_config.get('ssl', False):
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            sock = context.wrap_socket(sock, server_hostname=pool_config['host'])
            log_msg(f"🔒 SSL/TLS negotiated with {pool_name}")

        log_msg(f"✅ Connected to {pool_name}")

        # Send login - format varies by pool
        if pool_name == "supportxmr":
            # SupportXMR requires agent field in login
            login_msg = {
                "id": 1,
                "jsonrpc": "2.0",
                "method": "login",
                "params": {
                    "login": pool_config['wallet'],
                    "pass": "",
                    "agent": "stratum-proxy/2.0"
                }
            }
        else:
            # MoneroOcean uses separate login and pass fields
            login_msg = {
                "id": 1,
                "jsonrpc": "2.0",
                "method": "login",
                "params": {
                    "login": pool_config['wallet'],
                    "pass": pool_config['worker'],
                    "agent": "stratum-proxy/2.0"
                }
            }

        sock.sendall((json.dumps(login_msg) + "\n").encode())
        log_msg(f"📤 Sent login to {pool_name}: {login_msg['params']}")

        # Receive login response from pool
        try:
            sock.settimeout(5)
            login_response = sock.recv(4096).decode()
            if login_response:
                log_msg(f"📥 Pool login response: {login_response[:200]}")
        except:
            pass
        sock.settimeout(None)

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

                                # Log pool method for debugging
                                if msg.get('method'):
                                    if msg.get('method') not in ['mining.notify']:  # don't spam logs
                                        log_msg(f"📨 {pool_name}: Method {msg.get('method')}")

                                # Handle mining.notify from pool (new job)
                                if msg.get('method') == 'mining.notify':
                                    params = msg.get('params', [])
                                    if len(params) >= 3:
                                        with job_lock:
                                            current_job['job_id'] = params[0]
                                            current_job['blob'] = params[1]
                                            current_job['target'] = params[2]
                                        log_msg(f"⚡ {pool_name}: New job {current_job['job_id']}, broadcasting to miners...")
                                        broadcast_job_to_all_miners()

                                # Handle share rejection/acceptance
                                elif msg.get('error'):
                                    stats['shares_rejected'][pool_name] += 1
                                    if stats['shares_rejected'][pool_name] % 100 == 0:
                                        log_msg(f"⚠️ {pool_name}: {stats['shares_rejected'][pool_name]} shares rejected")

                                elif msg.get('result') or 'job' in msg.get('result', {}):
                                    stats['shares_accepted'][pool_name] += 1
                                    if stats['shares_accepted'][pool_name] % 10 == 0:
                                        log_msg(f"✅ {pool_name}: {stats['shares_accepted'][pool_name]} shares ACCEPTED")

                                    # Update job if provided in result
                                    if 'job' in msg.get('result', {}):
                                        with job_lock:
                                            job_info = msg['result']['job']
                                            current_job['job_id'] = job_info.get('job_id', '1')
                                            current_job['blob'] = job_info.get('blob', current_job['blob'])
                                            current_job['target'] = job_info.get('target', current_job['target'])
                                        broadcast_job_to_all_miners()

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
                pass

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
        log_msg(f"📤 Forwarded share #{stats['shares_forwarded'][pool_name]} to {pool_name}")

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
    """Handle incoming miner connection (non-blocking)"""
    stats['connections'] += 1
    miner_id = f"miner-{stats['connections']}"

    try:
        log_msg(f"🔗 Miner connected: {miner_id} from {client_addr}")

        # Set non-blocking mode
        client_socket.setblocking(False)

        buffer = ""
        last_activity = time.time()
        idle_timeout = 120  # 2 minutes idle timeout

        while True:
            try:
                # Non-blocking receive
                try:
                    data = client_socket.recv(4096).decode()
                    if data:
                        last_activity = time.time()
                        buffer += data
                    else:
                        # Connection closed by client
                        break
                except BlockingIOError:
                    # No data available, check for timeout
                    if time.time() - last_activity > idle_timeout:
                        log_msg(f"⚠️ {miner_id}: Idle timeout, disconnecting")
                        break
                    time.sleep(0.01)  # Brief sleep to avoid spinning
                    continue

                # Send any queued messages for this miner
                with queue_lock:
                    if miner_id in miner_send_queue and miner_send_queue[miner_id]:
                        try:
                            while miner_send_queue[miner_id]:
                                queued_msg = miner_send_queue[miner_id].pop(0)
                                client_socket.sendall(queued_msg.encode() if isinstance(queued_msg, str) else queued_msg)
                        except:
                            pass

                # Process complete lines from buffer
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    if not line.strip():
                        continue

                    try:
                        msg = json.loads(line)

                        # Handle login
                        if msg.get('method') == 'login':
                            # Register miner for job broadcasts
                            with miners_lock:
                                connected_miners[miner_id] = client_socket

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

                            # Queue difficulty and current job to be sent
                            queue_job_for_miner(miner_id)

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

                                # Always accept locally
                                response = {
                                    "id": msg.get('id', 2),
                                    "jsonrpc": "2.0",
                                    "result": True
                                }
                                client_socket.sendall((json.dumps(response) + "\n").encode())

                                if stats['shares_received'] % 100 == 0:
                                    total_accepted = sum(stats['shares_accepted'].values())
                                    log_msg(f"📊 Total shares: received={stats['shares_received']}, accepted={total_accepted}")
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
                log_msg(f"❌ Error in miner handler ({miner_id}): {e}")
                break

    except Exception as e:
        log_msg(f"❌ Miner handler error ({miner_id}): {e}")

    finally:
        try:
            client_socket.close()
        except:
            pass
        # Remove from connected miners and queue
        with miners_lock:
            if miner_id in connected_miners:
                del connected_miners[miner_id]
        with queue_lock:
            if miner_id in miner_send_queue:
                del miner_send_queue[miner_id]
        log_msg(f"🔌 Miner disconnected: {miner_id}")


def start_local_server():
    """Start local stratum server accepting miners"""
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind(('127.0.0.1', LOCAL_PORT))
    server_socket.listen(10)

    log_msg(f"🎯 Stratum Proxy V2 listening on 127.0.0.1:{LOCAL_PORT}")
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
    log_msg("STRATUM PROXY V2 - Multi-Pool Share Aggregator (Non-Blocking)")
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
