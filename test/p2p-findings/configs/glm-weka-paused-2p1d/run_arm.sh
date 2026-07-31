#!/bin/bash
# One campaign arm: swap the EPP --config-file (arg change forces restart),
# verify the active config and producer declarations, gate the fleet, then
# run the recovered blog-campaign aiperf invocation.
# Usage: run_arm.sh <armA|armB|armC> <concurrency> <tag>
set -u
NS=${NS:-nilig-p2p}
ARM="$1"; CONC="$2"; TAG="$3"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"

declare -A CFG=( [armA]=armA-blog-plugins.yaml [armB]=armB-loadfirst.yaml [armC]=armC-loadfirst-p2p.yaml )
declare -A WANT_P2P=( [armA]=0 [armB]=0 [armC]=1 )

echo "### ARM $ARM c$CONC (tag $TAG) ###"
IDX=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i,c in enumerate(d['spec']['template']['spec']['containers']):
    if c['name']=='epp': print(i)")
POS=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'].index('--config-file')+1)")
kubectl -n $NS patch deploy p2p-pd-epp --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/${CFG[$ARM]}\"}]" >/dev/null
kubectl -n $NS rollout status deploy/p2p-pd-epp --timeout=300s | tail -1

ACTIVE=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
[ "$ACTIVE" = "/config/${CFG[$ARM]}" ] || { echo "ABORT: config swap failed"; exit 1; }

P2P=$(kubectl -n $NS get cm p2p-weka-epp-plugins -o json | python3 -c "
import json,sys
body=json.load(sys.stdin)['data']['${CFG[$ARM]}']
print(sum(1 for l in body.splitlines() if l.strip().startswith('- type: p2p-source-producer')))")
echo "p2p-source-producer declared: $P2P (want ${WANT_P2P[$ARM]})"
[ "$P2P" = "${WANT_P2P[$ARM]}" ] || { echo "ABORT: producer declaration mismatch"; exit 1; }

# fleet: 2 prefill pods + 2 decode pods, all Running/ready
R=$(kubectl -n $NS get pods -l llm-d.ai/model --no-headers | grep -cE "Running")
echo "fleet running pods: $R"

# concurrent-operator check: no foreign jobs/rollouts in flight
FOREIGN=$(kubectl -n $NS get jobs --no-headers 2>/dev/null | grep -vc "weka-$TAG" || true)
echo "other jobs present: $FOREIGN (review before trusting the arm)"

# warm probe through the EPP
for attempt in 1 2 3 4; do
  code=$(kubectl -n $NS exec scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'hi','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://p2p-pd-epp:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=300).status)
except Exception as e: print('ERR',type(e).__name__)" 2>&1 | tail -1)
  echo "probe $attempt: $code"; [ "$code" = "200" ] && break; sleep 20
done
[ "$code" = "200" ] || { echo "ABORT: probe failed"; exit 1; }

# counter snapshot before
kubectl -n $NS exec scenc-loadgen -- sh -c \
  'for u in $(getent hosts p2p-pd-epp | head -1); do :; done; true' 2>/dev/null
./snap_counters.sh "$SP/snap-$TAG-before.txt" || true

# the recovered blog-campaign invocation (see workload/README.md), with
# AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1 and seed 42; only
# --concurrency varies across cells.
python3 - "$TAG" "$CONC" << 'PY'
import json, sys
tag, conc = sys.argv[1], sys.argv[2]
d = json.load(open('workload/blog-campaign-job-c64.json'))
for k in ('status','managedFields','resourceVersion','uid','creationTimestamp','generation','selfLink'):
    d.get('metadata',{}).pop(k, None)
d.pop('status', None)
d['metadata'] = {'name': f'weka-{tag}', 'namespace': 'nilig-p2p'}
d['spec'].pop('selector', None)
d['spec']['template']['metadata'].get('labels',{}).pop('batch.kubernetes.io/controller-uid', None)
d['spec']['template']['metadata'].get('labels',{}).pop('controller-uid', None)
d['spec']['template']['metadata'].get('labels',{}).pop('batch.kubernetes.io/job-name', None)
d['spec']['template']['metadata'].get('labels',{}).pop('job-name', None)
spec = d['spec']['template']['spec']
c = spec['containers'][0]
c['args'][-1] = c['args'][-1].replace('--concurrency 64', f'--concurrency {conc}')
env = {e['name']: e for e in c.get('env', [])}
env['URL']['value'] = 'http://p2p-pd-epp.nilig-p2p:8081/v1'
env['SERVER_METRICS_ARGS']['value'] = '--server-metrics http://p2p-pd-epp.nilig-p2p:9090/metrics'
env['ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/attempt1'
env['CANONICAL_ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/canonical'
# our namespace's RWX PVC replaces their lustre claim
for v in spec['volumes']:
    if v.get('persistentVolumeClaim',{}).get('claimName') == 'lustre-pvc-vllm':
        v['persistentVolumeClaim']['claimName'] = 'workload-pvc'
        v['name'] = v['name']
for m in c.get('volumeMounts', []):
    if m['mountPath'] == '/mnt/lustre':
        m['mountPath'] = '/workload'
# ARTIFACT_DIR paths must live under the new mount
env['ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/attempt1'
env['CANONICAL_ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/canonical'
json.dump(d, open(f'weka-job-{tag}.json','w'), indent=1)
PY
kubectl -n $NS delete job weka-$TAG --ignore-not-found >/dev/null 2>&1
kubectl -n $NS apply -f weka-job-$TAG.json >/dev/null
echo "aiperf job weka-$TAG launched (900 s); waiting..."
kubectl -n $NS wait --for=condition=complete --timeout=1800s job/weka-$TAG 2>&1 | tail -1 \
  || { echo "job did not complete"; kubectl -n $NS logs job/weka-$TAG --tail=20; exit 1; }
JP=$(kubectl -n $NS get pods --no-headers | grep "weka-$TAG" | awk '{print $1}' | head -1)
kubectl -n $NS logs $JP > "$SP/weka-$TAG.log" 2>/dev/null
./snap_counters.sh "$SP/snap-$TAG-after.txt" || true
echo "=== summary ==="
grep -iE "error|fail" "$SP/weka-$TAG.log" | head -3
grep -iE "time to first token|inter token|request latency|throughput|Benchmark Duration|request count" "$SP/weka-$TAG.log" | tail -12
