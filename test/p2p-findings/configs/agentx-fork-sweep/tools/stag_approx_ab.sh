#!/usr/bin/env bash
# Six-arm fork campaign on one fleet: the guide's fitted-approximate pair and
# the load-modeled tokenload (spill) pair, each +-p2p-source-producer, on the
# big twin windows. Prefill pods restart between pairs so both pairs start
# cold; decode persists (its tier is a legitimate pull source, as in all
# prior runs). Assignments match the prior campaigns:
#   baseline arms -> 21cde366-g5 (W=44) | p2p arms -> 631738-g0 (W=43)
set -uo pipefail
cd "$(dirname "$0")"
NS=nilig-agentx-slo; EPP=agentx-slo-epp; POD=workload-access
WB=21cde366f5bd2f-g5; WP=631738ac313214-g0
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
cleanup(){ [ -n "${KW_PID:-}" ] && kill "$KW_PID" 2>/dev/null; }
trap cleanup EXIT

ready(){ r=$(timeout 30 kubectl -n $NS get lws $1 -o jsonpath='{.status.readyReplicas}' 2>/dev/null); echo ${r:-0}; }
desired(){ r=$(timeout 30 kubectl -n $NS get lws $1 -o jsonpath='{.spec.replicas}' 2>/dev/null); echo ${r:-0}; }
wait_fleet(){
  # gpu-pruner treats weight-loading pods (Running, zero traffic, older than its
  # ~35min lookback) as idle and zeroes the LWS mid-boot. Guard: re-assert
  # replicas=2 every iteration and count strikes.
  local strikes=0
  for i in $(seq 1 240); do
    for lws in glm-5-2-prefill glm-5-2-decode; do
      if [ "$(desired $lws)" -lt 2 ]; then
        strikes=$((strikes+1))
        log "PRUNER-GUARD: $lws desired dropped, re-patching to 2 (strike $strikes)"
        kubectl -n $NS patch lws $lws --type=json -p '[{"op":"replace","path":"/spec/replicas","value":2}]' >/dev/null 2>&1
      fi
    done
    [ "$(ready glm-5-2-prefill)" -ge 2 ] && [ "$(ready glm-5-2-decode)" -ge 2 ] && { [ $strikes -gt 0 ] && log "boot survived $strikes pruner strikes"; return 0; }
    sleep 30
  done
  return 1
}

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
  # rollout success IS the config gate: a bad EPP config crashloops and the
  # status wait times out
  kubectl -n $NS rollout status deploy/$EPP --timeout=5m >/dev/null 2>&1 \
    || { log "FAIL: EPP rollout did not become Ready for $tag"; exit 1; }
  sleep 45
  # best-effort startup capture from the newest pod (trace spam floods and
  # rotates the log fast, so absence of the boot lines is NOT an error)
  local eppod=$(kubectl -n $NS get pods -o name --sort-by=.metadata.creationTimestamp 2>/dev/null | grep "$EPP" | tail -1)
  [ -n "$eppod" ] && kubectl -n $NS logs "$eppod" -c epp 2>/dev/null | head -2000 > "windows/$win/epp-startup-${tag}.log"
  grep -q "Instantiated all plugins" "windows/$win/epp-startup-${tag}.log" 2>/dev/null \
    || log "note: startup lines already rotated out for $tag (gate = rollout Ready)" 
  local h0=$(prefill_hits); log "$tag: hits before=$h0"
  rm -rf "windows/$win/artifacts/$tag"
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "windows/$win" "$tag" 2>&1 \
    | grep -E "records stable|JOB FAILED|done:" | sed "s/^/[$tag] /"
  local h1=$(prefill_hits)
  local npull=0; [ -f "windows/$win/epp-${tag}.jsonl" ] && npull=$(grep -c "set KV cache source header" "windows/$win/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls=$npull hitsdelta=$((h1-h0))"
  timeout 60 kubectl -n $NS exec $POD -- python3 -c "
import json
recs=[json.loads(l) for l in open('/workload/fork-runs/${win}-${tag}/profile_export.jsonl') if l.strip()]
ok=sum(1 for r in recs if (r.get('metrics') or {}).get('time_to_first_token'))
print(f'${tag}: TTFT coverage {ok}/{len(recs)}')" 2>/dev/null | tail -1
  local young=$(kubectl -n $NS get pods -o json 2>/dev/null | python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
print(','.join(p['metadata']['name'] for p in json.load(sys.stdin)['items']
  if p['metadata']['name'].startswith('glm-5-2-') and 'render' not in p['metadata']['name']
  and (now-datetime.datetime.fromisoformat(p['metadata']['creationTimestamp'].replace('Z','+00:00'))).total_seconds()<480) or '-')")
  log "$tag: young engine pods: $young"
}

NEWIMG=quay.io/niliguy/llm-d-router-endpoint-picker:p2p-cputier-c68d52c6
log "STAGGERED APPROX A/B: same composition, approximate index, fixed EPP"
wait_fleet_mf(){
  for i in $(seq 1 240); do
    pr=$(timeout 30 kubectl -n $NS get lws glm-5-2-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    d=$(timeout 30 kubectl -n $NS get lws glm-5-2-decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [ "${pr:-0}" -ge 3 ] && [ "${d:-0}" -ge 1 ] && return 0
    sleep 30
  done
  return 1
}
kubectl -n $NS patch lws glm-5-2-prefill --type=json -p '[{"op":"replace","path":"/spec/replicas","value":3}]' >/dev/null
kubectl -n $NS patch lws glm-5-2-decode  --type=json -p '[{"op":"replace","path":"/spec/replicas","value":1}]' >/dev/null
kubectl -n $NS delete pod glm-5-2-prefill-0 glm-5-2-prefill-1 glm-5-2-prefill-2 glm-5-2-decode-0 --wait=false >/dev/null 2>&1
sleep 30; wait_fleet_mf || { log "FAIL: fleet never Ready"; exit 1; }
log "fleet Ready"
./keep_warm.sh >/tmp/stagapx-keepwarm.log 2>&1 & KW_PID=$!
for pod in glm-5-2-prefill-0 glm-5-2-prefill-1 glm-5-2-prefill-2 glm-5-2-decode-0; do
  nohup bash -c "while true; do kubectl -n $NS logs $pod -c vllm -f --tail=5 >> /tmp/stagapx-$pod.log 2>/dev/null; echo \"--- stream ended \$(date -u +%H:%M:%S) ---\" >> /tmp/stagapx-$pod.log; sleep 5; done" >/dev/null 2>&1 &
done

run stag-approx-base /config/mfapprox-off.yaml staggered-v1

log "full engine restart before p2p arm"
kubectl -n $NS delete pod glm-5-2-prefill-0 glm-5-2-prefill-1 glm-5-2-prefill-2 glm-5-2-decode-0 --wait=false >/dev/null 2>&1
sleep 30; wait_fleet_mf || { log "FAIL: fleet incomplete"; exit 1; }
run stag-approx-p2p /config/mfapprox-on.yaml staggered-v1

log "STAGGERED RESULTS"
for t in stag-base stag-p2p stag-approx-base stag-approx-p2p; do
  ./.venv/bin/python - "$t" <<'PYEOF'
import json, statistics, sys
t=sys.argv[1]
try: recs=[json.loads(l) for l in open(f"windows/staggered-v1/artifacts/{t}/profile_export.jsonl") if l.strip()]
except FileNotFoundError: print(f"{t}: no artifacts"); sys.exit(0)
firsts={}
for r in recs:
    cid=r["metadata"]["conversation_id"]
    cur=firsts.get(cid)
    if cur is None or r["metadata"].get("turn_index",0)<cur["metadata"].get("turn_index",0): firsts[cid]=r
vals=sorted(t2 for cid,r in firsts.items()
            if ((r["metrics"].get("input_sequence_length") or {}).get("value") or 0)>=15000
            and (t2:=(r["metrics"].get("time_to_first_token") or {}).get("value")))
if vals:
    cold=[v for v in vals if v>=3000]; warm=[v for v in vals if v<3000]
    print(f"{t}: n={len(vals)} p50={statistics.median(vals):,.0f} p90={vals[int(.9*(len(vals)-1))]:,.0f} max={max(vals):,.0f} COLD n={len(cold)} mean={statistics.mean(cold) if cold else 0:,.0f} warm={len(warm)}")
PYEOF
done
[ -f windows/staggered-v1/epp-stag-p2p.jsonl ] && ./.venv/bin/python delta_stats.py windows/staggered-v1/epp-stag-approx-p2p.jsonl --label stag-approx-p2p
pkill -f "stagapx-glm" 2>/dev/null
log "STAGGERED APPROX AB complete"
