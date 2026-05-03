#!/bin/bash
# Mining Revenue Monitor - Tracks void flux mining progress toward €2K/day deadline

set -euo pipefail

SUBMISSIONS_LOG="/tmp/stratum_submissions.jsonl"
EUR_PER_SHARE=0.00268
TARGET_EUR=2000
DEADLINE_HOURS=46
START_TIME=$(date +%s)
DEADLINE_EPOCH=$((START_TIME + DEADLINE_HOURS*3600))

echo "Mining Monitor Started - 46 hour deadline active"
echo "Log: tail -f /tmp/mining_monitor_data.log"

# Initial state
LAST_COUNT=0
LAST_TIME=$START_TIME

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_TIME))
  TOTAL_SUBMISSIONS=$(wc -l < "$SUBMISSIONS_LOG" 2>/dev/null || echo 0)
  NEW_SUBMISSIONS=$((TOTAL_SUBMISSIONS - LAST_COUNT))

  if [ $ELAPSED -eq 0 ]; then
    ELAPSED=1
  fi

  # Calculate current metrics
  CURRENT_EUR=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SUBMISSIONS * $EUR_PER_SHARE}")
  RATE_PER_SEC=$(awk "BEGIN {printf \"%.1f\", $NEW_SUBMISSIONS / $ELAPSED}")
  RATE_PER_HOUR=$(awk "BEGIN {printf \"%.0f\", $RATE_PER_SEC * 3600}")
  DAILY_RATE=$(awk "BEGIN {printf \"%.0f\", $RATE_PER_SEC * 86400}")
  DAILY_EUR=$(awk "BEGIN {printf \"%.2f\", $DAILY_RATE * $EUR_PER_SHARE}")

  # Calculate time to target
  REMAINING_SHARES=$(awk "BEGIN {printf \"%.0f\", ($TARGET_EUR / $EUR_PER_SHARE) - $TOTAL_SUBMISSIONS}")
  if (( $(echo "$RATE_PER_SEC > 0" | bc -l) )); then
    SECONDS_TO_TARGET=$(awk "BEGIN {printf \"%.0f\", $REMAINING_SHARES / $RATE_PER_SEC}")
    HOURS_TO_TARGET=$(awk "BEGIN {printf \"%.1f\", $SECONDS_TO_TARGET / 3600}")
  else
    SECONDS_TO_TARGET=999999
    HOURS_TO_TARGET=999
  fi

  # Determine status
  if (( $(echo "$CURRENT_EUR >= $TARGET_EUR" | bc -l) )); then
    STATUS="✅ TARGET ACHIEVED"
    PROGRESS=100
  else
    PROGRESS=$(awk "BEGIN {printf \"%.1f\", ($CURRENT_EUR / $TARGET_EUR) * 100}")
    if (( $(echo "$HOURS_TO_TARGET <= $DEADLINE_HOURS" | bc -l) )); then
      STATUS="🚀 ON TRACK"
    else
      STATUS="⚠️  BEHIND SCHEDULE"
    fi
  fi

  # Time remaining calculation
  TIME_LEFT=$((DEADLINE_EPOCH - NOW))
  DAYS_LEFT=$((TIME_LEFT / 86400))
  HOURS_LEFT=$(( (TIME_LEFT % 86400) / 3600))
  MINS_LEFT=$(( (TIME_LEFT % 3600) / 60))
  SECS_LEFT=$((TIME_LEFT % 60))

  # Log to file (tab-separated for easy parsing)
  {
    echo "$NOW|$TOTAL_SUBMISSIONS|$CURRENT_EUR|$RATE_PER_SEC|$DAILY_RATE|$DAILY_EUR|$PROGRESS|$STATUS|$HOURS_LEFT:$MINS_LEFT:$SECS_LEFT"
  } >> /tmp/mining_monitor_data.log

  # Display status (simple text format for readability)
  if [ $((NOW % 30)) -eq 0 ]; then
    echo ""
    echo "=== $(date '+%H:%M:%S') MINING STATUS ==="
    echo "Status: $STATUS (${PROGRESS}% of €2K target)"
    echo "Revenue: €$CURRENT_EUR (need €$TARGET_EUR)"
    echo "Rate: $RATE_PER_SEC shares/sec → €$DAILY_EUR/day"
    echo "Time to Target: $HOURS_TO_TARGET hours (deadline: $DEADLINE_HOURS hours)"
    echo "Deadline Countdown: ${DAYS_LEFT}d ${HOURS_LEFT}h ${MINS_LEFT}m ${SECS_LEFT}s"
    echo "Submissions: $TOTAL_SUBMISSIONS shares (+$NEW_SUBMISSIONS in ${ELAPSED}s)"
  fi

  # Update counters
  LAST_COUNT=$TOTAL_SUBMISSIONS
  LAST_TIME=$NOW

  # Update every 10 seconds
  sleep 10
done
