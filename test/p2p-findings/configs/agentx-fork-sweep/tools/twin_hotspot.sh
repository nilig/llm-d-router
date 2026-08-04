#!/usr/bin/env bash
# Matched-twin hot-spot experiment: bursty W=10 fork, ~70K shared prefix.
# baseline (spill-off, no pull) on a2a25745-g1; p2p (spill-on) on c97f752d-g2.
# Both windows cold on prefill (pods restarted 06:24 wiped older prefixes).
# Same spill-capable router in both arms; the pull is the only variable.
set -uo pipefail
cd "$(dirname "$0")"
NS=nilig-agentx-slo; EPP=agentx-slo-epp; POD=workload-access
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
./keep_warm.sh >/tmp/twin-keepwarm.log 2>&1 & KW=$!; trap 'kill $KW 2>/dev/null' EXIT

prefill_hits(){ kubectl -n $NS exec glm-5-2-prefill-0 -c vllm -- python3 -c "
import urllib.request
h=0
for p in range(8000,8008):
    try: t=urllib.request.urlopen(f'http://127.0.0.1:{p}/metrics',timeout=5).read().decode()
    except Exception: continue
    for l in t.splitlines():
        if l.startswith('vllm:external_prefix_cache_hits_total'): h+=float(l.split()[-1])
print(int(h))" 2>/dev/null | tail -1; }

run(){
  local tag=$1 cfg=$2 win=$3
  log "=== $tag ($cfg on $win)"
  kubectl -n $NS rollout restart deploy/$EPP >/dev/null 2>&1
  kubectl -n $NS rollout status deploy/$EPP --timeout=5m >/dev/null 2>&1
  local h0=$(prefill_hits); log "$tag: prefill ext hits before = $h0"
  rm -rf "windows-cut/$win/artifacts/$tag"
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "windows-cut/$win" "$tag" 2>&1 \
    | grep -E "records stable|JOB FAILED|done:" | sed "s/^/[$tag] /"
  local h1=$(prefill_hits)
  local n=0; [ -f "windows-cut/$win/epp-${tag}.jsonl" ] && n=$(grep -c "set KV cache source header" "windows-cut/$win/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls(stream)=$n | prefill ext hits delta = $((h1-h0)) tokens"
}

run baseline /config/spill-off.yaml a2a25745b7f9a0-g1
run p2p      /config/spill-on.yaml  c97f752dfb70c0-g2
log "twin run complete"
