#!/usr/bin/env bash
# Wait for both llama-fs pods, warm the TP=2 pod with a long prefix (offloads
# to shared fs), clear its GPU/CPU by warming other content, then read the SAME
# prefix on the TP=1 pod and check for a cross-TP fs load (CPU_to_GPU bytes /
# external hit). Decides: does fs multi-tier share KV across TP?
set -uo pipefail
K="kubectl --context kermit_US-EAST-01A --request-timeout=40s -n nilig-p2p"
log(){ echo "$(date +%H:%M:%S) $*"; }

log "waiting for both pods ready..."
for i in $(seq 1 90); do
  a=$($K get pods --no-headers 2>/dev/null | grep llama-fs-tp1 | grep -c "1/1 *Running")
  b=$($K get pods --no-headers 2>/dev/null | grep llama-fs-tp2 | grep -c "1/1 *Running")
  [ "$a" = "1" ] && [ "$b" = "1" ] && break; sleep 15
done
[ "$a" = "1" ] && [ "$b" = "1" ] || { log "pods not ready (tp1=$a tp2=$b)"; $K get pods --no-headers | grep llama-fs; exit 1; }
T1=$($K get pods --no-headers | grep llama-fs-tp1 | awk '{print $1}')
T2=$($K get pods --no-headers | grep llama-fs-tp2 | awk '{print $1}')
log "tp1=$T1  tp2=$T2"

offload_load(){ $K exec "$1" -c modelserver -- python3 -c "
import urllib.request
d=urllib.request.urlopen('http://localhost:8000/metrics',timeout=10).read().decode()
lb=sc=0.0
for l in d.splitlines():
    if l.startswith('vllm:kv_offload_load_bytes'): lb=float(l.split()[-1])
    if l.startswith('vllm:external_prefix_cache_hits_total{'): sc+=float(l.split()[-1])
print(int(lb), int(sc))" 2>/dev/null; }

gen(){ $K exec "$1" -c modelserver -- python3 -c "
import json,urllib.request
body={'model':'meta-llama/Llama-3.1-8B-Instruct','prompt':'''$2''','max_tokens':$3,'temperature':0,'ignore_eos':True}
r=urllib.request.urlopen(urllib.request.Request('http://localhost:8000/v1/completions',data=json.dumps(body).encode(),headers={'content-type':'application/json'}),timeout=120)
print('code', r.getcode())" 2>&1 | tail -1; }

PREFIX="FSXTP $(python3 -c "print(' '.join(['word']*8000))")"
log "warm TP=2 with an 8K prefix (writes blocks to shared fs)..."
gen "$T2" "$PREFIX Q1:" 16
sleep 8   # let async offload CPU->fs flush
log "tp2 fs-store side offloaded. Now READ same prefix on TP=1 (cold GPU):"
read LB0 SC0 < <(offload_load "$T1"); log "tp1 before: load_bytes=$LB0 ext_hits=$SC0"
gen "$T1" "$PREFIX Q2:" 16
sleep 3
read LB1 SC1 < <(offload_load "$T1"); log "tp1 after:  load_bytes=$LB1 ext_hits=$SC1"
DL=$((LB1-LB0)); DH=$((SC1-SC0))
log "tp1 cross-TP fs read: load_bytes_delta=$DL ext_hits_delta=$DH"
echo "--- tp1 log: fs/tiering warnings or layout errors:"
$K logs "$T1" -c modelserver --tail=1500 2>/dev/null | grep -iE "fs|tier|block_len|shape|mismatch|reject|layout|fingerprint|error" | grep -viE "INFO.*Refreshed|POST /" | tail -8 | cut -c1-160
if [ "$DL" -gt 0 ]; then log "VERDICT: cross-TP fs read LOADED bytes -> fs multi-tier SHARES KV across TP (problem is p2p-session-specific)"; else log "VERDICT: cross-TP fs read loaded 0 bytes -> fs does NOT share across TP either (KV layout is TP-locked in general)"; fi
