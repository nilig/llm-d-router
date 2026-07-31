#!/bin/bash
# Gate 1: deployment verification. Fails closed.
# PASS requires, per the campaign topology (2x DEP8 prefill pods + 2-pod
# DEP16 decode group, DP_SIZE_LOCAL=8 everywhere):
#   - exactly $FLEET_EXPECT model pods Ready
#   - per pod: 8 KV-event listeners (5557-5564) and 8 P2P listeners
#     (7777-7784) on the vllm container
#   - per pod: >= 8 completed NIXL/UCX backend initializations
#   - EPP: nonzero KV-event activity and subscription evidence
set -euo pipefail
NS=${NS:-nilig-p2p}
LOADGEN=${LOADGEN:-scenc-loadgen}
FLEET_EXPECT=${FLEET_EXPECT:-4}
OUT=${OUT:-gate1-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"
fail=0

kubectl -n "$NS" get pods -o wide > "$OUT/pods.txt"
kubectl -n "$NS" get lws -o yaml > "$OUT/lws.yaml"
kubectl -n "$NS" get deploy p2p-pd-epp -o yaml > "$OUT/epp-deploy.yaml"

READY=$(kubectl -n "$NS" get pods -l 'llm-d.ai/model' --no-headers \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") n++} END {print n+0}')
echo "ready model pods: $READY (want $FLEET_EXPECT)" | tee "$OUT/summary.txt"
[ "$READY" -eq "$FLEET_EXPECT" ] || { echo "FAIL: fleet not fully ready" | tee -a "$OUT/summary.txt"; fail=1; }

for p in $(kubectl -n "$NS" get pods -l 'llm-d.ai/model' -o name); do
  pod=${p#pod/}
  kubectl -n "$NS" get "$p" -o json > "$OUT/pod-$pod.json"

  # listener counts from /proc/net/tcp (hex ports), robust to missing ss
  counts=$(kubectl -n "$NS" exec "$pod" -c vllm -- python3 -c '
kv = set(range(5557, 5565)); p2p = set(range(7777, 7785))
seen = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        lines = open(f).read().splitlines()[1:]
    except OSError:
        continue
    for ln in lines:
        parts = ln.split()
        if len(parts) < 4 or parts[3] != "0A":  # LISTEN
            continue
        seen.add(int(parts[1].rsplit(":", 1)[1], 16))
print(len(kv & seen), len(p2p & seen))' 2>/dev/null || echo "0 0")
  kvn=${counts% *}; p2pn=${counts#* }
  echo "$pod kv_listeners=$kvn p2p_listeners=$p2pn" | tee -a "$OUT/summary.txt"
  [ "$kvn" -eq 8 ] || { echo "FAIL: $pod expected 8 KV-event listeners" | tee -a "$OUT/summary.txt"; fail=1; }
  [ "$p2pn" -eq 8 ] || { echo "FAIL: $pod expected 8 P2P listeners" | tee -a "$OUT/summary.txt"; fail=1; }

  kubectl -n "$NS" logs "$pod" -c vllm 2>/dev/null | \
    grep -iE "TieringOffloadingSpec|cpu_bytes|secondary tier|NixlTransport|Backend UCX was instantiated" \
    > "$OUT/tiers-$pod.txt" || true
  ucx_done=$(grep -c "Backend UCX was instantiated" "$OUT/tiers-$pod.txt" || true)
  echo "$pod ucx_completed=$ucx_done" | tee -a "$OUT/summary.txt"
  [ "$ucx_done" -ge 8 ] || { echo "FAIL: $pod has $ucx_done/8 completed UCX inits" | tee -a "$OUT/summary.txt"; fail=1; }
done

EPP=$(kubectl -n "$NS" get pods -l app=p2p-pd-epp -o name | head -1)
[ -n "$EPP" ] || { echo "FAIL: no EPP pod" | tee -a "$OUT/summary.txt"; fail=1; }
if [ -n "$EPP" ]; then
  kubectl -n "$NS" logs "${EPP#pod/}" -c epp --tail=200000 > "$OUT/epp-log-tail.txt" 2>/dev/null || true
  EVENTS=$(grep -icE "kv.?event" "$OUT/epp-log-tail.txt" || true)
  # distinct per-rank subscriber endpoints: 4 pods x 8 ranks on 5557-5564
  RANK_SUBS=$(python3 - "$OUT/epp-log-tail.txt" << 'PY'
import sys, re
eps = set()
for ln in open(sys.argv[1], errors="ignore"):
    for m in re.finditer(r"tcp://(\d+\.\d+\.\d+\.\d+):(55[5-6][0-9])", ln):
        if 5557 <= int(m.group(2)) <= 5564:
            eps.add((m.group(1), m.group(2)))
print(len(eps))
PY
)
  # No live subscribers gauge exists on this EPP build (verified against
  # the codebase and the live /metrics endpoint), and the container is
  # distroless (no exec-based connection inspection). The log-derived
  # distinct-endpoint count is the strongest available evidence and is
  # instance-bounded, not historical: kubectl logs returns only the
  # current container instance, and arm activation always restarts the
  # EPP before this gate runs.
  echo "epp kv-event lines=$EVENTS distinct rank subscribers=$RANK_SUBS (want $((FLEET_EXPECT*8)))" | tee -a "$OUT/summary.txt"
  [ "$EVENTS" -gt 0 ] || { echo "FAIL: EPP shows zero KV-event activity" | tee -a "$OUT/summary.txt"; fail=1; }
  [ "$RANK_SUBS" -ge $((FLEET_EXPECT*8)) ] \
    || { echo "FAIL: EPP subscribes to $RANK_SUBS/$((FLEET_EXPECT*8)) rank endpoints" | tee -a "$OUT/summary.txt"; fail=1; }
fi

if [ "$fail" -ne 0 ]; then
  echo "GATE 1: FAIL (archive in $OUT)" | tee -a "$OUT/summary.txt"
  exit 1
fi
echo "GATE 1: PASS (archive in $OUT)" | tee -a "$OUT/summary.txt"
