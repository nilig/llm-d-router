#!/bin/bash
# Per-arm counter snapshot: EPP source decisions, engine offload counters,
# session evidence, restart counts. Append-only archive; diffs of
# before/after snapshots are the per-arm mechanism record.
set -u
NS=${NS:-nilig-p2p}
OUT=${1:?usage: snap_counters.sh <outfile>}
{
echo "=== $(date -u +%FT%TZ) ==="
echo "--- pod restarts ---"
kubectl -n $NS get pods -l llm-d.ai/model -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers
echo "--- engine offload counters (per pod) ---"
for p in $(kubectl -n $NS get pods -l llm-d.ai/model -o name); do
  pod=${p#pod/}
  echo "## $pod"
  kubectl -n $NS exec "$pod" -c vllm -- bash -c \
    'for port in 8200 8000; do curl -s --max-time 5 localhost:$port/metrics 2>/dev/null | grep -E "kv_offload_load_bytes_total|kv_offload_total_bytes_total|external_prefix_cache_hits|prefix_cache_hits" | head -8 && break; done' 2>/dev/null
  echo "## $pod sessions"
  kubectl -n $NS logs "$pod" -c vllm --tail=100000 2>/dev/null | grep -c "created connected session" || true
done
echo "--- EPP p2p decisions (streamed log counters) ---"
EPP=$(kubectl -n $NS get pods -l app=p2p-pd-epp -o name | head -1)
kubectl -n $NS logs ${EPP#pod/} -c epp --tail=200000 2>/dev/null | \
  grep -cE "p2p|kv.cache.source" || true
} >> "$OUT"
echo "snapshot appended to $OUT"
