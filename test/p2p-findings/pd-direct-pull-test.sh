#!/usr/bin/env bash
# Standalone prefill<-decode P2P pull test. No EPP, no sidecar, no benchmark:
# 1. warm ONE decode engine (:8200, direct) with an 8K INPUT prompt X
#    (input text tokenizes identically on any engine - no retokenization issue)
# 2. control: fresh 8K prompt Y on the prefill engine (:8000) -> compute-time ref
# 3. pull test: same prompt X on the prefill engine with hand-injected
#    kv_transfer_params.p2p={kv_request_id,remote_host=<decode-ip>,remote_port=7777}
#    (exactly what the sidecar injects - pkg/sidecar/proxy/connector_p2p.go)
# Verdict from prefill ext_hits/load_bytes deltas + TTFT vs control + both logs.
# MODEL/PPAT/DPAT select the deployment; TAG salts the prompts so repeat runs
# against the same prefill are not satisfied by its local prefix cache.
set -uo pipefail
K="kubectl --context kermit_US-EAST-01A --request-timeout=40s -n nilig-p2p"
MODEL="${MODEL:-openai/gpt-oss-120b}"
PPAT="${PPAT:-vllm-prefill-}"
DPAT="${DPAT:-vllm-decode-}"
TAG="${TAG:-DPULL42}"
log(){ echo "$(date +%H:%M:%S) $*"; }

DP=$($K get pods -o wide --no-headers | grep "$DPAT" | grep Running | head -1 | awk '{print $1, $6}')
PP=$($K get pods --no-headers | grep "$PPAT" | grep Running | head -1 | awk '{print $1}')
D=$(echo "$DP" | awk '{print $1}'); DIP=$(echo "$DP" | awk '{print $2}')
log "decode: $D ($DIP)  prefill: $PP  model: $MODEL  tag: $TAG"

metrics(){ $K exec "$1" -c modelserver -- python3 -c "
import urllib.request
d=urllib.request.urlopen('http://localhost:$2/metrics',timeout=10).read().decode()
eh=lb=0.0
for l in d.splitlines():
    if l.startswith('vllm:external_prefix_cache_hits_total{'): eh+=float(l.split()[-1])
    elif l.startswith('vllm:kv_offload_load_bytes_total'): lb=float(l.split()[-1])
print(int(eh), int(lb))" 2>/dev/null; }

log "1. warm decode engine directly with prompt X (8K input tokens)..."
$K exec "$D" -c modelserver -- python3 -c "
import json,urllib.request,time
p='$TAG '+' '.join(['kappa']*8000)
body={'model':'$MODEL','prompt':p+' Q1:','max_tokens':8,'temperature':0,'ignore_eos':True}
t0=time.time()
urllib.request.urlopen(urllib.request.Request('http://localhost:8200/v1/completions',data=json.dumps(body).encode(),headers={'content-type':'application/json'}),timeout=300).read()
print(f'decode warm: {time.time()-t0:.1f}s')"
log "waiting 8s for CPU-tier flush..."
sleep 8

log "2. control: fresh prompt Y on prefill (compute-time reference)..."
$K exec "$PP" -c modelserver -- python3 -c "
import json,urllib.request,time
p='CTRL-$TAG '+' '.join(['sigma']*8000)
body={'model':'$MODEL','prompt':p+' Q1:','max_tokens':8,'temperature':0,'ignore_eos':True}
t0=time.time()
urllib.request.urlopen(urllib.request.Request('http://localhost:8000/v1/completions',data=json.dumps(body).encode(),headers={'content-type':'application/json'}),timeout=300).read()
print(f'control compute: {time.time()-t0:.1f}s')"

read EH0 LB0 < <(metrics "$PP" 8000)
log "3. pull test: prompt X on prefill with p2p params -> $DIP:7777  (before: ext_hits=$EH0 load_bytes=$LB0)"
$K exec "$PP" -c modelserver -- python3 -c "
import json,urllib.request,time,uuid
p='$TAG '+' '.join(['kappa']*8000)
body={'model':'$MODEL','prompt':p+' Q1:','max_tokens':8,'temperature':0,'ignore_eos':True,
      'kv_transfer_params':{'p2p':{'kv_request_id':str(uuid.uuid4()),'remote_host':'$DIP','remote_port':7777}}}
t0=time.time()
urllib.request.urlopen(urllib.request.Request('http://localhost:8000/v1/completions',data=json.dumps(body).encode(),headers={'content-type':'application/json'}),timeout=300).read()
print(f'PULL request: {time.time()-t0:.1f}s')"
sleep 3
read EH1 LB1 < <(metrics "$PP" 8000)
log "after: ext_hits=$EH1 (+$((EH1-EH0)) tokens)  load_bytes=$LB1 (+$(( (LB1-LB0)/1024/1024 ))MB)"

echo "--- prefill engine p2p lines (last 4m):"
$K logs "$PP" -c modelserver --since=4m 2>/dev/null | grep -iE "p2p|session|peer|fetch|lookup" | grep -viE "POST|health" | tail -10 | cut -c1-170
echo "--- decode engine p2p lines (last 4m):"
$K logs "$D" -c modelserver --since=4m 2>/dev/null | grep -iE "p2p|session|peer|fetch|lookup" | grep -viE "POST|health" | tail -10 | cut -c1-170
if [ $((EH1-EH0)) -gt 4000 ]; then log "VERDICT: PULL WORKED - prefill took $((EH1-EH0)) tokens from decode's tier"
else log "VERDICT: pull did NOT engage (ext_hits delta $((EH1-EH0)))"; fi
