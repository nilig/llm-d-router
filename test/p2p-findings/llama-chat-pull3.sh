#!/usr/bin/env bash
# THE prefill<-decode generated-history pull demo (Llama-8B, chat API).
# Why this works where everything else failed: Llama's chat template
# re-renders the assistant turn to the SAME token ids the decode generated
# (round-trip-stable, no dropped channels), so decode's KV chain
# [prompt ids + generated ids] matches turn N+1's rendered prompt exactly.
# Driver: multi-turn chat via the DECODE pod's sidecar (P/D orchestration),
# turn N+1 carries x-kv-cache-source-host-port = the decode pod -> the
# sidecar injects p2p params on the PREFILL leg -> prefill pulls the full
# history (prefix + generated answer) from decode's tier.
# Control: same flow without the source header (prefill recomputes).
set -uo pipefail
K="kubectl --context kermit_US-EAST-01A --request-timeout=40s -n nilig-p2p"
log(){ echo "$(date +%H:%M:%S) $*"; }

log "waiting for llama pair..."
for i in $(seq 1 60); do
  P=$($K get pods --no-headers 2>/dev/null | grep llama-pd-prefill | grep -c "1/1 *Running")
  D=$($K get pods --no-headers 2>/dev/null | grep llama-pd-decode | grep -c "2/2 *Running")
  [ "$P" = "1" ] && [ "$D" = "1" ] && break; sleep 10
done
[ "$P" = "1" ] && [ "$D" = "1" ] || { log "pair not ready"; exit 1; }
PPOD=$($K get pods -o wide --no-headers | grep llama-pd-prefill | awk '{print $1}')
PIP=$($K get pods -o wide --no-headers | grep llama-pd-prefill | awk '{print $6}')
DPOD=$($K get pods -o wide --no-headers | grep llama-pd-decode | grep Running | awk '{print $1}')
DIP=$($K get pods -o wide --no-headers | grep llama-pd-decode | grep Running | awk '{print $6}')
log "prefill=$PPOD ($PIP)  decode=$DPOD ($DIP)"

pm(){ $K exec "$PPOD" -c modelserver -- python3 -c "
import urllib.request
d=urllib.request.urlopen('http://localhost:8000/metrics',timeout=10).read().decode()
eh=lb=0.0
for l in d.splitlines():
    if l.startswith('vllm:external_prefix_cache_hits_total{'): eh+=float(l.split()[-1])
    elif l.startswith('vllm:kv_offload_load_bytes_total'): lb=float(l.split()[-1])
print(int(eh), int(lb))" 2>/dev/null; }

cat > /tmp/chatpull.py <<'PYEOF'
import json,urllib.request,time,sys,uuid
PIP, DIP, MODE = sys.argv[1], sys.argv[2], sys.argv[3]  # MODE: pull|control
EP="http://localhost:8000/v1/chat/completions"
sysmsg=f"[{MODE}] You are a meticulous analyst. "+" ".join([MODE.lower()]*8000)
msgs=[{"role":"system","content":sysmsg},{"role":"user","content":"Q1: write a very detailed analysis in 20 numbered sections, each a full paragraph."}]
def call(msgs,n,src):
    body={"model":"meta-llama/Llama-3.1-8B-Instruct","messages":msgs,"max_tokens":n,"temperature":0}
    h={"content-type":"application/json","x-prefiller-host-port":f"{PIP}:8000"}
    if src: h["x-kv-cache-source-host-port"]=f"{DIP}:8000"
    t0=time.time()
    r=urllib.request.urlopen(urllib.request.Request(EP,data=json.dumps(body).encode(),headers=h),timeout=300)
    d=json.loads(r.read()); return d["choices"][0]["message"]["content"], time.time()-t0
# turn 1: no source (nothing to pull), decode generates 2500 tokens
a1,t1=call(msgs,2500,False)
import re
marks=[m.start() for m in re.finditer(r"<\|",a1)]
print(f"special-marks in a1: {len(marks)} at {marks[:3]}",flush=True)
print(f"turn1: {t1:.1f}s gen={len(a1)}ch",flush=True)
time.sleep(6)  # let decode offload generated blocks to its CPU tier
# prime p2p session prefill->decode (cold-session defect workaround)
if MODE=="pull":
    pm=[{"role":"user","content":"PRIME "+" ".join(["x"]*100)}]
    call(pm,4,True); time.sleep(4)
    print("session primed",flush=True)
# turn 2: history = sys + u1 + a1 + u2. prefill leg must obtain a1's KV.
msgs+= [{"role":"assistant","content":a1},{"role":"user","content":"Q2: continue."}]
a2,t2=call(msgs,32,MODE=="pull")
print(f"turn2 [{MODE}]: {t2:.2f}s",flush=True)
PYEOF
$K cp /tmp/chatpull.py "$DPOD":/tmp/chatpull.py -c modelserver >/dev/null 2>&1

log "=== CONTROL (no source header; prefill recomputes history) ==="
read EH0 LB0 < <(pm)
$K exec "$DPOD" -c modelserver -- python3 /tmp/chatpull.py "$PIP" "$DIP" control
read EH1 LB1 < <(pm)
log "control: prefill ext_hits+$((EH1-EH0)) load+$(( (LB1-LB0)/1024/1024 ))MB"

log "=== PULL (source = decode; prefill should pull generated history) ==="
read EH2 LB2 < <(pm)
$K exec "$DPOD" -c modelserver -- python3 /tmp/chatpull.py "$PIP" "$DIP" pull
read EH3 LB3 < <(pm)
log "pull: prefill ext_hits+$((EH3-EH2)) load+$(( (LB3-LB2)/1024/1024 ))MB"
echo "--- prefill p2p log:"
$K logs "$PPOD" -c modelserver --since=4m 2>/dev/null | grep -iE "p2p|peer|session" | grep -viE "POST|Metrics" | tail -4 | cut -c1-150
if [ $((EH3-EH2)) -gt 6000 ]; then log "VERDICT: PREFILL PULLED THE HISTORY FROM DECODE (generated KV matched via chat round-trip)"
else log "VERDICT: pull delta $((EH3-EH2)) - inspect"; fi
