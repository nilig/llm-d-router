#!/bin/bash
# One campaign arm. Fails closed: config swap, producer declaration,
# fleet readiness, foreign-workload absence, and the warm probe are all
# hard gates. Usage: run_arm.sh <armA|armB|armC> <concurrency> <tag>
set -euo pipefail
NS=${NS:-nilig-p2p}
LOADGEN=${LOADGEN:-scenc-loadgen}
FLEET_EXPECT=${FLEET_EXPECT:-4}
ALLOW_FOREIGN=${ALLOW_FOREIGN:-0}
SEED=${SEED:-42}
ARM="$1"; CONC="$2"; TAG="$3"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"

declare -A CFG=( [armA]=armA-blog-plugins.yaml [armB]=armB-loadfirst.yaml [armC]=armC-loadfirst-p2p.yaml )
declare -A WANT_P2P=( [armA]=0 [armB]=0 [armC]=1 )

echo "### ARM $ARM c$CONC (tag $TAG) ns=$NS ###"
IDX=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i,c in enumerate(d['spec']['template']['spec']['containers']):
    if c['name']=='epp': print(i)")
POS=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'].index('--config-file')+1)")
kubectl -n "$NS" patch deploy p2p-pd-epp --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/${CFG[$ARM]}\"}]" >/dev/null
kubectl -n "$NS" rollout status deploy/p2p-pd-epp --timeout=300s | tail -1

ACTIVE=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
[ "$ACTIVE" = "/config/${CFG[$ARM]}" ] || { echo "ABORT: config swap failed (active=$ACTIVE)"; exit 1; }

P2P=$(kubectl -n "$NS" get cm p2p-weka-epp-plugins -o json | python3 -c "
import json,sys
body=json.load(sys.stdin)['data']['${CFG[$ARM]}']
print(sum(1 for l in body.splitlines() if l.strip().startswith('- type: p2p-source-producer')))")
echo "p2p-source-producer declared: $P2P (want ${WANT_P2P[$ARM]})"
[ "$P2P" = "${WANT_P2P[$ARM]}" ] || { echo "ABORT: producer declaration mismatch"; exit 1; }

READY=$(kubectl -n "$NS" get pods -l 'llm-d.ai/model' --no-headers \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") n++} END {print n+0}')
echo "fleet ready pods: $READY (want $FLEET_EXPECT)"
[ "$READY" -eq "$FLEET_EXPECT" ] || { echo "ABORT: fleet not fully ready"; exit 1; }

FOREIGN=$(kubectl -n "$NS" get jobs --no-headers 2>/dev/null \
  | awk -v t="weka-$TAG" '$1 != t {n++} END {print n+0}')
if [ "$FOREIGN" -gt 0 ] && [ "$ALLOW_FOREIGN" != "1" ]; then
  kubectl -n "$NS" get jobs --no-headers | awk -v t="weka-$TAG" '$1 != t'
  echo "ABORT: $FOREIGN foreign job(s) present (delete them or set ALLOW_FOREIGN=1 with justification)"
  exit 1
fi

for attempt in 1 2 3 4; do
  code=$(kubectl -n "$NS" exec "$LOADGEN" -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'hi','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://p2p-pd-epp.${NS}:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=300).status)
except Exception as e: print('ERR',type(e).__name__)" 2>&1 | tail -1)
  echo "probe $attempt: $code"; [ "$code" = "200" ] && break; sleep 20
done
[ "$code" = "200" ] || { echo "ABORT: probe failed"; exit 1; }

NS="$NS" ./snap_counters.sh "$SP/snap-$TAG-before.txt"

# the recovered runner (see workload/README.md - reconstruction status),
# cloned verbatim; only URL/metrics endpoints, artifact volume, namespace,
# and the concurrency cell change.
python3 - "$TAG" "$CONC" "$NS" "$SEED" << 'PY'
import json, sys
tag, conc, ns, seed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open('workload/blog-campaign-job-c64.json'))
d.pop('status', None)
d['metadata'] = {'name': f'weka-{tag}', 'namespace': ns}
d['spec'].pop('selector', None)
labels = d['spec']['template'].setdefault('metadata', {}).setdefault('labels', {})
for k in list(labels):
    if 'controller-uid' in k or 'job-name' in k: labels.pop(k)
spec = d['spec']['template']['spec']
c = spec['containers'][0]
a = c['args'][-1].replace('--concurrency 64', f'--concurrency {conc}')
a = a.replace('--random-seed 42', f'--random-seed {seed}')
c['args'][-1] = a
env = {e['name']: e for e in c.get('env', [])}
env['URL']['value'] = f'http://p2p-pd-epp.{ns}:8081/v1'
env['SERVER_METRICS_ARGS']['value'] = f'--server-metrics http://p2p-pd-epp.{ns}:9090/metrics'
env['ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/attempt1'
env['CANONICAL_ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/canonical'
for v in spec['volumes']:
    if v.get('persistentVolumeClaim', {}).get('claimName') == 'lustre-pvc-vllm':
        v['persistentVolumeClaim'] = {'claimName': 'workload-pvc'}
for m in c.get('volumeMounts', []):
    if m['mountPath'] == '/mnt/lustre':
        m['mountPath'] = '/workload'
json.dump(d, open(f'weka-job-{tag}.json', 'w'), indent=1)
PY
kubectl -n "$NS" delete job "weka-$TAG" --ignore-not-found >/dev/null
kubectl -n "$NS" apply -f "weka-job-$TAG.json" >/dev/null
echo "aiperf job weka-$TAG launched (900 s); waiting..."
kubectl -n "$NS" wait --for=condition=complete --timeout=1800s "job/weka-$TAG" 2>&1 | tail -1 \
  || { echo "ABORT: job did not complete"; kubectl -n "$NS" logs "job/weka-$TAG" --tail=20; exit 1; }
JP=$(kubectl -n "$NS" get pods --no-headers | awk -v t="weka-$TAG" 'index($1,t)==1 {print $1; exit}')
kubectl -n "$NS" logs "$JP" > "$SP/weka-$TAG.log" 2>/dev/null
NS="$NS" ./snap_counters.sh "$SP/snap-$TAG-after.txt"
echo "=== summary ==="
ERRS=$(grep -icE "error|fail" "$SP/weka-$TAG.log" || true)
echo "error-ish lines in client log: $ERRS (inspect before trusting the arm)"
grep -iE "time to first token|inter token|request latency|throughput|Benchmark Duration|request count" "$SP/weka-$TAG.log" | tail -12
