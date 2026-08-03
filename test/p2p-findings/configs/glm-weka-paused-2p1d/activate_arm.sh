#!/bin/bash
# Activate one arm: swap the EPP --config-file (the arg change forces the
# restart a ConfigMap-only edit silently skips), then verify the active
# config and the producer declaration count. No workload is started.
# Shared by run_arm.sh and gates/armC_probe.sh.
# Usage: activate_arm.sh <blog-approximate|blog-approximate-p2p|
# blog-precise|blog-precise-p2p>
set -euo pipefail
NS=${NS:-nilig-p2p}
ARM="$1"

case "$ARM" in
  blog-approximate) CFGF=blog-approximate.yaml; WANT=0; PRECISE=0 ;;
  blog-approximate-p2p-fitted) CFGF=blog-approximate-p2p-fitted.yaml; WANT=1; PRECISE=0 ;;
  blog-approximate-p2p) CFGF=blog-approximate-p2p.yaml; WANT=1; PRECISE=0 ;;
  blog-precise) CFGF=blog-precise.yaml; WANT=0; PRECISE=1 ;;
  blog-precise-p2p) CFGF=blog-precise-p2p.yaml; WANT=1; PRECISE=1 ;;
  armA) CFGF=armA-blog-plugins.yaml; WANT=0; PRECISE=0 ;;
  precise-no-p2p|armB) CFGF=armB-loadfirst.yaml; WANT=0; PRECISE=1 ;;
  precise-p2p|armC) CFGF=armC-loadfirst-p2p.yaml; WANT=1; PRECISE=1 ;;
  *) echo "ABORT: unknown configuration $ARM"; exit 1 ;;
esac

# the campaign ConfigMap and the arm's key must exist before any
# --config-file change, or the rollout ships an EPP that cannot start
KEY_OK=$(kubectl -n "$NS" get cm p2p-weka-epp-plugins -o json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)['data']
except Exception: print('NO_CM'); raise SystemExit
print('OK' if '$CFGF' in d else 'NO_KEY')" || echo NO_CM)
[ "$KEY_OK" = "OK" ] || { echo "ABORT: p2p-weka-epp-plugins/$ARM key check: $KEY_OK (run install_epp_configmap.sh first)"; exit 1; }
MOUNTED=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
spec=d['spec']['template']['spec']
mn=None
for c in spec['containers']:
    if c['name']=='epp':
        for m in c.get('volumeMounts',[]):
            if m['mountPath']=='/config': mn=m['name']
for v in spec.get('volumes',[]):
    if v['name']==mn: print(v.get('configMap',{}).get('name',''))")
[ "$MOUNTED" = "p2p-weka-epp-plugins" ] || { echo "ABORT: EPP /config volume backed by '$MOUNTED' (run install_epp_configmap.sh first)"; exit 1; }

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
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/$CFGF\"}]" >/dev/null
kubectl -n "$NS" rollout status deploy/p2p-pd-epp --timeout=300s | tail -1

ACTIVE=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
[ "$ACTIVE" = "/config/$CFGF" ] || { echo "ABORT: config swap failed (active=$ACTIVE)"; exit 1; }

P2P=$(kubectl -n "$NS" get cm p2p-weka-epp-plugins -o json | python3 -c "
import json,sys
body=json.load(sys.stdin)['data']['$CFGF']
print(sum(1 for l in body.splitlines() if l.strip().startswith('- type: p2p-source-producer')))")
echo "arm $ARM active; p2p-source-producer declared: $P2P (want $WANT)"
[ "$P2P" = "$WANT" ] || { echo "ABORT: producer declaration mismatch"; exit 1; }

# every B/C swap restarts the EPP, so its precise-index subscriptions must
# be re-proven live before any measurement; armA is approximate and skips
if [ "$PRECISE" = "1" ]; then
  NS="$NS" bash "$(dirname "$0")/gates/wait_precise_subscriptions.sh" \
    "$(dirname "$0")/gates/subscriptions/subs-$ARM-$(date +%Y%m%d%H%M%S)" \
    || { echo "ABORT: precise subscriptions incomplete after $ARM activation"; exit 1; }
fi
