#!/bin/bash
# Gate 1: deployment verification. Fails closed.
# PASS requires, per the campaign topology (2x DEP8 prefill pods + 2-pod
# DEP16 decode group, DP_SIZE_LOCAL=8 everywhere):
#   - exactly $FLEET_EXPECT model pods Ready
#   - per pod: 8 KV-event listeners (5557-5564) and 8 P2P listeners
#     (7777-7784) on the vllm container
#   - per pod: >= 8 completed NIXL/UCX backend initializations
#   - EPP: live ESTABLISHED subscriptions to all per-rank KV-event
#     endpoints (wait_precise_subscriptions.sh)
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

READY=$(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' --no-headers \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") n++} END {print n+0}')
echo "ready model pods: $READY (want $FLEET_EXPECT)" | tee "$OUT/summary.txt"
[ "$READY" -eq "$FLEET_EXPECT" ] || { echo "FAIL: fleet not fully ready" | tee -a "$OUT/summary.txt"; fail=1; }

for p in $(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' -o name); do
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

# Precise-index subscription evidence: live ESTABLISHED connections from
# the current EPP pod to every per-rank KV-event endpoint, checked from
# each model pod's /proc/net/tcp. Log greps are not evidence here:
# subscription lines log once at endpoint discovery and age out of any
# bounded tail at --v=5, and this build has no subscriber gauge or event
# counter. Event-to-index-to-source-selection proof is armC_probe.sh's job.
if NS="$NS" FLEET_EXPECT="$FLEET_EXPECT" \
   bash "$(dirname "$0")/wait_precise_subscriptions.sh" "$OUT" >> "$OUT/summary.txt" 2>&1; then
  echo "epp precise subscriptions: $((FLEET_EXPECT*8))/$((FLEET_EXPECT*8)) live" | tee -a "$OUT/summary.txt"
else
  echo "FAIL: EPP precise subscriptions incomplete (see precise-subscriptions.txt)" | tee -a "$OUT/summary.txt"; fail=1
fi

# archive the active config and producer liveness evidence
kubectl -n "$NS" get deploy p2p-pd-epp \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="epp")].args}' \
  > "$OUT/epp-active-args.txt" 2>/dev/null || true
kubectl -n "$NS" get cm p2p-weka-epp-plugins -o yaml > "$OUT/epp-configmap.yaml" 2>/dev/null || true
EPP_IP=$(head -1 "$OUT/precise-subscriptions.txt" | awk '{print $NF}')
kubectl -n "$NS" exec "$LOADGEN" -- python3 -c "
import urllib.request
t = urllib.request.urlopen('http://$EPP_IP:9090/metrics', timeout=10).read().decode()
for ln in t.splitlines():
    if 'plugin_duration_seconds_count' in ln and 'producer' in ln:
        print(ln)" > "$OUT/epp-producer-invocations.txt" 2>/dev/null || true

if [ "$fail" -ne 0 ]; then
  echo "GATE 1: FAIL (archive in $OUT)" | tee -a "$OUT/summary.txt"
  exit 1
fi
echo "GATE 1: PASS (archive in $OUT)" | tee -a "$OUT/summary.txt"
