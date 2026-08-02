#!/bin/bash
# Require every rank to be idle before a measured arm starts.
# Usage: wait_fleet_quiescent.sh [timeout_s]
set -euo pipefail
NS=${NS:-nilig-p2p}
TIMEOUT=${1:-180}
DEADLINE=$((SECONDS + TIMEOUT))
# Expected rank count is derived from the live fleet so the check stays
# fail-closed across topologies: every rank of every serving pod must
# report, and all must be idle.
RANKS_PER_POD=${RANKS_PER_POD:-8}
PODS=$(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' --no-headers 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") n++} END {print n+0}')
RANKS_EXPECT=${RANKS_EXPECT:-$((PODS * RANKS_PER_POD))}
[ "$RANKS_EXPECT" -gt 0 ] || { echo "ABORT: no Ready serving pods to sample"; exit 1; }

sample() {
  local role pod base
  for role in prefill decode; do
    if [ "$role" = "prefill" ]; then base=8000; else base=8200; fi
    for pod in $(kubectl -n "$NS" get pods -l "llm-d.ai/role=$role" -o name); do
      kubectl -n "$NS" exec "${pod#pod/}" -c vllm -- sh -c \
        "for r in 0 1 2 3 4 5 6 7; do curl -s --max-time 5 localhost:\$(( $base + r ))/metrics; done" \
        2>/dev/null | grep -E '^vllm:num_requests_(running|waiting)\{' || true
    done
  done
}

while [ "$SECONDS" -lt "$DEADLINE" ]; do
  METRICS=$(sample)
  read -r RUN_COUNT WAIT_COUNT RUNNING WAITING <<EOF
$(printf '%s\n' "$METRICS" | python3 -c '
import sys
running=[]
waiting=[]
for line in sys.stdin:
    try: value=float(line.rsplit(" ", 1)[1])
    except (IndexError, ValueError): continue
    if line.startswith("vllm:num_requests_running{"): running.append(value)
    elif line.startswith("vllm:num_requests_waiting{"): waiting.append(value)
print(len(running), len(waiting), sum(running), sum(waiting))')
EOF
  echo "rank metrics: running=$RUN_COUNT/$RANKS_EXPECT waiting=$WAIT_COUNT/$RANKS_EXPECT active=$RUNNING queued=$WAITING"
  if [ "$RUN_COUNT" -eq "$RANKS_EXPECT" ] && [ "$WAIT_COUNT" -eq "$RANKS_EXPECT" ] && \
     python3 -c "raise SystemExit(0 if float('$RUNNING') == 0 and float('$WAITING') == 0 else 1)"; then
    echo "fleet quiescent"
    exit 0
  fi
  sleep 5
done

echo "ABORT: fleet did not become quiescent within ${TIMEOUT}s"
exit 1
