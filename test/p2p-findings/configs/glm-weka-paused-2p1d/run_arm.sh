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

case "$ARM" in
  armA) CFGF=armA-blog-plugins.yaml; WANT=0 ;;
  armB) CFGF=armB-loadfirst.yaml;    WANT=0 ;;
  armC) CFGF=armC-loadfirst-p2p.yaml; WANT=1 ;;
  *) echo "ABORT: unknown arm $ARM"; exit 1 ;;
esac

echo "### ARM $ARM c$CONC (tag $TAG) ns=$NS ###"
NS="$NS" ./activate_arm.sh "$ARM"

READY=$(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' --no-headers \
  | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") n++} END {print n+0}')
echo "fleet ready pods: $READY (want $FLEET_EXPECT)"
[ "$READY" -eq "$FLEET_EXPECT" ] || { echo "ABORT: fleet not fully ready"; exit 1; }

FOREIGN=$(kubectl -n "$NS" get jobs -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
act=[j['metadata']['name'] for j in d['items']
     if j['metadata']['name'] != 'weka-$TAG' and (j.get('status',{}).get('active') or 0) > 0]
print(len(act)); [print('  active-foreign:', n, file=sys.stderr) for n in act]")
if [ "$FOREIGN" -gt 0 ] && [ "$ALLOW_FOREIGN" != "1" ]; then
  echo "ABORT: $FOREIGN foreign ACTIVE job(s) present (wait for them or set ALLOW_FOREIGN=1 with justification)"
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
