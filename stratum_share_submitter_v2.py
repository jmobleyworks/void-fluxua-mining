#!/usr/bin/env python3
"""
Stratum Share Submitter V2 - Faster, better logging
Reads from /tmp/stratum_submissions.jsonl and submits shares to local proxy
"""

import socket
import json
import time
import sys
import os
from datetime import datetime
from collections import defaultdict

POOL_HOST = "127.0.0.1"
POOL_PORT = 9999
WALLET = "4AZa4bQHDZRiU6cxpJ3mRtMAjduVAL6s2CFVRarXE9JW3iaQRgjNyBEMBAqVAJbiM9d9hjfhbJLHPKvs3bC6Qk5uT2kCwto"
WORKER_NAME = "void-flux-real-submitter"

LOG_FILE = "/tmp/stratum_share_submitter_v2.log"
SUBMISSION_FILE = os.environ.get("SUBMISSION_FILE", "/tmp/stratum_submissions_direct.jsonl")

# Stats
stats = {
    'connected': False,
    'submitted': 0,
    'accepted': 0,
    'rejected': 0,
    'connection_attempts': 0,
    'last_log_submitted': 0,
}

socket_conn = None
last_job_id = None
last_submit_line = 0


def log_msg(msg):
    """Log with timestamp"""
    ts = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    full_msg = f"[{ts}] {msg}"
    print(full_msg)
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(full_msg + "\n")
    except:
        pass


def connect_to_pool():
    """Establish socket connection to pool"""
    global socket_conn, stats

    stats['connection_attempts'] += 1

    try:
        socket_conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        socket_conn.settimeout(10.0)
        socket_conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        log_msg(f"Connecting to {POOL_HOST}:{POOL_PORT} (attempt {stats['connection_attempts']})...")
        socket_conn.connect((POOL_HOST, POOL_PORT))

        log_msg("✅ Connected to proxy")
        stats['connected'] = True

        # Send login
        login_msg = {
            "id": 1,
            "jsonrpc": "2.0",
            "method": "login",
            "params": {
                "login": WALLET,
                "pass": WORKER_NAME
            }
        }

        socket_conn.sendall((json.dumps(login_msg) + "\n").encode())
        log_msg(f"📤 Sent login")

        # Try to get initial job
        try:
            initial_data = socket_conn.recv(4096).decode()
            if initial_data:
                log_msg(f"📥 Proxy response received")
                try:
                    for line in initial_data.split('\n'):
                        if line.strip():
                            resp = json.loads(line)
                            if 'result' in resp and 'job' in resp['result']:
                                return True
                except:
                    pass
        except socket.timeout:
            log_msg("⏱️ Initial response timeout (continuing anyway)")

        return True

    except Exception as e:
        log_msg(f"❌ Connection failed: {e}")
        stats['connected'] = False
        if socket_conn:
            try:
                socket_conn.close()
            except:
                pass
            socket_conn = None
        return False


def submit_share(nonce_hex, result_hex, job_id):
    """Submit a single share to the pool"""
    global socket_conn, stats

    if not socket_conn or not stats['connected']:
        if not connect_to_pool():
            return False

    try:
        # Build share message
        share_msg = {
            "id": 2 + stats['submitted'],
            "jsonrpc": "2.0",
            "method": "submit",
            "params": {
                "id": job_id,
                "nonce": nonce_hex,
                "result": result_hex
            }
        }

        msg_str = json.dumps(share_msg) + "\n"
        socket_conn.sendall(msg_str.encode())
        stats['submitted'] += 1

        # Log every 50 submissions
        if stats['submitted'] % 50 == 0:
            log_msg(f"📊 Submitted {stats['submitted']} shares (accepted={stats['accepted']}, rejected={stats['rejected']})")

        # Try to receive response (non-blocking)
        try:
            socket_conn.settimeout(0.1)
            response_data = socket_conn.recv(1024).decode()

            if response_data:
                for line in response_data.split('\n'):
                    if line.strip():
                        try:
                            resp = json.loads(line)
                            if resp.get('error'):
                                stats['rejected'] += 1
                            elif 'result' in resp:
                                stats['accepted'] += 1
                        except:
                            pass

            socket_conn.settimeout(10.0)
        except socket.timeout:
            socket_conn.settimeout(10.0)

        return True

    except Exception as e:
        log_msg(f"❌ Submit failed: {e}")
        stats['connected'] = False
        if socket_conn:
            try:
                socket_conn.close()
            except:
                pass
            socket_conn = None
        return False


def process_submissions_fast():
    """Read and submit shares from submission file - optimized"""
    global last_submit_line

    try:
        with open(SUBMISSION_FILE, 'r') as f:
            lines = f.readlines()

        # Only process new lines since last check
        new_lines = len(lines) - last_submit_line
        if new_lines > 0:
            for line in lines[last_submit_line:]:
                if not line.strip():
                    continue

                try:
                    share = json.loads(line.strip())
                    nonce_hex = share.get('nonce_hex', '')
                    result_hex = share.get('result_hex', '')
                    job_id = share.get('job_id', '')

                    # Validate hex format (should be 64 chars)
                    if len(result_hex) == 64 and len(nonce_hex) > 0:
                        submit_share(nonce_hex, result_hex, job_id)

                except json.JSONDecodeError:
                    pass

        last_submit_line = len(lines)

    except FileNotFoundError:
        pass
    except Exception as e:
        log_msg(f"Error processing submissions: {e}")


def main():
    """Main loop"""
    log_msg("═" * 70)
    log_msg("STRATUM SHARE SUBMITTER V2 - Fast submission pipeline")
    log_msg("═" * 70)
    log_msg(f"Target: {POOL_HOST}:{POOL_PORT}")
    log_msg(f"Wallet: {WALLET[:30]}...")
    log_msg(f"Reading from: {SUBMISSION_FILE}")
    log_msg("")

    # Initial connection
    if not connect_to_pool():
        log_msg("Initial connection failed, will retry...")

    # Main loop - read and submit shares
    while True:
        try:
            process_submissions_fast()
            time.sleep(0.1)  # Faster polling
        except KeyboardInterrupt:
            log_msg("Shutting down...")
            break
        except Exception as e:
            log_msg(f"Main loop error: {e}")
            time.sleep(1)


if __name__ == '__main__':
    main()
