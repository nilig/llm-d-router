#!/usr/bin/env bash
# Reverse-assignment replicate of the wide twins: cold prefill via pod restart,
# then baseline on 631738-g0 (W=43) and p2p on 21cde366-g5 (W=44) -- the swap
# controls for window identity and doubles n.
set -uo pipefail
cd "$(dirname "$0")"
NS=nilig-agentx-slo; EPP=agentx-slo-epp; POD=workload-access
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
./keep_warm.sh >/tmp/twinrev-keepwarm.log 2>&1 & KW=$!; trap 'kill $KW 2>/dev/null' EXIT

log "restarting both prefill pods for cold state"
kubectl -n $NS delete pod glm-5-2-prefill-0 glm-5-2-prefill-1 --wait=false >/dev/null 2>&1
sleep 30
log "waiting for 2 prefill + 2 decode Ready (~15 min)"
for i in $(seq 1 240); do
  np=$(timeout 30 kubectl -n $NS get lws glm-5-2-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  nd=$(timeout 30 kubectl -n $NS get lws glm-5-2-decode  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${np:-0}" -ge 2 ] && [ "${nd:-0}" -ge 2 ] && { log "fleet Ready (2P+2D)"; break; }
  sleep 20
done
np=$(kubectl -n $NS get lws glm-5-2-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
nd=$(kubectl -n $NS get lws glm-5-2-decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
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
  sleep 45
  local h0=$(prefill_hits); log "$tag: prefill ext hits before = $h0"
  rm -rf "windows/$win/artifacts/$tag"
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "windows/$win" "$tag" 2>&1 \
    | grep -E "records stable|JOB FAILED|done:" | sed "s/^/[$tag] /"
  local h1=$(prefill_hits)
  local npull=0; [ -f "windows/$win/epp-${tag}.jsonl" ] && npull=$(grep -c "set KV cache source header" "windows/$win/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls(stream)=$npull | prefill ext hits delta = $((h1-h0)) tokens"
  local ages=$(kubectl -n $NS get pods -o json 2>/dev/null | python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
young=[p['metadata']['name'] for p in json.load(sys.stdin)['items']
       if p['metadata']['name'].startswith('glm-5-2-decode')
       and (now-datetime.datetime.fromisoformat(p['metadata']['creationTimestamp'].replace('Z','+00:00'))).total_seconds()<600]
print(','.join(young) if young else '-')")
  log "$tag: decode pods younger than 10min: $ages (must be '-')"
}

run baseline-rev /config/spill-off.yaml 631738ac313214-g0
run p2p-rev      /config/spill-on.yaml  21cde366f5bd2f-g5
log "twin-wide-rev complete"
