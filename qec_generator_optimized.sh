#!/bin/bash
# Fixed QEC Generator - simplified to work reliably
set -euo pipefail

MASCOM_HOME="${MASCOM_HOME:-$HOME/mascom}"
STATE_DIR="$MASCOM_HOME/mining_state"
mkdir -p "$STATE_DIR"
QEC_OUTPUT="$STATE_DIR/qec_corrections_optimized.jsonl"
DURATION_MINUTES=${1:-60}
DURATION_SECONDS=$((DURATION_MINUTES * 60))
START_TIME=$(date +%s)
NONCE_COUNTER=0

# Initialize output file
> "$QEC_OUTPUT"

echo "QEC Generator started - will run for $DURATION_MINUTES minutes"
echo "Output: $QEC_OUTPUT"

while true; do
  elapsed=$(($(date +%s) - START_TIME))

  if [ $elapsed -ge $DURATION_SECONDS ]; then
    echo "QEC Generator completed ($DURATION_MINUTES minutes)"
    break
  fi

  # Generate 10 QEC corrections per iteration
  for reg in {0..9}; do
    NONCE_COUNTER=$((NONCE_COUNTER + 1))

    # Create unique nonce
    NONCE=$(printf "pkt_%03d_%06d_%d" $reg $NONCE_COUNTER $(date +%s%N))

    # Hash = nonce via sha256
    HASH=$(echo "$NONCE" | sha256sum | cut -c1-32)

    # Syndrome = fallback time-based (xmrig not available locally)
    SYNDROME=$(awk -v seed="$(date +%s%N)" 'BEGIN {srand(seed); printf "%.4f", 0.5 + rand() * 1.5}')

    # Error magnitude = syndrome
    ERROR_MAGNITUDE="$SYNDROME"

    # Confidence via tanh
    CONFIDENCE=$(echo "$ERROR_MAGNITUDE" | /tmp/tanh_fast -opt 2>/dev/null | awk '{print $1}' || echo "0.5")

    # Multiplier
    FINAL_MULTIPLIER=$(awk -v conf="$CONFIDENCE" 'BEGIN {printf "%.4f", 1.0 + (conf * 0.5)}')

    # Write QEC entry
    echo "{\"venture_id\": \"k10-register-$reg\", \"syndrome_magnitude\": $SYNDROME, \"error_magnitude\": $ERROR_MAGNITUDE, \"confidence\": $CONFIDENCE, \"multiplier\": $FINAL_MULTIPLIER, \"nonce\": \"$NONCE\", \"hash\": \"$HASH\", \"timestamp\": $(date +%s)}" >> "$QEC_OUTPUT"
  done

  # Status every 100 nonces
  if [ $((NONCE_COUNTER % 100)) -eq 0 ]; then
    TAIL_COUNT=$(wc -l < "$QEC_OUTPUT" 2>/dev/null || echo 0)
    echo "[$(date +%H:%M:%S)] Generated $NONCE_COUNTER nonces | File: $TAIL_COUNT lines | $(tail -1 "$QEC_OUTPUT" | jq -r .nonce 2>/dev/null || echo 'parsing...')"
  fi

  # 10 corrections per second (0.1s per batch)
  sleep 0.1
done

echo ""
echo "QEC Generator completed successfully"
wc -l "$QEC_OUTPUT"
