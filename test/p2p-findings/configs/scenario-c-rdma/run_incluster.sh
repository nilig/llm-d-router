#!/bin/bash
# Run a Scenario C ladder from an in-cluster pod (no port-forward).
# Usage: run_incluster.sh <arm-label> <expect-p2p yes|no> <rates_csv>
set -u
NS=nilig-p2p
ARM="$1"; EXPECT="$2"; RATES="$3"
cd "$(dirname "$0")"
EP=http://llm-d-router-epp:8081

count_ready() {
  kubectl get pods -n $NS -l "app=scenc,role=$1" --field-selector=status.phase=Running -o json 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(1 for p in d['items'] if p['status'].get('containerStatuses') and all(c['ready'] for c in p['status']['containerStatuses'])))" 2>/dev/null || echo 0
}
for i in $(seq 1 90); do
  pf=$(count_ready prefill); dc=$(count_ready decode)
  epp=$(kubectl get deploy llm-d-router-epp -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "[$i] prefill=$pf/8 decode=$dc/8 epp=${epp:-0}/1"
  [ "$pf" = "8" ] && [ "$dc" = "8" ] && [ "${epp:-0}" = "1" ] && break
  sleep 20
done
[ "$pf" = "8" ] && [ "$dc" = "8" ] || { echo "ABORT: fleets not ready"; exit 1; }

echo "=== restart counts (expect all 0) ==="
kubectl get pods -n $NS -l app=scenc -o json | python3 -c "import json,sys;print([p['status']['containerStatuses'][0]['restartCount'] for p in json.load(sys.stdin)['items']])"

echo "=== arm gate ==="
bash arm_gate.sh "$EXPECT" || exit 1

echo "=== in-cluster P/D roundtrip ==="
for i in 1 2 3 4 5; do
  out=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json,time
t=time.time()
b=json.dumps({'model':'openai/gpt-oss-120b','prompt':'hello there friend','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('$EP/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print('OK', urllib.request.urlopen(r,timeout=120).status, round(time.time()-t,1))
except Exception as e: print('ERR', type(e).__name__, str(e)[:80])
" 2>&1 | tail -1)
  echo "  probe $i: $out"
  echo "$out" | grep -q "^OK 200" && break
  sleep 20
done
echo "$out" | grep -q "^OK 200" || { echo "ABORT: roundtrip broken"; exit 1; }

echo "=== ladder (in-cluster, arm=$ARM rates=$RATES) ==="
kubectl exec -n $NS scenc-loadgen -- sh -c \
  "nohup python3 -u /driver/scenC_ladder.py $EP $ARM $RATES > /tmp/$ARM.log 2>&1 & echo started"
last=0
while true; do
  body=$(kubectl exec -n $NS scenc-loadgen -- cat /tmp/$ARM.log 2>/dev/null)
  n=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
  if [ "$n" -gt "$last" ]; then printf '%s\n' "$body" | tail -n +$((last+1)); last=$n; fi
  printf '%s' "$body" | grep -q "^# done" && break
  # python:3.12-slim has no procps, so pgrep is unavailable - scan /proc instead.
  alive=$(kubectl exec -n $NS scenc-loadgen -- sh -c \
    'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q scenC_ladder && echo x; done; true' 2>/dev/null | wc -l | tr -d ' ')
  [ "${alive:-0}" -gt 0 ] || { echo "LADDER DIED"; break; }
  sleep 30
done
kubectl exec -n $NS scenc-loadgen -- cat /tmp/$ARM.log > "scenC_$ARM.log" 2>/dev/null
echo "LADDER COMPLETE ($ARM)"
