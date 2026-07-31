#!/bin/bash
# Gate 2: one-shot P2P proof on the P2P arm, before any Weka run.
# Seeds a fresh 24,576-token prefix on a source rank, then measures the
# consumer's loaded-bytes delta without and with pull injection.
# PASS: no-pull control ~0.0 MB; pull ~2,276.4 MB (24,576 x 92.6 KB/token),
# HTTP 200, and the source-side listener logged an accepted transfer.
#
# Runs from the in-cluster loadgen pod (kubectl exec); read-only on the
# fleet apart from the probe requests themselves.
set -u
NS=${NS:-nilig-p2p}
LOADGEN=${LOADGEN:-scenc-loadgen}
SRC_POD=${SRC_POD:?set SRC_POD (decode pod holding the seed)}
SRC_RANK=${SRC_RANK:-0}
DST_URL=${DST_URL:?set DST_URL (prefill leader http url)}
SRC_URL=${SRC_URL:?set SRC_URL (source rank serving url, port 8200+rank)}
SRC_IP=${SRC_IP:?set SRC_IP (source pod ip)}
P2P_PORT=$((7777 + SRC_RANK))
TOKENS=24576
OUT=${OUT:-gate2-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"

metrics_bytes() {
  kubectl -n $NS exec $LOADGEN -- python3 - "$1" << 'PY'
import sys, urllib.request
url = sys.argv[1]
txt = urllib.request.urlopen(url, timeout=30).read().decode()
def fam(match):
    total, seen = 0.0, False
    for ln in txt.splitlines():
        if ln.startswith('#') or not match(ln): continue
        try:
            total += float(ln.rsplit(' ',1)[1]); seen = True
        except (IndexError, ValueError): pass
    return total, seen
t, s = fam(lambda ln: 'kv_offload_load_bytes_total' in ln)
if not s:
    t, s = fam(lambda ln: 'kv_offload_total_bytes_total' in ln and 'CPU_to_GPU' in ln)
print(t if s else 'NaN')
PY
}

echo "== Gate 2: fresh-prefix P2P proof ==" | tee "$OUT/log"
# 1. seed fresh random-token prefix on the source rank (concurrent per-rank
#    seeding pattern from the calibration recipe applies if the balancer
#    may move it; here we hit the rank's own port so a single post pins it)
kubectl -n $NS exec $LOADGEN -- python3 - "$SRC_URL" "$TOKENS" << 'PY' | tee -a "$OUT/log"
import sys, json, random, urllib.request, time
url, n = sys.argv[1], int(sys.argv[2])
ids = [random.randint(600, 140000) for _ in range(n)]
open('/tmp/gate2_ids.json','w').write(json.dumps(ids))
b = json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0}).encode()
t0=time.monotonic()
r = urllib.request.urlopen(urllib.request.Request(url+'/v1/completions', data=b,
    headers={'Content-Type':'application/json'}), timeout=600)
print('seed status', r.status, f'{time.monotonic()-t0:.1f}s')
PY

# 2/3. consumer runs: control (no injection) then pull injection
for MODE in control pull; do
  M0=$(metrics_bytes "$DST_URL/metrics")
  kubectl -n $NS exec $LOADGEN -- python3 - "$DST_URL" "$MODE" "$SRC_IP" "$P2P_PORT" << 'PY' | tee -a "$OUT/log"
import sys, json, urllib.request, time, uuid
url, mode, ip, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ids = json.load(open('/tmp/gate2_ids.json'))
body = {'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0}
if mode == 'pull':
    body['kv_transfer_params'] = {'remote_kv_source': {
        'kv_request_id': str(uuid.uuid4()), 'remote_host': ip, 'remote_port': port}}
t0=time.monotonic()
r = urllib.request.urlopen(urllib.request.Request(url+'/v1/completions',
    data=json.dumps(body).encode(), headers={'Content-Type':'application/json'}), timeout=600)
print(mode, 'status', r.status, f'{time.monotonic()-t0:.1f}s')
PY
  M1=$(metrics_bytes "$DST_URL/metrics")
  echo "$MODE loaded_MB=$(python3 -c "print((${M1:-0}-${M0:-0})/1e6)")" | tee -a "$OUT/log"
done

# source accept evidence
kubectl -n $NS logs "$SRC_POD" -c vllm --tail=2000 2>/dev/null | \
  grep -iE "accepting incoming|incoming connection|session" | tail -5 | tee "$OUT/source-accept.txt"

echo "PASS criteria: control ~0.0 MB, pull ~2276.4 MB, both status 200, source accept logged." | tee -a "$OUT/log"
