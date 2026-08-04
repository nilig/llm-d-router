#!/usr/bin/env bash
# Bursty fork x TWO-POD prefill: the untested combination.
# W=44 baseline (21cde366-g5, 40,640 tok) vs W=43 p2p (631738-g0, 40,320 tok).
# Cross-pod spills have no intra-pod rescue: baseline recomputes ~6.6s, p2p pulls.
# Both windows cold on both prefill pods (pod-0 wiped 06:24, pod-1 brand new).
set -uo pipefail
cd "$(dirname "$0")"
NS=nilig-agentx-slo; EPP=agentx-slo-epp; POD=workload-access
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
./keep_warm.sh >/tmp/twinwide-keepwarm.log 2>&1 & KW=$!; trap 'kill $KW 2>/dev/null' EXIT

log "waiting for 2 prefill + 2 decode pods Ready"
for i in $(seq 1 240); do
  np=$(timeout 30 kubectl -n $NS get lws glm-5-2-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  nd=$(timeout 30 kubectl -n $NS get lws glm-5-2-decode  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${np:-0}" -ge 2 ] && [ "${nd:-0}" -ge 2 ] && { log "fleet Ready (2P+2D)"; break; }
  sleep 20
done
np=$(kubectl -n $NS get lws glm-5-2-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
nd=$(kubectl -n $NS get lws glm-5-2-decode  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
{ [ "${np:-0}" -ge 2 ] && [ "${nd:-0}" -ge 2 ]; } || { log "FAILED: fleet incomplete (P=$np D=$nd)"; exit 1; }

prefill_hits(){ for pod in glm-5-2-prefill-0 glm-5-2-prefill-1; do kubectl -n $NS exec $pod -c vllm -- python3 -c "
import urllib.request
h=0
for p in range(8000,8008):
    try: t=urllib.request.urlopen(f'http://127.0.0.1:{p}/metrics',timeout=5).read().decode()
    except Exception: continue
    for l in t.splitlines():
        if l.startswith('vllm:external_prefix_cache_hits_total'): h+=float(l.split()[-1])
print(int(h))" 2>/dev/null | tail -1; done | paste -sd+ - | bc; }

run(){
  local tag=$1 cfg=$2 win=$3
  log "=== $tag ($cfg on $win)"
  kubectl -n $NS rollout restart deploy/$EPP >/dev/null 2>&1
  kubectl -n $NS rollout status deploy/$EPP --timeout=5m >/dev/null 2>&1
  sleep 45   # let KV-event subscriptions establish across all 3 engine pods
  local h0=$(prefill_hits); log "$tag: prefill ext hits before = $h0"
  rm -rf "windows/$win/artifacts/$tag"
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "windows/$win" "$tag" 2>&1 \
    | grep -E "records stable|JOB FAILED|done:" | sed "s/^/[$tag] /"
  local h1=$(prefill_hits)
  local np=0; [ -f "windows/$win/epp-${tag}.jsonl" ] && np=$(grep -c "set KV cache source header" "windows/$win/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls(stream)=$np | prefill ext hits delta = $((h1-h0)) tokens"
  local ages=$(kubectl -n $NS get pods -o json 2>/dev/null | python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
young=[p['metadata']['name'] for p in json.load(sys.stdin)['items']
       if p['metadata']['name'].startswith('glm-5-2-') and 'render' not in p['metadata']['name']
       and (now-datetime.datetime.fromisoformat(p['metadata']['creationTimestamp'].replace('Z','+00:00'))).total_seconds()<600]
print(','.join(young) if young else '-')")
  log "$tag: engine pods younger than 10min: $ages (must be '-' for a valid arm)"
}

run baseline /config/spill-off.yaml 21cde366f5bd2f-g5
run p2p      /config/spill-on.yaml  631738ac313214-g0
log "twin-wide complete"
