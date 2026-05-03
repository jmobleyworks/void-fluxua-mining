#!/bin/bash
# PERSISTENT VOID FLUXUA MINING RESTART SCRIPT
# Run this to restore mining after crash/reboot
# Location: ~/mascom/void_fluxua_mining/RESTART_MINING.sh

set -euo pipefail

MINING_DIR="$HOME/mascom/void_fluxua_mining"
DATA_DIR="/tmp/void_fluxua_data"  # /tmp is OK for data, but scripts are backed up
SUBMIT_LOG="$DATA_DIR/stratum_submissions.jsonl"
QEC_LOG="$DATA_DIR/qec_corrections.jsonl"

# Ensure /tmp data directory exists
mkdir -p "$DATA_DIR"

# Ensure /tmp symbolic links to persistent scripts (in case they're called from /tmp)
ln -sf "$MINING_DIR/qec_generator.sh" /tmp/qec_generator.sh
ln -sf "$MINING_DIR/void_flux_bridge_local.sh" /tmp/void_flux_bridge_local.sh
ln -sf "$MINING_DIR/stratum_job_server.py" /tmp/stratum_job_server.py
ln -sf "$MINING_DIR/mining_monitor.sh" /tmp/mining_monitor.sh

echo "╔════════════════════════════════════════════════════════════╗"
echo "║    VOID FLUXUA MINING - EMERGENCY RESTART                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Mining Directory: $MINING_DIR"
echo "Data Directory:   $DATA_DIR"
echo ""

# Kill any existing processes
echo "Stopping any existing mining processes..."
pkill -f "qec_generator.sh" || true
pkill -f "void_flux_bridge_local" || true
pkill -f "mining_monitor.sh" || true
pkill -f "stratum_job_server.py" || true
sleep 2

# Start Stratum Job Server (Python - HTTP pool simulator)
echo "Starting Stratum Job Server..."
nohup python3 "$MINING_DIR/stratum_job_server.py" > "$DATA_DIR/stratum_server.log" 2>&1 &
SERVER_PID=$!
sleep 2
if ps -p $SERVER_PID > /dev/null 2>&1; then
  echo "✅ Stratum Job Server started (PID: $SERVER_PID)"
else
  echo "❌ Stratum Job Server failed to start"
  exit 1
fi

# Start QEC Generator (generates mining work - 46 hour duration)
echo "Starting QEC Generator (46-hour duration)..."
nohup bash "$MINING_DIR/qec_generator.sh" 46 > "$DATA_DIR/qec_generator.log" 2>&1 &
QEC_PID=$!
sleep 2
if ps -p $QEC_PID > /dev/null 2>&1; then
  echo "✅ QEC Generator started (PID: $QEC_PID)"
else
  echo "❌ QEC Generator failed to start"
  exit 1
fi

# Start Void Flux Stratum Bridge (consumes QEC, submits shares)
echo "Starting Void Flux Stratum Bridge..."
nohup bash "$MINING_DIR/void_flux_bridge_local.sh" > "$DATA_DIR/stratum_bridge.log" 2>&1 &
BRIDGE_PID=$!
sleep 2
if ps -p $BRIDGE_PID > /dev/null 2>&1; then
  echo "✅ Void Flux Bridge started (PID: $BRIDGE_PID)"
else
  echo "❌ Void Flux Bridge failed to start"
  exit 1
fi

# Start Mining Monitor (real-time revenue tracking)
echo "Starting Mining Monitor..."
nohup bash "$MINING_DIR/mining_monitor.sh" > "$DATA_DIR/mining_monitor.log" 2>&1 &
MONITOR_PID=$!
sleep 2
if ps -p $MONITOR_PID > /dev/null 2>&1; then
  echo "✅ Mining Monitor started (PID: $MONITOR_PID)"
else
  echo "⚠️  Mining Monitor failed to start (non-critical)"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           ✅ MINING SYSTEM RESTORED                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Status:"
echo "  Stratum Server:    PID $SERVER_PID  ✅"
echo "  QEC Generator:     PID $QEC_PID  ✅"
echo "  Void Flux Bridge:  PID $BRIDGE_PID  ✅"
echo "  Mining Monitor:    PID $MONITOR_PID"
echo ""
echo "Monitoring:"
echo "  tail -f $DATA_DIR/mining_monitor.log"
echo ""
echo "Current submission count:"
wc -l "$SUBMIT_LOG" 2>/dev/null || echo "  (Log will be created on first submission)"
echo ""
echo "Logs:"
echo "  QEC:              $DATA_DIR/qec_generator.log"
echo "  Bridge:           $DATA_DIR/stratum_bridge.log"
echo "  Server:           $DATA_DIR/stratum_server.log"
echo "  Monitor:          $DATA_DIR/mining_monitor.log"
echo "  Submissions:      $SUBMIT_LOG"
echo ""
