#!/bin/bash
# Reproduce Maroon's matched c32 precise vs precise+P2P benchmark on the
# nilig-built images (kv-source-endpoint-92e5de82). Uses his ConfigMap
# p2p-benchmark-20260730 (profiles + bench.py) and clones his retained job
# specs with fresh salts. Counterbalanced order as in his doc.
# Scales the fleet to 0 at the end.
set -u
NS=nilig-p2p
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
STAMP=$(date -u +%Y%m%d%H%M)

epp_profile() { # $1 = precise.yaml | precise-p2p.yaml
  local IDX POS CUR
  IDX=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print([i for i,c in enumerate(d['spec']['template']['spec']['containers']) if c['name']=='epp'][0])")
  POS=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'].index('--config-file')+1)")
  CUR=$(kubectl -n $NS get deploy p2p-pd-epp -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
  if [ "$CUR" = "/config/$1" ]; then echo "EPP already on $1"; return 0; fi
  kubectl -n $NS patch deploy p2p-pd-epp --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/$1\"}]" >/dev/null
  kubectl -n $NS rollout status deploy/p2p-pd-epp --timeout=300s >/dev/null 2>&1 || { echo "ABORT: EPP rollout"; return 1; }
  for attempt in 1 2 3 4 5 6; do
    code=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'hi','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://p2p-pd-epp:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=300).status)
except Exception as e: print('ERR',type(e).__name__)" 2>&1 | tail -1)
    [ "$code" = "200" ] && break; sleep 20
  done
  echo "EPP on $1, probe: $code"
  [ "$code" = "200" ]
}

run_rep() { # $1 mode-label (precise|p2p), $2 rep
  local MODE="$1" REP="$2"
  local SRC="p2pbench-balanced-$MODE-r$REP" NEW="p2pbench-repro-$MODE-r$REP"
  kubectl -n $NS get job "$SRC" -o json > "$SP/src-$NEW.json"
  python3 - "$SP/src-$NEW.json" "$NEW" "$REP" "$STAMP" <<'PY' > "$SP/job-$NEW.json"
import json, sys
srcpath, new, rep, stamp = sys.argv[1:5]
d = json.load(open(srcpath))
for k in ('status','ownerReferences'): d.pop(k, None)
meta = {'name': new, 'namespace': d['metadata']['namespace']}
d['metadata'] = meta
d['spec'].pop('selector', None)
d['spec']['template']['metadata'] = {}
c = d['spec']['template']['spec']['containers'][0]
c['args'] = [a if not a.startswith('--salt=') else f"--salt=repro-{stamp}-{new}" for a in c['args']]
json.dump(d, sys.stdout)
PY
  kubectl -n $NS delete job "$NEW" --ignore-not-found >/dev/null 2>&1
  kubectl -n $NS apply -f "$SP/job-$NEW.json" >/dev/null
  kubectl -n $NS wait --for=condition=complete --timeout=900s "job/$NEW" >/dev/null 2>&1 \
    || { echo "REP $NEW DID NOT COMPLETE"; kubectl -n $NS logs "job/$NEW" --tail=10; return 1; }
  kubectl -n $NS logs "job/$NEW" > "$SP/$NEW.log" 2>/dev/null
  grep '^SUMMARY' "$SP/$NEW.log" | tail -1
}

echo "##### MAROON REPRO START $(date -u +%H:%M:%S) #####"
FAILED=""
epp_profile precise.yaml       || FAILED="$FAILED swap1"
run_rep precise 1              || FAILED="$FAILED precise-r1"
epp_profile precise-p2p.yaml   || FAILED="$FAILED swap2"
run_rep p2p 1                  || FAILED="$FAILED p2p-r1"
run_rep p2p 2                  || FAILED="$FAILED p2p-r2"
epp_profile precise.yaml       || FAILED="$FAILED swap3"
run_rep precise 2              || FAILED="$FAILED precise-r2"
run_rep precise 3              || FAILED="$FAILED precise-r3"
epp_profile precise-p2p.yaml   || FAILED="$FAILED swap4"
run_rep p2p 3                  || FAILED="$FAILED p2p-r3"

echo "##### REPRO RUNS DONE failed=[${FAILED:-none}] - scaling fleet to 0 #####"
kubectl -n $NS scale lws wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=0
echo "##### MAROON REPRO COMPLETE $(date -u +%H:%M:%S) #####"
