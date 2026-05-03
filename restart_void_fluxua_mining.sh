#!/bin/bash
# Quick restart for void fluxua mining if processes crash
# Run this to bring the system back online in < 30 seconds

echo "Checking void fluxua mining processes..."

# Kill any existing processes
pkill -f "qec_generator.sh" || true
pkill -f "void_flux_bridge_local" || true
sleep 2

# Restart QEC Generator (required for mining work generation)
echo "Starting QEC Generator (46-hour duration)..."
nohup /tmp/qec_generator.sh 46 > /tmp/qec_generator.log 2>&1 &
QEC_PID=$!
echo "✅ QEC Generator started (PID: $QEC_PID)"

sleep 2

# Restart Void Flux Stratum Bridge (required for share submission)
echo "Starting Void Flux Stratum Bridge..."
nohup bash /tmp/void_flux_bridge_local.sh > /tmp/stratum_bridge.log 2>&1 &
BRIDGE_PID=$!
echo "✅ Void Flux Bridge restarted (PID: $BRIDGE_PID)"

sleep 2

# Verify all critical processes are running
echo ""
echo "Verifying processes..."
PS_COUNT=0

if ps aux | grep "$QEC_PID" | grep -v grep > /dev/null 2>&1; then
  echo "✅ QEC Generator running (PID: $QEC_PID)"
  ((PS_COUNT++))
else
  echo "❌ QEC Generator failed to start"
fi

if ps aux | grep "$BRIDGE_PID" | grep -v grep > /dev/null 2>&1; then
  echo "✅ Void Flux Bridge running (PID: $BRIDGE_PID)"
  ((PS_COUNT++))
else
  echo "❌ Void Flux Bridge failed to start"
fi

if ps aux | grep "stratum_job_server" | grep -v grep > /dev/null 2>&1; then
  echo "✅ Stratum Job Server running"
  ((PS_COUNT++))
else
  echo "⚠️  Stratum Job Server not running (restart manually if needed)"
fi

echo ""
if [ $PS_COUNT -ge 2 ]; then
  echo "✅ Mining system restored and operational"
  echo ""
  echo "To monitor progress:"
  echo "  tail -f /tmp/mining_monitor_output.log"
  echo ""
  echo "Current submission count:"
  wc -l /tmp/stratum_submissions.jsonl
else
  echo "❌ Some processes failed to start. Check logs:"
  echo "  /tmp/qec_generator.log"
  echo "  /tmp/stratum_bridge.log"
fi
