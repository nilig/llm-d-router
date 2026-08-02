#!/bin/bash
# Engagement-only probe for the Weka long-pause workload.
# Usage: run_probe.sh <concurrency> [idle-gap-cap-seconds] [seed]
set -euo pipefail

CONC=${1:?usage: run_probe.sh <concurrency> [idle-gap-cap-seconds] [seed]}
GAP=${2:-60}
SEED=${3:-42}
SP="$(cd "$(dirname "$0")/.." && pwd)"
TAG="rp-c${CONC}-g${GAP}-s${SEED}-approx-p2p"

case "$CONC" in
  *[!0-9]*|'') echo "ABORT: concurrency must be a positive integer"; exit 1 ;;
esac
case "$GAP" in
  *[!0-9]*|'') echo "ABORT: idle-gap cap must be a positive integer"; exit 1 ;;
esac
UNSAFE_ARGS="--unsafe-override --trace-idle-gap-cap-seconds $GAP"

SEED="$SEED" \
AIPERF_UNSAFE_ARGS="$UNSAFE_ARGS" \
  "$SP/run_arm.sh" blog-approximate-p2p "$CONC" "$TAG"

python3 "$SP/resume-pressure/summarize_engagement.py" \
  "$SP/epp-$TAG.jsonl" | tee "$SP/resume-pressure/$TAG-engagement.txt"
