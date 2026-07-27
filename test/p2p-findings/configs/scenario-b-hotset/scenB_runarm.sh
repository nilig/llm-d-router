#!/bin/bash
# Run one Scenario B arm end to end: switch EPP (with the mandatory rollout
# restart), cold-reroll scenb-agg (clears GPU KV + CPU offload tier so no
# residual cache from the previous arm leaks into this one's measurement -
# same reasoning as scenC_runarm.sh's prefill reroll), wait, gate, ladder.
#
# Usage: scenB_runarm.sh <values-file> <arm-label> <expect-p2p yes|no>
set -u
VALS="$1"; ARM="$2"; EXPECT="$3"
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a15368a9-23b2-44c8-b692-6e900f79144b/scratchpad
FWT="$SP/findings-wt/test/p2p-findings/configs/scenario-b-hotset"
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone

echo "### ARM $ARM ###"
helm upgrade llm-d-router "$CHART" -n nilig-p2p -f "$FWT/$VALS" \
  --server-side=true --force-conflicts 2>&1 | grep -E "^REVISION|^STATUS"
# EPP reads plugin config once at startup; a ConfigMap-only upgrade does NOT
# restart it, so the arm would silently not change without this.
kubectl rollout restart deploy/llm-d-router-epp -n nilig-p2p >/dev/null 2>&1
kubectl delete pod -n nilig-p2p -l app=scenb-agg --wait=false >/dev/null 2>&1

echo "waiting for cold scenb-agg + epp..."
while true; do
  out=$(kubectl get pods -n nilig-p2p -l app=scenb-agg -o json 2>/dev/null)
  ready=$(echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for p in d['items'] if all(c['ready'] for c in p['status'].get('containerStatuses',[]))))
" 2>/dev/null)
  bad=$(echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bad=[]
for p in d['items']:
    for c in p['status'].get('containerStatuses',[]):
        if c.get('restartCount',0) > 0: bad.append(p['metadata']['name']+':restart='+str(c['restartCount']))
        w = c.get('state',{}).get('waiting',{})
        if w.get('reason') in ('CrashLoopBackOff','ImagePullBackOff','ErrImagePull','Error'):
            bad.append(p['metadata']['name']+':'+w['reason'])
print(';'.join(bad))
" 2>/dev/null)
  epp=$(kubectl get deploy llm-d-router-epp -n nilig-p2p -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "$(date +%H:%M:%S) scenb-agg ready=$ready/16 epp=${epp:-0} bad=[$bad]"
  if [ -n "$bad" ]; then echo "CRASH SIGNATURE DETECTED - aborting"; exit 1; fi
  [ "$ready" = "16" ] && [ "${epp:-0}" = "1" ] && break
  sleep 20
done

# assert the EPP actually loaded this arm - iterate every EPP pod explicitly
# (kubectl logs -l returns only a subset, never conclude "correct" from it).
GOTP2P=0
for EPP in $(kubectl get pods -n nilig-p2p -l llm-d-router-gateway=llm-d-router-epp -o name | cut -d/ -f2); do
  c=$(kubectl logs -n nilig-p2p "$EPP" -c epp 2>/dev/null | grep -c 'p2p-source-producer')
  GOTP2P=$((GOTP2P + c))
done
if { [ "$EXPECT" = yes ] && [ "$GOTP2P" -eq 0 ]; } || { [ "$EXPECT" = no ] && [ "$GOTP2P" -gt 0 ]; }; then
  echo "GATE FAIL: expected p2p=$EXPECT but loaded config has $GOTP2P occurrences across EPP pods"; exit 1
fi
echo "gate: epp loaded arm correctly (p2p-source-producer=$GOTP2P occurrences, expect $EXPECT)"

pkill -f "port-forward -n nilig-p2p svc/llm-d-router-epp" 2>/dev/null
sleep 2
nohup kubectl port-forward -n nilig-p2p svc/llm-d-router-epp 18096:8081 > "$SP/pf-scenb.log" 2>&1 &
sleep 5
python3 "$FWT/scenB_hotset.py" http://localhost:18096 "$ARM" 12,24,36,48 2>&1 | tee "$SP/scenB_$ARM.log"
echo "--- pull mechanism spot-check (INFO-level session log, all pods, no v:5/DEBUG needed) ---"
SESS=0
for POD in $(kubectl get pods -n nilig-p2p -l app=scenb-agg -o name | cut -d/ -f2); do
  n=$(kubectl logs -n nilig-p2p "$POD" -c modelserver 2>/dev/null | grep -c "created connected session for")
  SESS=$((SESS + n))
done
echo "total 'created connected session' occurrences across all 16 pods: $SESS"
