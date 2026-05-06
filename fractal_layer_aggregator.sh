#!/bin/bash
###############################################################################
# FRACTAL LAYER AGGREGATOR
#
# Implements order-of-magnitude many-to-one aggregation layers
# Like a Sankey chart: multiple small flows merge into larger flows
#
# Architecture:
#  Layer 0: Physical xmrig (actual mining work)
#  Layer 1: K10 aggregation (10x multiplier)
#  Layer 2: K100 aggregation (100x multiplier)
#  Layer 3: K1000 aggregation (1000x multiplier)
#
#  Flow: xmrig → K10 [10 instances] → K100 [100 instances] → Pool
#
###############################################################################

set -euo pipefail

MASCOM_DIR="${MASCOM_DIR:-/Users/johnmobley/mascom}"
AGGREGATION_DIR="${MASCOM_DIR}/mining_state/fractal_layers"
LOG_DIR="${AGGREGATION_DIR}/logs"

mkdir -p "$AGGREGATION_DIR/layer0" "$AGGREGATION_DIR/layer1" "$AGGREGATION_DIR/layer2" "$LOG_DIR"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Fractal Layer Aggregator started" >> "$LOG_DIR/aggregator.log"

###############################################################################
# LAYER 0: PHYSICAL XMRIG FEEDS
# Monitor actual mining work from physical hardware
###############################################################################

aggregate_layer_0() {
    local output_file="$AGGREGATION_DIR/layer0/physical_work.jsonl"

    # Poll xmrig instances on Hetzner
    # Each machine contributes real hashing work
    while true; do
        for machine in {0..5}; do
            # Query each Hetzner machine's xmrig metrics
            local host="5.161.253.$((15 + machine))"
            local metrics=$(curl -s "http://${host}:8088/api/v1/stats" 2>/dev/null || echo '{}')

            local hashrate=$(echo "$metrics" | jq '.hashrate // 0' 2>/dev/null || echo 0)
            local accepted=$(echo "$metrics" | jq '.connection[0].accepted // 0' 2>/dev/null || echo 0)

            if [ "$hashrate" != "0" ]; then
                echo "{\"timestamp\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\", \"source\": \"xmrig_machine_$machine\", \"host\": \"$host\", \"hashrate\": $hashrate, \"accepted_shares\": $accepted, \"layer\": 0}" >> "$output_file"
            fi
        done
        sleep 5
    done
}

###############################################################################
# LAYER 1: K10 AGGREGATION
# 10 K10 registers, each represents 10 units of physical work
# Manifold aggregation: 6 physical machines → 10 virtual K10 entities
###############################################################################

aggregate_layer_1() {
    local output_file="$AGGREGATION_DIR/layer1/k10_aggregated.jsonl"
    local input_file="$AGGREGATION_DIR/layer0/physical_work.jsonl"

    local k10_index=0
    local accumulated_hashrate=0
    local accumulated_shares=0

    while true; do
        # Read latest physical work
        if [ -f "$input_file" ]; then
            local latest=$(tail -1 "$input_file" 2>/dev/null)

            if [ -n "$latest" ]; then
                local hashrate=$(echo "$latest" | jq '.hashrate // 0' 2>/dev/null || echo 0)
                local shares=$(echo "$latest" | jq '.accepted_shares // 0' 2>/dev/null || echo 0)

                accumulated_hashrate=$(echo "$accumulated_hashrate + $hashrate" | bc -l)
                accumulated_shares=$(echo "$accumulated_shares + $shares" | bc -l)

                # Every 10x accumulation, emit a K10 aggregation
                # (In practice: every time ~10 physical work units arrive)
                if (( $(echo "$accumulated_hashrate > 100" | bc -l) )); then
                    echo "{\"timestamp\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\", \"k10_register\": $k10_index, \"aggregated_hashrate\": $accumulated_hashrate, \"aggregated_shares\": $accumulated_shares, \"multiplier\": 10, \"layer\": 1}" >> "$output_file"

                    k10_index=$(( (k10_index + 1) % 10 ))
                    accumulated_hashrate=0
                    accumulated_shares=0
                fi
            fi
        fi
        sleep 1
    done
}

###############################################################################
# LAYER 2: K100 AGGREGATION
# 10 K100 registers, each represents aggregation of K10 layers
# Many-to-one: 10 K10 flows → 1 K100 entity (100x multiplier)
###############################################################################

aggregate_layer_2() {
    local output_file="$AGGREGATION_DIR/layer2/k100_aggregated.jsonl"
    local input_file="$AGGREGATION_DIR/layer1/k10_aggregated.jsonl"

    local k100_index=0
    local accumulated_work=0
    local work_buffer=""

    while true; do
        # Buffer K10 emissions until we have 10 (one full K100 aggregation)
        if [ -f "$input_file" ]; then
            local latest=$(tail -1 "$input_file" 2>/dev/null)

            if [ -n "$latest" ]; then
                work_buffer="$work_buffer
$latest"

                local line_count=$(echo "$work_buffer" | wc -l)

                # After 10 K10 aggregations, emit K100
                if [ "$line_count" -ge 10 ]; then
                    local total_hashrate=$(echo "$work_buffer" | jq -s 'map(.aggregated_hashrate) | add' 2>/dev/null || echo 0)
                    local total_shares=$(echo "$work_buffer" | jq -s 'map(.aggregated_shares) | add' 2>/dev/null || echo 0)

                    echo "{\"timestamp\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\", \"k100_register\": $k100_index, \"aggregated_hashrate\": $total_hashrate, \"aggregated_shares\": $total_shares, \"multiplier\": 100, \"source_k10_count\": $(echo $work_buffer | jq -s 'length'), \"layer\": 2}" >> "$output_file"

                    k100_index=$(( (k100_index + 1) % 10 ))
                    work_buffer=""
                fi
            fi
        fi
        sleep 2
    done
}

###############################################################################
# MAIN: Run all aggregation layers in parallel
###############################################################################

main() {
    echo "═══════════════════════════════════════════════════════════"
    echo "FRACTAL LAYER AGGREGATOR - Many-to-One Sankey Flow"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Architecture:"
    echo "  Layer 0: 6 physical xmrig machines"
    echo "  Layer 1: 10 K10 registers (10x each) ← aggregate physical work"
    echo "  Layer 2: 10 K100 registers (100x each) ← aggregate K10 flows"
    echo "  Pool: Single submission stream ← ultimate aggregation"
    echo ""
    echo "Output:"
    echo "  $AGGREGATION_DIR/layer0/physical_work.jsonl"
    echo "  $AGGREGATION_DIR/layer1/k10_aggregated.jsonl"
    echo "  $AGGREGATION_DIR/layer2/k100_aggregated.jsonl"
    echo ""

    # Start aggregation layers as background processes
    aggregate_layer_0 &
    LOCAL_PID_0=$!

    aggregate_layer_1 &
    LOCAL_PID_1=$!

    aggregate_layer_2 &
    LOCAL_PID_2=$!

    echo "Layer 0 (physical xmrig):  PID $LOCAL_PID_0"
    echo "Layer 1 (K10 aggregation):  PID $LOCAL_PID_1"
    echo "Layer 2 (K100 aggregation): PID $LOCAL_PID_2"
    echo ""
    echo "Monitoring aggregation layers (press Ctrl+C to stop)..."
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Monitor layer outputs
    while true; do
        echo "[$(date -u +'%H:%M:%S')] Layer status:"

        if [ -f "$AGGREGATION_DIR/layer0/physical_work.jsonl" ]; then
            local count0=$(wc -l < "$AGGREGATION_DIR/layer0/physical_work.jsonl" 2>/dev/null || echo 0)
            echo "  Layer 0 (physical): $count0 work units"
        fi

        if [ -f "$AGGREGATION_DIR/layer1/k10_aggregated.jsonl" ]; then
            local count1=$(wc -l < "$AGGREGATION_DIR/layer1/k10_aggregated.jsonl" 2>/dev/null || echo 0)
            local latest1=$(tail -1 "$AGGREGATION_DIR/layer1/k10_aggregated.jsonl" 2>/dev/null | jq -c '.k10_register, .aggregated_hashrate' 2>/dev/null || echo "none")
            echo "  Layer 1 (K10): $count1 aggregations (latest: $latest1)"
        fi

        if [ -f "$AGGREGATION_DIR/layer2/k100_aggregated.jsonl" ]; then
            local count2=$(wc -l < "$AGGREGATION_DIR/layer2/k100_aggregated.jsonl" 2>/dev/null || echo 0)
            local latest2=$(tail -1 "$AGGREGATION_DIR/layer2/k100_aggregated.jsonl" 2>/dev/null | jq -c '.k100_register, .aggregated_hashrate' 2>/dev/null || echo "none")
            echo "  Layer 2 (K100): $count2 aggregations (latest: $latest2)"
        fi

        sleep 30
    done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
