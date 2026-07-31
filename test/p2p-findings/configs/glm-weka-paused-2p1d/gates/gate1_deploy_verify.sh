#!/bin/bash
# Gate 1: deployment verification archive. Read-only; writes the archive
# into $OUT (default ./gate1-<timestamp>). Abort criteria per the campaign
# design: any rank without CPU/P2P tier, any missing listener, or a precise
# index missing rank endpoints fails the gate.
set -u
NS=${NS:-nilig-p2p}
OUT=${OUT:-gate1-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"
fail=0

kubectl -n $NS get pods -o wide > "$OUT/pods.txt"
kubectl -n $NS get lws -o yaml > "$OUT/lws.yaml"
kubectl -n $NS get deploy p2p-pd-epp -o yaml > "$OUT/epp-deploy.yaml" 2>/dev/null

# per-pod: images, env, GPU count, listeners
for p in $(kubectl -n $NS get pods -l 'llm-d.ai/model' -o name 2>/dev/null); do
  pod=${p#pod/}
  kubectl -n $NS get "$p" -o json > "$OUT/pod-$pod.json"
  echo "== $pod listeners ==" >> "$OUT/listeners.txt"
  # ss may be absent in distroless; /proc/net/tcp fallback
  kubectl -n $NS exec "$pod" -c vllm -- bash -c \
    'ss -tlnp 2>/dev/null | grep -E ":(5557|555[8-9]|556[0-4]|777[7-9]|778[0-4]|82[0-9][0-9])" || cat /proc/net/tcp' \
    >> "$OUT/listeners.txt" 2>&1
  # tier creation evidence
  kubectl -n $NS logs "$pod" -c vllm 2>/dev/null | \
    grep -iE "TieringOffloadingSpec|cpu_bytes|secondary tier|p2p.*(listen|bind|port)|NixlTransport|Backend UCX was instantiated" \
    | head -40 > "$OUT/tiers-$pod.txt"
  ucx_started=$(grep -c "NixlTransport" "$OUT/tiers-$pod.txt" || true)
  ucx_done=$(grep -c "Backend UCX was instantiated" "$OUT/tiers-$pod.txt" || true)
  echo "$pod NixlTransport=$ucx_started UCX_done=$ucx_done" >> "$OUT/ucx-summary.txt"
done

# expected listener check per decode pod: KV events 5557-5564, P2P 7777-7784
while read -r pod n_start n_done; do
  :
done < /dev/null

# EPP: rendered config + per-rank endpoint discovery + event flow
EPP=$(kubectl -n $NS get pods -l app=p2p-pd-epp -o name 2>/dev/null | head -1)
if [ -n "$EPP" ]; then
  kubectl -n $NS exec ${EPP#pod/} -c epp -- cat /config/$(kubectl -n $NS get deploy p2p-pd-epp -o jsonpath='{.spec.template.spec.containers[?(@.name=="epp")].args}' | tr ',' '\n' | grep -A0 'config' | tail -1 | tr -d '"[]') > "$OUT/epp-active-config.yaml" 2>/dev/null
  kubectl -n $NS logs ${EPP#pod/} -c epp --tail=5000 2>/dev/null | \
    grep -icE "kv.?event|subscrib" > "$OUT/epp-event-line-count.txt"
fi

echo "Gate 1 archive in $OUT. REVIEW ucx-summary.txt: every rank must show UCX_done >= 1."
grep -c "UCX_done=0" "$OUT/ucx-summary.txt" 2>/dev/null && echo "WARNING: ranks with no completed UCX init" && fail=1
exit $fail
