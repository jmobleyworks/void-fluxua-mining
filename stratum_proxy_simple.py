#!/usr/bin/env python3
"""
STRATUM PROXY - Simple bidirectional relay with proper login handling
"""

import socket
import json
import threading
import time
import logging
from datetime import datetime

# Configuration
LOCAL_PORT = 9999
POOL_HOST = "gulf.moneroocean.stream"
POOL_PORT = 10128
WALLET = "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"

LOG_FILE = "/Users/johnmobley/mascom/logs/stratum_proxy_simple.log"
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

def log_msg(msg):
    logger.info(msg)

# Global pool connection
pool_socket = None
pool_lock = threading.Lock()

def connect_to_pool():
    """Establish and maintain connection to pool"""
    global pool_socket

    while True:
        try:
            pool_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            pool_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

            log_msg(f"Connecting to {POOL_HOST}:{POOL_PORT}...")
            pool_socket.connect((POOL_HOST, POOL_PORT))
            log_msg(f"✅ Connected to pool")

            # Send login
            login_msg = {
                "id": 1,
                "jsonrpc": "2.0",
                "method": "login",
                "params": {
                    "login": WALLET,
                    "pass": "stratum-proxy",
                    "agent": "stratum-proxy/1.0"
                }
            }
            pool_socket.sendall((json.dumps(login_msg) + "\n").encode())
            log_msg(f"📤 Sent pool login")

            # Now relay forever (will break if connection drops)
            while True:
                time.sleep(1)

        except Exception as e:
            log_msg(f"❌ Pool connection error: {e}")
            try:
                pool_socket.close()
            except:
                pass
            pool_socket = None
            time.sleep(5)

def relay_bidirectional(client_socket, client_addr, miner_id):
    """Relay messages between miner and pool"""

    miner_connected = True
    login_handled = False

    def miner_to_pool():
        nonlocal miner_connected, login_handled
        try:
            client_socket.settimeout(60)
            while miner_connected and pool_socket:
                try:
                    data = client_socket.recv(4096)
                    if not data:
                        break

                    # Try to parse as JSON
                    try:
                        lines = data.decode().strip().split('\n')
                        for line in lines:
                            if not line.strip():
                                continue
                            msg = json.loads(line)

                            # Handle miner login - respond locally
                            if msg.get('method') == 'login' and not login_handled:
                                login_handled = True
                                response = {
                                    "id": msg.get('id', 1),
                                    "jsonrpc": "2.0",
                                    "result": {
                                        "id": miner_id,
                                        "job": {
                                            "job_id": "1",
                                            "target": "0000c8000000000000000000000000000000000000000000000000000000000"
                                        }
                                    }
                                }
                                client_socket.sendall((json.dumps(response) + "\n").encode())
                                log_msg(f"✅ {miner_id}: Login accepted, waiting for pool jobs...")

                                # Send difficulty and a dummy job
                                diff_msg = {
                                    "id": None,
                                    "jsonrpc": "2.0",
                                    "method": "mining.set_difficulty",
                                    "params": [256]
                                }
                                client_socket.sendall((json.dumps(diff_msg) + "\n").encode())
                                continue

                            # Forward other messages to pool
                            with pool_lock:
                                if pool_socket:
                                    pool_socket.sendall((json.dumps(msg) + "\n").encode())

                    except json.JSONDecodeError:
                        # Not JSON, just relay as-is
                        pass

                except socket.timeout:
                    pass

        except Exception as e:
            log_msg(f"❌ Miner->Pool error ({miner_id}): {e}")
        finally:
            miner_connected = False

    def pool_to_miner():
        nonlocal miner_connected
        try:
            pool_socket.settimeout(60)
            buffer = ""
            while miner_connected:
                try:
                    data = pool_socket.recv(4096).decode()
                    if not data:
                        break

                    buffer += data

                    # Process complete lines
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        if not line.strip():
                            continue

                        try:
                            msg = json.loads(line)

                            # Log important messages
                            method = msg.get('method')
                            if method in ['mining.notify', 'mining.set_difficulty']:
                                log_msg(f"📨 Pool: {method}")

                            # Forward to miner
                            client_socket.sendall((json.dumps(msg) + "\n").encode())

                        except json.JSONDecodeError:
                            pass

                except socket.timeout:
                    pass

        except Exception as e:
            log_msg(f"❌ Pool->Miner error ({miner_id}): {e}")
        finally:
            miner_connected = False

    # Start relay threads
    t1 = threading.Thread(target=miner_to_pool, daemon=True)
    t2 = threading.Thread(target=pool_to_miner, daemon=True)
    t1.start()
    t2.start()

    # Wait for either direction to close
    while miner_connected:
        time.sleep(0.5)

    # Cleanup
    try:
        client_socket.close()
    except:
        pass
    log_msg(f"🔌 {miner_id} disconnected")

def main():
    log_msg("═" * 70)
    log_msg("STRATUM PROXY - Simple Bidirectional Relay")
    log_msg("═" * 70)
    log_msg(f"Listen: 127.0.0.1:{LOCAL_PORT}")
    log_msg(f"Pool: {POOL_HOST}:{POOL_PORT}")
    log_msg("")

    # Start pool connection thread
    pool_thread = threading.Thread(target=connect_to_pool, daemon=True)
    pool_thread.start()
    time.sleep(2)

    # Start local server
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", LOCAL_PORT))
    server.listen(10)
    log_msg(f"🎯 Listening for miners...")

    miner_count = 0
    try:
        while True:
            client_socket, client_addr = server.accept()
            miner_count += 1
            miner_id = f"miner-{miner_count}"
            log_msg(f"🔗 {miner_id} connected from {client_addr}")

            thread = threading.Thread(
                target=relay_bidirectional,
                args=(client_socket, client_addr, miner_id),
                daemon=True
            )
            thread.start()

    except KeyboardInterrupt:
        log_msg("Shutting down...")
    finally:
        server.close()

if __name__ == "__main__":
    main()
