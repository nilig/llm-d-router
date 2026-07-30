#!/bin/bash
# Fair approx c32 pair, v2 - single-deployment harness per codex review.
# EPP_DEPLOY/EPP_SERVICE are the SAME object; every cloned job's --url is
# rewritten to EPP_SERVICE; per-rep assertions: active config == arm, job
# URL == service, streamed-log pod belongs to the deployment; a rep is
# REJECTED unless its streamed EPP log carries >= 99 distinct request IDs.
# A one-shot mechanism probe (seed 70K -> repeat -> bestCachedTokens > 0)
# gates the campaign. Scales the fleet to 0 at the end.
set -u
NS=nilig-p2p
EPP_DEPLOY=p2p-pd-epp
EPP_SERVICE=p2p-pd-epp
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
STAMP=$(date -u +%Y%m%d%H%M)
EPP_POD=""

resolve_epp_pod() {
  local SEL
  SEL=$(kubectl -n $NS get deploy $EPP_DEPLOY -o json | python3 -c "
import json,sys
m=json.load(sys.stdin)['spec']['selector']['matchLabels']
print(','.join(f'{k}={v}' for k,v in m.items()))")
  EPP_POD=$(kubectl -n $NS get pods -l "$SEL" --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
  [ -n "$EPP_POD" ]
}

epp_profile() { # $1 = profile yaml key
  local IDX POS CUR
  IDX=$(kubectl -n $NS get deploy $EPP_DEPLOY -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print([i for i,c in enumerate(d['spec']['template']['spec']['containers']) if c['name']=='epp'][0])")
  POS=$(kubectl -n $NS get deploy $EPP_DEPLOY -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'].index('--config-file')+1)")
  CUR=$(kubectl -n $NS get deploy $EPP_DEPLOY -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][$IDX]
print(c['args'][c['args'].index('--config-file')+1])")
  if [ "$CUR" != "/config/$1" ]; then
    kubectl -n $NS patch deploy $EPP_DEPLOY --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/$IDX/args/$POS\",\"value\":\"/config/$1\"}]" >/dev/null
    kubectl -n $NS rollout status deploy/$EPP_DEPLOY --timeout=300s >/dev/null 2>&1 || { echo "ABORT: EPP rollout for $1"; return 1; }
  fi
  resolve_epp_pod || { echo "ABORT: no running EPP pod"; return 1; }
  local code
  for attempt in 1 2 3 4 5 6; do
    code=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'hi','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://$EPP_SERVICE:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=300).status)
except Exception as e: print('ERR',type(e).__name__)" 2>&1 | tail -1)
    [ "$code" = "200" ] && break; sleep 20
  done
  echo "EPP($EPP_DEPLOY) on $1, pod $EPP_POD, probe: $code"
  [ "$code" = "200" ]
}

assert_arm() { # $1 expected profile
  local CUR
  CUR=$(kubectl -n $NS get deploy $EPP_DEPLOY -o json | python3 -c "
import json,sys
c=[c for c in json.load(sys.stdin)['spec']['template']['spec']['containers'] if c['name']=='epp'][0]
print(c['args'][c['args'].index('--config-file')+1])")
  [ "$CUR" = "/config/$1" ] || { echo "ASSERT FAIL: active config $CUR != /config/$1"; return 1; }
}

mechanism_probe() {
  echo "--- mechanism probe on fair-approx-p2p (seed 70K -> repeat -> bestCachedTokens>0)"
  epp_profile fair-approx-p2p.yaml || return 1
  kubectl -n $NS logs -f "$EPP_POD" -c epp > "$SP/probe-epp.jsonl" 2>/dev/null &
  local LOGPID=$!
  local SALT="probe-$STAMP"
  for round in seed repeat; do
    kubectl exec -n $NS scenc-loadgen -- env SALT="$SALT" python3 -c "
import urllib.request,json,os
prompt = os.environ['SALT'] + ' ' + ('juniper basalt aurora pistachio garnet willow cobalt drift ' * 8750) + ' Reply with exactly OK'
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':prompt,'max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://$EPP_SERVICE:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
resp=urllib.request.urlopen(r,timeout=600)
body=json.loads(resp.read())
print('probe', resp.status, body.get('usage',{}).get('prompt_tokens'))" 2>&1 | tail -1
  done
  sleep 3; kill $LOGPID 2>/dev/null
  local BEST
  BEST=$(python3 - "$SP/probe-epp.jsonl" <<'PY'
import json,sys
best=0
for line in open(sys.argv[1]):
    try: d=json.loads(line)
    except: continue
    if d.get('msg')=='Produce completed' and 'bestCachedTokens' in d:
        best=max(best,int(d.get('bestCachedTokens') or 0))
print(best)
PY
)
  echo "MECHANISM PROBE bestCachedTokens=$BEST"
  [ "$BEST" -gt 0 ] || { echo "MECHANISM PROBE FAILED: approx index credited nothing on repeat"; return 1; }
}

run_rep() { # $1 mode-label, $2 src-job name, $3 rep, $4 expected profile
  local MODE="$1" SRC="$2" REP="$3" PROFILE="$4"
  local NEW="p2pbench-fair3-$MODE-r$REP"
  assert_arm "$PROFILE" || return 1
  resolve_epp_pod || return 1
  kubectl -n $NS get job "$SRC" -o json > "$SP/src-$NEW.json"
  python3 - "$SP/src-$NEW.json" "$NEW" "$STAMP" "$MODE" "$EPP_SERVICE" "$NS" <<'PY' > "$SP/job-$NEW.json"
import json, sys
srcpath, new, stamp, mode, svc, ns = sys.argv[1:7]
d = json.load(open(srcpath))
d.pop('status', None)
d['metadata'] = {'name': new, 'namespace': ns}
d['spec'].pop('selector', None)
d['spec']['template']['metadata'] = {}
c = d['spec']['template']['spec']['containers'][0]
args = []
for a in c['args']:
    if a.startswith('--salt='): a = f"--salt={stamp}-{new}"
    elif a.startswith('--mode='): a = f"--mode={mode}-c32"
    elif a.startswith('--repetition='): a = f"--repetition={new.rsplit('-r',1)[1]}"
    elif a.startswith('--url='): a = f"--url=http://{svc}.{ns}:8081"
    args.append(a)
c['args'] = args
assert any(a == f"--url=http://{svc}.{ns}:8081" for a in c['args']), "url rewrite failed"
json.dump(d, sys.stdout)
PY
  grep -q -- "--url=http://$EPP_SERVICE.$NS:8081" "$SP/job-$NEW.json" || { echo "ASSERT FAIL: job url != $EPP_SERVICE"; return 1; }
  kubectl -n $NS logs -f "$EPP_POD" -c epp > "$SP/epplog-$NEW.jsonl" 2>/dev/null &
  local LOGPID=$!
  kubectl -n $NS delete job "$NEW" --ignore-not-found >/dev/null 2>&1
  kubectl -n $NS apply -f "$SP/job-$NEW.json" >/dev/null
  local RC=0
  kubectl -n $NS wait --for=condition=complete --timeout=900s "job/$NEW" >/dev/null 2>&1 || RC=1
  kubectl -n $NS logs "job/$NEW" > "$SP/$NEW.log" 2>/dev/null
  sleep 3; kill $LOGPID 2>/dev/null
  if [ "$RC" != "0" ]; then echo "REP $NEW DID NOT COMPLETE"; return 1; fi
  local IDS HDRS
  IDS=$(python3 - "$SP/epplog-$NEW.jsonl" <<'PY'
import json,sys
ids=set()
for line in open(sys.argv[1]):
    try: d=json.loads(line)
    except: continue
    rid=d.get('x-request-id')
    if rid and d.get('msg')=='Produce completed': ids.add(rid)
print(len(ids))
PY
)
  HDRS=$(grep -c 'set KV cache source header' "$SP/epplog-$NEW.jsonl" 2>/dev/null; true)
  if [ "$IDS" -lt 99 ]; then echo "REP $NEW REJECTED: only $IDS request IDs in streamed EPP log (need >=99)"; return 1; fi
  grep '^SUMMARY' "$SP/$NEW.log" | tail -1
  echo "MECHV2 $NEW ids=$IDS headers=${HDRS:-0}"
}

echo "##### FAIR-APPROX V2 START $(date -u +%H:%M:%S) #####"
mechanism_probe || { echo "##### CAMPAIGN SKIPPED: mechanism probe failed - approx question answered #####"; \
  kubectl -n $NS scale lws wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=0; exit 1; }

FAILED=""
epp_profile fair-approx.yaml || FAILED="$FAILED swapA1"
run_rep fair-approx p2pbench-fair-approx-r1 1 fair-approx.yaml         || FAILED="$FAILED a1"
epp_profile fair-approx-p2p.yaml || FAILED="$FAILED swapAp1"
run_rep fair-approx-p2p p2pbench-fair-approx-r1 1 fair-approx-p2p.yaml || FAILED="$FAILED ap1"
run_rep fair-approx-p2p p2pbench-fair-approx-r1 2 fair-approx-p2p.yaml || FAILED="$FAILED ap2"
epp_profile fair-approx.yaml || FAILED="$FAILED swapA2"
run_rep fair-approx p2pbench-fair-approx-r1 2 fair-approx.yaml         || FAILED="$FAILED a2"
run_rep fair-approx p2pbench-fair-approx-r1 3 fair-approx.yaml         || FAILED="$FAILED a3"
epp_profile fair-approx-p2p.yaml || FAILED="$FAILED swapAp2"
run_rep fair-approx-p2p p2pbench-fair-approx-r1 3 fair-approx-p2p.yaml || FAILED="$FAILED ap3"

echo "##### FAIR-APPROX V2 RUNS DONE failed=[${FAILED:-none}] - scaling fleet to 0 #####"
kubectl -n $NS scale lws wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=0
echo "##### FAIR-APPROX V2 COMPLETE $(date -u +%H:%M:%S) #####"
