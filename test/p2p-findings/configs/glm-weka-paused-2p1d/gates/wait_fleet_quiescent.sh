#!/bin/bash
# Require every rank to be idle before a measured arm starts.
# Usage: wait_fleet_quiescent.sh [timeout_s]
set -euo pipefail
NS=${NS:-nilig-p2p}
TIMEOUT=${1:-180}
DEADLINE=$((SECONDS + TIMEOUT))

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
  echo "rank metrics: running=$RUN_COUNT/32 waiting=$WAIT_COUNT/32 active=$RUNNING queued=$WAITING"
  if [ "$RUN_COUNT" -eq 32 ] && [ "$WAIT_COUNT" -eq 32 ] && \
     python3 -c "raise SystemExit(0 if float('$RUNNING') == 0 and float('$WAITING') == 0 else 1)"; then
    echo "fleet quiescent"
    exit 0
  fi
  sleep 5
done

echo "ABORT: fleet did not become quiescent within ${TIMEOUT}s"
exit 1
