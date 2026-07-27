#!/bin/bash
# Scenario C mechanism gate. Run AFTER warmup, BEFORE trusting a ladder.
#
# Checks three things the arms depend on, each of which has already failed
# silently at least once in this campaign:
#   1. EPP loaded the intended arm (a ConfigMap-only helm upgrade does not
#      restart the EPP, so the arm can silently not change).
#   2. Prefix affinity is actually converging - a low hit rate means
#      placement is scattering and the arm is measuring recompute, not
#      placement (this is what a missing no-hit-lru-scorer looked like).
#   3. For pull arms, the P2P tier is moving bytes prefill<->prefill.
# Also reports fingerprint rejects, which is how cross-TP P2P fails.
ARM="${1:-unknown}"
EXPECT_P2P="${2:-no}"   # yes|no

EPP=$(kubectl get pods -n nilig-p2p -o name | grep llm-d-router-epp | head -1 | cut -d/ -f2)
P2PCOUNT=$(kubectl logs -n nilig-p2p "$EPP" -c epp 2>/dev/null | grep -c 'p2p-source-producer')
LRU=$(kubectl logs -n nilig-p2p "$EPP" -c epp 2>/dev/null | grep -c 'no-hit-lru-scorer')
echo "arm=$ARM  epp=$EPP"
echo "  loaded config: p2p-source-producer=$P2PCOUNT (expect $( [ "$EXPECT_P2P" = yes ] && echo '>0' || echo '0' ))  no-hit-lru-scorer=$LRU"

tot_q=0; tot_h=0; tot_eq=0; tot_eh=0; tot_load=0
for p in $(kubectl get pods -n nilig-p2p -l app=scenc,role=prefill -o jsonpath='{.items[*].metadata.name}'); do
  m=$(kubectl exec -n nilig-p2p "$p" -c modelserver -- curl -s -m 5 localhost:8000/metrics 2>/dev/null)
  q=$(echo "$m"  | awk '/^vllm:prefix_cache_queries_total/{printf "%.0f",$2}')
  h=$(echo "$m"  | awk '/^vllm:prefix_cache_hits_total/{printf "%.0f",$2}')
  eq=$(echo "$m" | awk '/^vllm:external_prefix_cache_queries_total/{printf "%.0f",$2}')
  eh=$(echo "$m" | awk '/^vllm:external_prefix_cache_hits_total/{printf "%.0f",$2}')
  l=$(echo "$m"  | awk '/^vllm:kv_offload_load_bytes_total/{printf "%.0f",$2}')
  tot_q=$((tot_q+${q:-0})); tot_h=$((tot_h+${h:-0}))
  tot_eq=$((tot_eq+${eq:-0})); tot_eh=$((tot_eh+${eh:-0})); tot_load=$((tot_load+${l:-0}))
done
python3 - "$tot_q" "$tot_h" "$tot_eq" "$tot_eh" "$tot_load" <<'PY'
import sys
q,h,eq,eh,l = (int(x) for x in sys.argv[1:6])
print(f"  GPU prefix cache:      {h:,}/{q:,} = {100*h/q if q else 0:.1f}% hit")
print(f"  External (CPU tier):   {eh:,}/{eq:,} = {100*eh/eq if eq else 0:.1f}% hit")
print(f"  P2P bytes pulled:      {l/1e9:.2f} GB across prefill fleet")
PY
echo "  fingerprint rejects: $(kubectl logs -n nilig-p2p -l app=scenc,role=prefill -c modelserver --since=30m 2>/dev/null | grep -icE 'fingerprint mismatch|rejecting peer connect')"
echo "  restarts: $(kubectl get pods -n nilig-p2p -l app=scenc --no-headers | awk '{s+=$4} END{print s+0}')"
