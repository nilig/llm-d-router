#!/bin/bash
# Install the campaign's EPP ConfigMap and point the EPP at it. Run once
# before the first activate_arm.sh. Fails closed.
#
# Creates/updates `p2p-weka-epp-plugins` from the three arm files,
# verifies all three keys, switches the EPP deployment's config volume to
# the new ConfigMap, and waits for the rollout. Does NOT change
# --config-file: activation stays with activate_arm.sh.
set -euo pipefail
NS=${NS:-nilig-p2p}
CM=p2p-weka-epp-plugins
SP="$(cd "$(dirname "$0")" && pwd)"

kubectl -n "$NS" create configmap "$CM" \
  --from-file=armA-blog-plugins.yaml="$SP/epp/armA-blog-plugins.yaml" \
  --from-file=armB-loadfirst.yaml="$SP/epp/armB-loadfirst.yaml" \
  --from-file=armC-loadfirst-p2p.yaml="$SP/epp/armC-loadfirst-p2p.yaml" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

KEYS=$(kubectl -n "$NS" get cm "$CM" -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
want={'armA-blog-plugins.yaml','armB-loadfirst.yaml','armC-loadfirst-p2p.yaml'}
missing=want-set(d)
print('OK' if not missing else 'MISSING:'+','.join(sorted(missing)))")
[ "$KEYS" = "OK" ] || { echo "ABORT: ConfigMap keys $KEYS"; exit 1; }

# switch whichever volume backs the /config mount to the campaign ConfigMap
VOL=$(kubectl -n "$NS" get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
spec=d['spec']['template']['spec']
mount_name=None
for c in spec['containers']:
    if c['name']!='epp': continue
    for m in c.get('volumeMounts',[]):
        if m['mountPath']=='/config': mount_name=m['name']
for i,v in enumerate(spec.get('volumes',[])):
    if v['name']==mount_name:
        print(i, v.get('configMap',{}).get('name',''))")
IDX=${VOL% *}; OLD=${VOL#* }
[ -n "$IDX" ] || { echo "ABORT: could not locate the /config volume"; exit 1; }
echo "config volume index $IDX currently backed by '$OLD'"
if [ "$OLD" != "$CM" ]; then
  kubectl -n "$NS" patch deploy p2p-pd-epp --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/$IDX/configMap/name\",\"value\":\"$CM\"}]"
  kubectl -n "$NS" rollout status deploy/p2p-pd-epp --timeout=300s | tail -1
fi

# verify via the API (the image is distroless - no exec): the READY pod's
# /config volume must resolve to the campaign ConfigMap; the key check
# above already proved the ConfigMap's contents
POD_CM=$(kubectl -n "$NS" get pods -l app=p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for pod in d['items']:
    st=pod.get('status',{})
    ready=any(c.get('type')=='Ready' and c.get('status')=='True'
              for c in st.get('conditions',[]))
    if not ready: continue
    spec=pod['spec']
    mn=None
    for c in spec['containers']:
        if c['name']=='epp':
            for m in c.get('volumeMounts',[]):
                if m['mountPath']=='/config': mn=m['name']
    for v in spec.get('volumes',[]):
        if v['name']==mn:
            print(v.get('configMap',{}).get('name',''))
            raise SystemExit
print('')")
[ "$POD_CM" = "$CM" ] || { echo "ABORT: ready EPP pod's /config volume resolves to '$POD_CM', want $CM"; exit 1; }
echo "EPP ConfigMap installed and mounted by the ready pod; use activate_arm.sh to select an arm"
