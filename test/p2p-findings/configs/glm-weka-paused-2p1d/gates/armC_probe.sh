#!/bin/bash
# Arm C engagement probe: the stop-rule implementation. Runs a SHORT arm C
# burst at the target concurrency and measures organic P2P engagement
# through the stock EPP path (directives deduplicated by requestID). Fails closed.
#
# Engagement counter: the EPP's p2p-source-producer logs
# "set KV cache source header" at Info per emitted directive
# (producer.go), so the streamed EPP log divided by the burst's request
# count is the engagement rate. Corroboration: source-side session delta
# across the fleet.
#
# Exit nonzero when zero directives were emitted (P2P inert - do not run
# the performance A/B at this cell). Prints the engagement rate for the
# >=5% stage-2 rule; the caller decides on rates between 0 and 5%.
set -euo pipefail
NS=${NS:-nilig-p2p}
CONC=${1:?usage: armC_probe.sh <concurrency> [duration_s]}
DUR=${2:-900}
# the scenario locks duration >= 900s (steady state + KV offloading);
# reject early, before arm activation or log streaming
[ "$DUR" -ge 900 ] || { echo "ABORT: duration ${DUR}s < scenario minimum 900s"; exit 1; }
SP="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${OUT:-$SP/gates/probe-c${CONC}-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"

# activate arm C (swap + verify, no workload)
NS="$NS" "$SP/activate_arm.sh" armC

sessions() {
  local n=0 c
  for p in $(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' -o name); do
    c=$(kubectl -n "$NS" logs "${p#pod/}" -c vllm --tail=200000 2>/dev/null \
        | grep -c "accepting incoming connection" || true)
    n=$((n+c))
  done
  echo "$n"
}

EPP_POD=$(kubectl -n "$NS" get pods -l app=p2p-pd-epp -o name | head -1)
EPP_POD=${EPP_POD#pod/}
prefill_load_bytes() {
  local total=0 b
  for p in $(kubectl -n "$NS" get pods -l 'llm-d.ai/role=prefill' -o name 2>/dev/null); do
    b=$(kubectl -n "$NS" exec "${p#pod/}" -c vllm -- sh -c \
      'for r in 0 1 2 3 4 5 6 7; do curl -s --max-time 5 localhost:$((8000+r))/metrics; done' 2>/dev/null | \
      python3 -c "
import sys
txt=sys.stdin.read().splitlines()
def fam(match):
    t,seen=0.0,False
    for ln in txt:
        if ln.startswith('#') or not match(ln): continue
        try: t+=float(ln.rsplit(' ',1)[1]); seen=True
        except Exception: pass
    return t,seen
t,seen=fam(lambda ln:'kv_offload_load_bytes_total' in ln)
if not seen:
    t,seen=fam(lambda ln:'kv_offload_total_bytes_total' in ln and 'CPU_to_GPU' in ln)
print(int(t))")
    total=$((total + ${b:-0}))
  done
  echo "$total"
}

S0=$(sessions)
B0=$(prefill_load_bytes)
# filter to request-bearing lines: at --v=5 the raw stream is dominated
# by metric-refresh noise (107 MB in a 3-minute attempt); the directive
# lines all carry a requestID field
kubectl -n "$NS" logs --tail=0 -f "$EPP_POD" -c epp 2>/dev/null \
  | grep --line-buffered '"requestID"' > "$OUT/epp-stream.jsonl" &
STREAM_PID=$!
trap 'kill $STREAM_PID 2>/dev/null || true' EXIT
# ensure the stream is attached before any directive can be emitted
sleep 5
kill -0 $STREAM_PID 2>/dev/null || { echo "ABORT: EPP log stream failed to attach"; exit 1; }

# short burst: the recovered runner at this cell, duration-limited
cd "$SP"
python3 - "$CONC" "$DUR" "$NS" << 'PY'
import json, sys
conc, dur, ns = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open('workload/blog-campaign-job-c64.json'))
d.pop('status', None)
d['metadata'] = {'name': 'weka-probe', 'namespace': ns}
d['spec'].pop('selector', None)
labels = d['spec']['template'].setdefault('metadata', {}).setdefault('labels', {})
for k in list(labels):
    if 'controller-uid' in k or 'job-name' in k: labels.pop(k)
spec = d['spec']['template']['spec']
c = spec['containers'][0]
a = c['args'][-1].replace('--concurrency 64', f'--concurrency {conc}')
a = a.replace('--benchmark-duration 900', f'--benchmark-duration {dur}')
c['args'][-1] = a
env = {e['name']: e for e in c.get('env', [])}
env['URL']['value'] = f'http://p2p-pd-epp.{ns}:8081/v1'
env['SERVER_METRICS_ARGS']['value'] = f'--server-metrics http://p2p-pd-epp.{ns}:9090/metrics'
env['ARTIFACT_DIR']['value'] = '/workload/weka-probe/attempt1'
env['CANONICAL_ARTIFACT_DIR']['value'] = '/workload/weka-probe/canonical'
for v in spec['volumes']:
    if v.get('persistentVolumeClaim', {}).get('claimName') == 'lustre-pvc-vllm':
        v['persistentVolumeClaim'] = {'claimName': 'workload-pvc'}
for m in c.get('volumeMounts', []):
    if m['mountPath'] == '/mnt/lustre':
        m['mountPath'] = '/workload'
json.dump(d, open('weka-job-probe.json', 'w'), indent=1)
PY
kubectl -n "$NS" delete job weka-probe --ignore-not-found >/dev/null
kubectl -n "$NS" apply -f weka-job-probe.json >/dev/null
echo "probe burst launched (c$CONC, ${DUR}s)"
kubectl -n "$NS" wait --for=condition=complete --timeout=$((DUR+600))s job/weka-probe 2>&1 | tail -1 \
  || { echo "ABORT: probe job did not complete"; exit 1; }
JP=$(kubectl -n "$NS" get pods --no-headers | awk 'index($1,"weka-probe")==1 {print $1; exit}')
kubectl -n "$NS" logs "$JP" > "$OUT/probe-client.log" 2>/dev/null
sleep 3
kill $STREAM_PID 2>/dev/null || true
S1=$(sessions)
B1=$(prefill_load_bytes)

EMITS=$(python3 - "$OUT/epp-stream.jsonl" << 'PY'
import sys, re
ids = set()
for ln in open(sys.argv[1], errors='ignore'):
    if 'set KV cache source header' not in ln: continue
    m = re.search(r'"requestID"\s*:\s*"([^"]+)"|requestID[=\s]+"?([\w-]+)', ln)
    ids.add((m.group(1) or m.group(2)) if m else ln)
print(len(ids))
PY
)
REQS=$(python3 - "$OUT/epp-stream.jsonl" << 'PY'
import sys, re
ids = set()
for ln in open(sys.argv[1], errors='ignore'):
    m = re.search(r'"requestID"\s*:\s*"([^"]+)"|requestID[=\s]+"?([\w-]+)', ln)
    if m: ids.add(m.group(1) or m.group(2))
print(len(ids))
PY
)
BMB=$(python3 -c "print(round(($B1-$B0)/1e6,1))")
echo "probe c$CONC: requests_seen=$REQS source_directives=$EMITS sessions_delta=$((S1-S0)) prefill_loaded_MB=$BMB" | tee "$OUT/summary.txt"
if [ "$REQS" -gt 0 ]; then
  RATE=$(python3 -c "print(round(100.0*$EMITS/$REQS,1))")
else
  RATE=0
fi
echo "engagement rate: ${RATE}% (stage-2 threshold: 5%)" | tee -a "$OUT/summary.txt"
if [ "$EMITS" -eq 0 ]; then
  echo "PROBE: FAIL - zero source directives; P2P is inert at c$CONC, do not run the A/B here" | tee -a "$OUT/summary.txt"
  exit 1
fi
# bytes corroborate that organic pulls succeeded (necessary, not
# attributable on their own: the counter includes local CPU restores)
python3 -c "exit(0 if $BMB > 0 else 1)" || {
  echo "PROBE: FAIL - directives were emitted but destination prefill engines moved zero bytes" | tee -a "$OUT/summary.txt"
  exit 1
}
echo "PROBE: PASS (archive in $OUT)" | tee -a "$OUT/summary.txt"
