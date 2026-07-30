#!/bin/bash
# Resume arms 2-4 of the 4-arm GLM campaign (arm 1 fix-precise already done).
# Same per-arm snapshot/delta protocol as glm4_campaign.sh; scales the fleet
# to 0 at the end regardless of outcomes.
set -u
NS=nilig-p2p
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
PODS="wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill-0 wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill-0-1 wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode-0 wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode-0-1"

snapshot() {
  : > "$1"
  for p in $PODS; do
    kubectl -n $NS exec $p -c vllm -- sh -c '
      for port in 8000 8001 8002 8003 8004 8005 8006 8007; do
        curl -s --max-time 5 localhost:$port/metrics 2>/dev/null |
          grep -E "^vllm:(kv_offload_total_bytes_total.*CPU_to_GPU|external_prefix_cache_(queries|hits)|prefix_cache_(queries|hits)_total)"
      done' 2>/dev/null | sed "s|^|$p |" >> "$1"
  done
}

sumdelta() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re
def total(path, rx):
    t = 0.0
    for line in open(path):
        parts = line.rsplit(" ", 1)
        if len(parts) == 2 and re.search(rx, line):
            try: t += float(parts[1])
            except ValueError: pass
    return t
b, a, rx = sys.argv[1], sys.argv[2], sys.argv[3]
print(f"{total(a, rx) - total(b, rx):.0f}")
PY
}

run_arm() {
  local ARM="$1" TAG="$2"
  echo "##### CAMPAIGN ARM $TAG ($ARM) START $(date -u +%H:%M:%S) #####"
  local T0
  T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  snapshot "$SP/snap-$TAG-before.txt"
  ./glm_arm.sh "$ARM" "$TAG"
  local RC=$?
  snapshot "$SP/snap-$TAG-after.txt"
  local BYTES EXTQ EXTH ACC
  BYTES=$(sumdelta "$SP/snap-$TAG-before.txt" "$SP/snap-$TAG-after.txt" 'CPU_to_GPU')
  EXTQ=$(sumdelta "$SP/snap-$TAG-before.txt" "$SP/snap-$TAG-after.txt" 'external_prefix_cache_queries')
  EXTH=$(sumdelta "$SP/snap-$TAG-before.txt" "$SP/snap-$TAG-after.txt" 'external_prefix_cache_hits')
  ACC=0
  for p in $PODS; do
    n=$(kubectl -n $NS logs $p -c vllm --since-time="$T0" 2>/dev/null | grep -c "accepting incoming connection")
    ACC=$((ACC + n))
  done
  echo "ARM $TAG DELTAS: cpu_to_gpu_bytes=$BYTES ext_queries=$EXTQ ext_hits=$EXTH p2p_accepts=$ACC rc=$RC"
  echo "##### CAMPAIGN ARM $TAG END rc=$RC #####"
  return $RC
}

FAILED=""
run_arm armC-16k    fix-precisepull || FAILED="$FAILED fix-precisepull"
run_arm armB-approx fix-approx      || FAILED="$FAILED fix-approx"
run_arm armD        fix-approxpull  || FAILED="$FAILED fix-approxpull"

echo "##### CAMPAIGN RUNS DONE failed=[${FAILED:-none}] - scaling fleet to 0 #####"
kubectl -n $NS scale lws wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=0
echo "##### CAMPAIGN COMPLETE $(date -u +%H:%M:%S) #####"
