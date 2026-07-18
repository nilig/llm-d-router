#!/usr/bin/env bash
# Mechanism gate for the gpt-oss P/D A/B: escalate concurrency until P2P
# pulls engage under the guide's own scorers (prefix3/queue2/kv2 prefill).
# Burst = C concurrent 2-turn conversations (32K-token unique docs, text
# append) through the EPP. Evidence: EPP "set KV cache source header" count
# (live follow) + prefill ext_hits/load_bytes delta per burst.
set -uo pipefail
NSP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad
source "$NSP/epp_lib.sh"
log(){ echo "$(date +%H:%M:%S) [gate] $*"; }

log "waiting for 8P+8D..."
for i in $(seq 1 90); do
  P=$($K get pods --no-headers 2>/dev/null | grep vllm-prefill- | grep -c "1/1 *Running")
  D=$($K get pods --no-headers 2>/dev/null | grep vllm-decode- | grep -c "2/2 *Running")
  [ "$P" = "8" ] && [ "$D" = "8" ] && break; sleep 20
done
[ "$P" = "8" ] && [ "$D" = "8" ] || { log "fleet not ready (P=$P D=$D)"; exit 1; }
gate && log "gate 200" || { log "EPP gate FAIL"; exit 1; }

# watchdog (post-bring-up, safe)
( for i in $(seq 1 240); do
    $K scale deploy pd-disaggregation-nvidia-gpu-vllm-prefill --replicas=8 >/dev/null 2>&1
    $K scale deploy pd-disaggregation-nvidia-gpu-vllm-decode --replicas=8 >/dev/null 2>&1
    $K scale deploy gptoss-render --replicas=6 >/dev/null 2>&1
    sleep 60
  done ) & echo $! > "$NSP/.gate_watchdog_pid"
log "watchdog started"

snap(){ local eh=0 lb=0
  for nm in $($K get pods --no-headers 2>/dev/null | grep vllm-prefill- | grep Running | awk '{print $1}'); do
    v=$($K exec "$nm" -c modelserver -- python3 -c "
import urllib.request
d=urllib.request.urlopen('http://localhost:8000/metrics',timeout=8).read().decode()
eh=lb=0.0
for l in d.splitlines():
    if l.startswith('vllm:external_prefix_cache_hits_total{'): eh+=float(l.split()[-1])
    elif l.startswith('vllm:kv_offload_load_bytes_total'): lb=float(l.split()[-1])
print(int(eh), int(lb))" 2>/dev/null)
    eh=$((eh + $(echo "$v" | awk '{print $1+0}'))); lb=$((lb + $(echo "$v" | awk '{print $2+0}')))
  done; echo "$eh $lb"; }

cat > /tmp/burst.py <<'PYEOF'
import json,urllib.request,time,sys,threading
C=int(sys.argv[1]); TURNS=2; WORDS=32000
EP="http://llm-d-router-epp.nilig-p2p.svc.cluster.local:8081/v1/completions"
ok=0; err=0; lock=threading.Lock()
def conv(i):
    global ok,err
    doc=f"GATE{C}D{i} "+" ".join(["gamma"]*WORDS)
    hist=""
    for t in range(TURNS):
        body={"model":"openai/gpt-oss-120b","prompt":doc+hist+f" Q{t}:","max_tokens":128,"temperature":0,"ignore_eos":True}
        try:
            r=urllib.request.urlopen(urllib.request.Request(EP,data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=600)
            a=json.loads(r.read())["choices"][0]["text"]
            hist+=f" Q{t}:"+a
            with lock: ok+=1
        except Exception:
            with lock: err+=1
            return
ths=[threading.Thread(target=conv,args=(i,)) for i in range(C)]
t0=time.time()
for x in ths: x.start()
for x in ths: x.join()
print(f"burst C={C}: ok={ok} err={err} dur={time.time()-t0:.0f}s",flush=True)
PYEOF
$K cp /tmp/burst.py llmdbench-harness-launcher:/tmp/burst.py >/dev/null 2>&1 || true

for C in 128 192 256; do
  log "=== BURST C=$C (2 turns x 32K docs) ==="
  read EH0 LB0 < <(snap)
  # live header counter during the burst
  $K logs deploy/llm-d-router-epp -c epp -f --tail=0 2>/dev/null | grep --line-buffered -c "set KV cache source header" > "$NSP/.gate_hdr_$C" & HF=$!
  $K exec llmdbench-harness-launcher -- python3 /tmp/burst.py "$C" 2>&1 | tail -1
  sleep 5; kill $HF 2>/dev/null
  read EH1 LB1 < <(snap)
  HDR=$(tail -1 "$NSP/.gate_hdr_$C" 2>/dev/null || echo 0)
  log "C=$C: header-fires=$HDR prefill ext_hits_delta=$((EH1-EH0)) load_delta=$(( (LB1-LB0)/1024/1024 ))MB"
  if [ "${HDR:-0}" -gt 0 ]; then log "MECHANISM ENGAGED at C=$C - lock this for the A/B"; echo "$C" > "$NSP/.gate_locked_C"; break; fi
  sleep 20
done
[ -f "$NSP/.gate_locked_C" ] || log "NO ENGAGEMENT up to C=256 - report before benchmarking"
log "GATE DONE"
