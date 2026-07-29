#!/bin/bash
# One Scenario D arm: switch EPP config, cold-roll the fleet so every arm
# starts from the same cache state, gate, then two back-to-back runs
# (the guide reports run 1 / run 2 per arm).
# Usage: scenD_runarm.sh <values-file> <arm-label> <expect-p2p yes|no>
set -u
NS=nilig-p2p
VALS="$1"; ARM="$2"; EXPECT="$3"; CFGFILE="$4"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone
EP=http://llm-d-router-epp:8081

echo "### SCENARIO A ARM $ARM ###"
if ! helm upgrade llm-d-router "$CHART" -n $NS -f "$SP/$VALS" \
     --server-side=true --force-conflicts > /tmp/_helm_$ARM.log 2>&1; then
  echo "ABORT: helm upgrade failed for $ARM"; tail -5 /tmp/_helm_$ARM.log; exit 1
fi
grep -E "^REVISION|^STATUS" /tmp/_helm_$ARM.log
kubectl rollout restart deploy/llm-d-router-epp -n $NS >/dev/null 2>&1
# the gpu-pruner scales idle deployments to 0; restore before waiting
kubectl scale deploy scend-agg -n $NS --replicas=16 >/dev/null 2>&1
kubectl delete pod -n $NS -l app=scend-agg --wait=false >/dev/null 2>&1
sleep 20

for i in $(seq 1 90); do
  r=$(kubectl get pods -n $NS -l app=scend-agg --field-selector=status.phase=Running -o json 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(1 for p in d['items'] if p['status'].get('containerStatuses') and all(c['ready'] for c in p['status']['containerStatuses'])))" 2>/dev/null || echo 0)
  epp=$(kubectl get deploy llm-d-router-epp -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "[$i] scend-agg ready=$r/16 epp=${epp:-0}/1"
  [ "$r" = "16" ] && [ "${epp:-0}" = "1" ] && break
  sleep 20
done
[ "$r" = "16" ] || { echo "ABORT: fleet not ready"; exit 1; }

echo "=== arm gate (active --config-file only) ==="
bash "$SP/arm_gate.sh" "$EXPECT" "$CFGFILE" || exit 1

echo "=== warm probe ==="
code=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'openai/gpt-oss-120b','messages':[{'role':'user','content':'hi'}],'max_tokens':4}).encode()
r=urllib.request.Request('$EP/v1/chat/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=180).status)
except Exception as e: print('ERR',type(e).__name__)
" 2>&1 | tail -1)
echo "probe: $code"
[ "$code" = "200" ] || { echo "ABORT: probe failed"; exit 1; }

for run in 1; do
  echo "=== $ARM run $run ==="
  kubectl exec -n $NS scenc-loadgen -- sh -c \
    "nohup python3 -u /driver/scenC_ladder.py $EP ${ARM} 6,12,18,24,30 > /tmp/${ARM}.log 2>&1 & echo started"
  last=0
  while true; do
    body=$(kubectl exec -n $NS scenc-loadgen -- cat /tmp/${ARM}.log 2>/dev/null)
    n=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
    if [ "$n" -gt "$last" ]; then printf '%s\n' "$body" | tail -n +$((last+1)); last=$n; fi
    printf '%s' "$body" | grep -q "^# done" && break
    alive=$(kubectl exec -n $NS scenc-loadgen -- sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "scenC_ladde[r].py" && echo x; done; true' 2>/dev/null | wc -l | tr -d ' ')
    [ "${alive:-0}" -gt 0 ] || { echo "RUN ENDED without done marker"; break; }
    sleep 30
  done
  kubectl exec -n $NS scenc-loadgen -- cat /tmp/${ARM}.log > "scenA_${ARM}.log" 2>/dev/null
done
echo "ARM $ARM COMPLETE"
