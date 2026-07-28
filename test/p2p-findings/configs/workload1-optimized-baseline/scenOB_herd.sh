#!/bin/bash
# Herd-recovery A/B: guide-default threshold (18s), P2P absent vs present.
# The herd is reproduced deterministically: precondition a warm, spread fleet,
# then restart the EPP - its empty index against warm engines sends every
# warmup seed (and its index credit) to one pod. Then rate 100 stresses the
# herd and the arms differ only in whether recovery spills can pull.
# Usage: scenOB_herd.sh <values-file> <arm-label> <expect-p2p yes|no> <cfgfile>
set -u
NS=nilig-p2p
VALS="$1"; ARM="$2"; EXPECT="$3"; CFGFILE="$4"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone
EP=http://llm-d-router-epp:8081

echo "### HERD ARM $ARM ###"
helm upgrade llm-d-router "$CHART" -n $NS -f "$SP/$VALS" \
  --server-side=true --force-conflicts > /tmp/_helm_$ARM.log 2>&1 || { echo ABORT-helm; exit 1; }
grep -E "^REVISION" /tmp/_helm_$ARM.log
kubectl rollout restart deploy/llm-d-router-epp -n $NS >/dev/null 2>&1
kubectl delete pod -n $NS -l app=scend-agg --wait=false >/dev/null 2>&1
sleep 20
for i in $(seq 1 90); do
  r=$(kubectl get pods -n $NS -l app=scend-agg --field-selector=status.phase=Running -o json 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(1 for p in d['items'] if p['status'].get('containerStatuses') and all(c['ready'] for c in p['status']['containerStatuses'])))" 2>/dev/null || echo 0)
  epp=$(kubectl get deploy llm-d-router-epp -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "[$i] ready=$r/16 epp=${epp:-0}/1"
  [ "$r" = "16" ] && [ "${epp:-0}" = "1" ] && break
  sleep 20
done
[ "$r" = "16" ] || { echo "ABORT: fleet not ready"; exit 1; }
bash "$SP/arm_gate.sh" "$EXPECT" "$CFGFILE" || exit 1

echo "=== precondition: spread + warm the engine caches (cold engines, rate 24) ==="
kubectl exec -n $NS scenc-loadgen -- sh -c \
  "python3 -u /driver/scenOB_pool.py $EP ${ARM}-pre 24 > /tmp/herd_${ARM}_pre.log 2>&1; echo done"
kubectl exec -n $NS scenc-loadgen -- tail -3 /tmp/herd_${ARM}_pre.log

echo "=== HERD TRIGGER: restart EPP against the warm fleet ==="
kubectl rollout restart deploy/llm-d-router-epp -n $NS >/dev/null 2>&1
kubectl rollout status deploy/llm-d-router-epp -n $NS --timeout=180s >/dev/null 2>&1
bash "$SP/arm_gate.sh" "$EXPECT" "$CFGFILE" || exit 1

echo "=== stress + recovery: rate 100 x 3 stages, sampling distribution ==="
( for i in $(seq 1 12); do python3 "$SP/fleet_sample.py" 1; sleep 15; done ) > "$SP/herd_${ARM}_dist.log" 2>&1 &
DIST=$!
kubectl exec -n $NS scenc-loadgen -- sh -c \
  "nohup python3 -u /driver/scenOB_pool.py $EP $ARM 100,100,100 > /tmp/herd_${ARM}.log 2>&1 & echo started"
last=0
while true; do
  body=$(kubectl exec -n $NS scenc-loadgen -- cat /tmp/herd_${ARM}.log 2>/dev/null)
  n=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
  if [ "$n" -gt "$last" ]; then printf '%s\n' "$body" | tail -n +$((last+1)) | grep -v "^# stage_"; last=$n; fi
  printf '%s' "$body" | grep -q "^# done" && break
  alive=$(kubectl exec -n $NS scenc-loadgen -- sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "scenOB_poo[l].py" && echo x; done; true' 2>/dev/null | wc -l | tr -d ' ')
  [ "${alive:-0}" -gt 0 ] || { echo "LADDER DIED"; break; }
  sleep 20
done
kill $DIST 2>/dev/null
kubectl exec -n $NS scenc-loadgen -- cat /tmp/herd_${ARM}.log > "$SP/herd_${ARM}.log" 2>/dev/null
S=0
for p in $(kubectl get pods -n $NS -l app=scend-agg -o name); do
  S=$((S + $(kubectl logs -n $NS $p -c modelserver 2>/dev/null | grep -c 'created connected session')))
done
echo "sessions(cumulative this engine life)=$S"
echo "ARM $ARM COMPLETE"
