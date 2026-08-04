#!/usr/bin/env bash
# Sequenced reverse-twin rerun that respects capacity contention:
# 1. wait for decode-1 to get a node and the full 2P+2D fleet to be Ready
# 2. refuse to restart prefill while any FOREIGN pending GPU pod could steal
#    the freed nodes
# 3. restart prefills (cold), wait, run both reverse arms
set -uo pipefail
cd "$(dirname "$0")"
NS=nilig-agentx-slo; EPP=agentx-slo-epp; POD=workload-access
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }

ready(){ r=$(timeout 30 kubectl -n $NS get lws $1 -o jsonpath='{.status.readyReplicas}' 2>/dev/null); echo ${r:-0}; }

log "phase 1: waiting for full fleet (decode-1 needs a node)"
for i in $(seq 1 720); do
  [ "$(ready glm-5-2-prefill)" -ge 2 ] && [ "$(ready glm-5-2-decode)" -ge 2 ] && break
  sleep 30
done
{ [ "$(ready glm-5-2-prefill)" -ge 2 ] && [ "$(ready glm-5-2-decode)" -ge 2 ]; } || { log "FAILED: fleet never complete"; exit 1; }
log "fleet complete"

log "phase 2: foreign-pending check"
foreign=$(timeout 60 kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
n=0
for p in json.load(sys.stdin)['items']:
    if p['status']['phase']!='Pending' or p['metadata']['namespace']=='$NS': continue
    if sum(int((c.get('resources',{}).get('limits') or {}).get('nvidia.com/gpu',0) or 0) for c in p['spec']['containers'])>0: n+=1
print(n)")
if [ "${foreign:-1}" -gt 0 ]; then
  log "WARNING: $foreign foreign pending GPU pods -- prefill restart would risk losing nodes; waiting for them to clear"
  for i in $(seq 1 120); do
    foreign=$(timeout 60 kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
n=0
for p in json.load(sys.stdin)['items']:
    if p['status']['phase']!='Pending' or p['metadata']['namespace']=='$NS': continue
    if sum(int((c.get('resources',{}).get('limits') or {}).get('nvidia.com/gpu',0) or 0) for c in p['spec']['containers'])>0: n+=1
print(n)")
    [ "${foreign:-1}" -eq 0 ] && break
    sleep 60
  done
fi
[ "${foreign:-1}" -eq 0 ] || { log "FAILED: foreign pending pods persist; not risking prefill nodes"; exit 1; }

log "phase 3: cold prefill restart"
kubectl -n $NS delete pod glm-5-2-prefill-0 glm-5-2-prefill-1 --wait=false >/dev/null 2>&1
sleep 30
for i in $(seq 1 240); do
  [ "$(ready glm-5-2-prefill)" -ge 2 ] && [ "$(ready glm-5-2-decode)" -ge 2 ] && { log "fleet Ready post-restart"; break; }
  sleep 20
done
{ [ "$(ready glm-5-2-prefill)" -ge 2 ] && [ "$(ready glm-5-2-decode)" -ge 2 ]; } || { log "FAILED post-restart"; exit 1; }

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
  local h0=$(prefill_hits); log "$tag: hits before=$h0"
  rm -rf "windows/$win/artifacts/$tag"
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "windows/$win" "$tag" 2>&1 \
    | grep -E "records stable|JOB FAILED|done:" | sed "s/^/[$tag] /"
  local h1=$(prefill_hits)
  local npull=0; [ -f "windows/$win/epp-${tag}.jsonl" ] && npull=$(grep -c "set KV cache source header" "windows/$win/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls=$npull hitsdelta=$((h1-h0))"
  timeout 60 kubectl -n $NS exec workload-access -- python3 -c "
import json
recs=[json.loads(l) for l in open('/workload/fork-runs/${win}-${tag}/profile_export.jsonl') if l.strip()]
ok=sum(1 for r in recs if (r.get('metrics') or {}).get('time_to_first_token'))
print(f'${tag}: TTFT coverage {ok}/{len(recs)}')" 2>/dev/null | tail -1
  local young=$(kubectl -n $NS get pods -o json 2>/dev/null | python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
print(','.join(p['metadata']['name'] for p in json.load(sys.stdin)['items']
  if p['metadata']['name'].startswith('glm-5-2-') and 'render' not in p['metadata']['name']
  and (now-datetime.datetime.fromisoformat(p['metadata']['creationTimestamp'].replace('Z','+00:00'))).total_seconds()<600) or '-')")
  log "$tag: young engine pods: $young"
}

run baseline-rev /config/spill-off.yaml 631738ac313214-g0
run p2p-rev      /config/spill-on.yaml  21cde366f5bd2f-g5
log "reverse2 complete"
