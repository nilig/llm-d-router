#!/bin/bash
# One GLM wide-EP arm on the upstream tier (no overlay).
# Swaps the EPP's --config-file (editing a key under a running EPP does
# nothing - the arg must change and the EPP must restart), verifies the
# fleet is intact, then runs the 900 s aiperf profile.
# Usage: glm_arm.sh <armB|armC-16k> <tag>
set -u
NS=nilig-p2p
ARM="$1"; TAG="$2"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"

echo "### GLM ARM $ARM (tag $TAG) ###"
kubectl -n $NS patch deploy p2p-pd-epp --type=json \
  -p "$(python3 -c "
import json,sys
print(json.dumps([{'op':'replace','path':'/spec/template/spec/containers/0/args','value':None}]))" >/dev/null 2>&1; echo '[]')" >/dev/null 2>&1 || true
# locate the epp container index and its --config-file position
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
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/${ARM}-plugins.yaml\"}]" >/dev/null
kubectl -n $NS rollout status deploy/p2p-pd-epp --timeout=300s | tail -1
ACTIVE=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
echo "active config: $ACTIVE"
[ "$ACTIVE" = "/config/${ARM}-plugins.yaml" ] || { echo "ABORT: config swap failed"; exit 1; }
# count PLUGIN DECLARATIONS, not comment mentions - armB's prose references
# the producer without configuring it
P2P=$(kubectl -n $NS get cm p2p-pd-epp-plugins-v4 -o json | python3 -c "
import json,sys
body=json.load(sys.stdin)['data']['${ARM}-plugins.yaml']
print(sum(1 for l in body.splitlines() if l.strip().startswith('- type: p2p-source-producer')))")
echo "p2p-source-producer plugins declared: $P2P"

R=$(kubectl -n $NS get pods -l llm-d.ai/model=GLM-5.2-FP8 --no-headers | grep -E "prefill|decode" | grep -cE "3/3 *Running|2/2 *Running")
echo "fleet ready: $R/4"
[ "$R" = "4" ] || { echo "ABORT: fleet not ready"; exit 1; }

for attempt in 1 2 3 4; do
code=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'hi','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://p2p-pd-epp:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=300).status)
except Exception as e: print('ERR',type(e).__name__)
" 2>&1 | tail -1)
echo "probe attempt $attempt: $code"; [ "$code" = "200" ] && break; sleep 20
done
[ "$code" = "200" ] || { echo "ABORT: probe failed"; exit 1; }

python3 - "$TAG" <<'PY'
import json,sys
tag=sys.argv[1]
d=json.load(open('glm-aiperf-job.tmpl.json'))
d['metadata']['name']=f'glm-rerun-{tag}'
c=d['spec']['template']['spec']['containers'][0]
c['args'][0]=c['args'][0].replace('c128-armb', f'rerun-{tag}')
json.dump(d, open(f'glm-job-{tag}.json','w'), indent=1)
PY
kubectl -n $NS delete job glm-rerun-$TAG --ignore-not-found >/dev/null 2>&1
kubectl -n $NS apply -f glm-job-$TAG.json >/dev/null
echo "aiperf job launched (900 s profile); waiting..."
kubectl -n $NS wait --for=condition=complete --timeout=1500s job/glm-rerun-$TAG 2>&1 | tail -1 \
  || { echo "job did not complete"; kubectl -n $NS logs job/glm-rerun-$TAG --tail=20; exit 1; }
JP=$(kubectl -n $NS get pods --no-headers | grep "glm-rerun-$TAG" | awk '{print $1}' | head -1)
kubectl -n $NS logs $JP > "$SP/glm-rerun-$TAG.log" 2>/dev/null
echo "=== summary ==="
grep -iE "time to first token|inter token|request latency|throughput|Benchmark Duration" "$SP/glm-rerun-$TAG.log" | tail -12
S=0
for p in $(kubectl -n $NS get pods -l llm-d.ai/model=GLM-5.2-FP8 -o name | grep -E "prefill|decode"); do
  S=$((S + $(kubectl -n $NS logs $p -c vllm 2>/dev/null | grep -c "created connected session")))
done
echo "p2p sessions (cumulative): $S"
echo "GLM ARM $ARM COMPLETE"
