#!/bin/bash
# Screen a candidate seed using only AIPerf's excluded warmup. The Job is
# deleted as soon as warmup passes or a terminal warmup failure appears.
# Usage: screen_seed_warmup.sh <seed>
set -euo pipefail
NS=${NS:-nilig-p2p}
SEED=${1:?usage: screen_seed_warmup.sh <seed>}
SP="$(cd "$(dirname "$0")/.." && pwd)"
TAG="seed-screen-$SEED-$(date +%Y%m%d%H%M%S)"
OUT="$SP/gates/seed-screens/$TAG"
JOB="weka-$TAG"
mkdir -p "$OUT"
cd "$SP"

python3 - "$SEED" "$TAG" "$NS" << 'PY'
import json, sys
seed, tag, ns = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open('workload/blog-campaign-job-c64.json'))
d.pop('status', None)
d['metadata'] = {'name': f'weka-{tag}', 'namespace': ns}
d['spec'].pop('selector', None)
labels = d['spec']['template'].setdefault('metadata', {}).setdefault('labels', {})
for key in list(labels):
    if 'controller-uid' in key or 'job-name' in key:
        labels.pop(key)
spec = d['spec']['template']['spec']
container = spec['containers'][0]
container['args'][-1] = container['args'][-1].replace(
    '--random-seed 42', f'--random-seed {seed}')
env = {entry['name']: entry for entry in container.get('env', [])}
env['URL']['value'] = f'http://p2p-pd-epp.{ns}:8081/v1'
env['SERVER_METRICS_ARGS']['value'] = (
    f'--server-metrics http://p2p-pd-epp.{ns}:9090/metrics')
env['ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/attempt1'
env['CANONICAL_ARTIFACT_DIR']['value'] = f'/workload/weka-{tag}/canonical'
for volume in spec['volumes']:
    if volume.get('persistentVolumeClaim', {}).get('claimName') == 'lustre-pvc-vllm':
        volume['persistentVolumeClaim'] = {'claimName': 'workload-pvc'}
for mount in container.get('volumeMounts', []):
    if mount['mountPath'] == '/mnt/lustre':
        mount['mountPath'] = '/workload'
json.dump(d, open(f'gates/seed-screens/job-{tag}.json', 'w'), indent=1)
PY

cleanup() {
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl -n "$NS" apply -f "$SP/gates/seed-screens/job-$TAG.json" >/dev/null

DEADLINE=$((SECONDS + 360))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  POD=$(kubectl -n "$NS" get pods -l "job-name=$JOB" -o name 2>/dev/null | head -1)
  if [ -n "$POD" ]; then
    LOG=$(kubectl -n "$NS" logs "${POD#pod/}" 2>/dev/null || true)
    if grep -q 'Terminal warmup failure' <<<"$LOG"; then
      printf '%s\n' "$LOG" > "$OUT/aiperf.log"
      grep 'Terminal warmup failure' "$OUT/aiperf.log" | tail -1 | tee "$OUT/result.txt"
      echo "SEED $SEED: FAIL" | tee -a "$OUT/result.txt"
      exit 1
    fi
    if grep -q 'Phase warmup complete.*errors=0' <<<"$LOG"; then
      printf '%s\n' "$LOG" > "$OUT/aiperf.log"
      grep 'Phase warmup complete' "$OUT/aiperf.log" | tail -1 | tee "$OUT/result.txt"
      echo "SEED $SEED: PASS" | tee -a "$OUT/result.txt"
      exit 0
    fi
  fi
  sleep 2
done

echo "SEED $SEED: FAIL - warmup screen timed out" | tee "$OUT/result.txt"
exit 1
