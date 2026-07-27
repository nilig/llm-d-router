#!/bin/bash
# Run one Scenario C arm end to end: switch EPP (with the mandatory rollout
# restart), re-roll prefill cold, wait, warm up, gate, then ladder.
#
# Usage: scenC_runarm.sh <values-file> <arm-label> <expect-p2p yes|no>
set -u
VALS="$1"; ARM="$2"; EXPECT="$3"
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a15368a9-23b2-44c8-b692-6e900f79144b/scratchpad
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone

echo "### ARM $ARM ###"
helm upgrade llm-d-router "$CHART" -n nilig-p2p -f "$SP/$VALS" \
  --server-side=true --force-conflicts 2>&1 | grep -E "^REVISION|^STATUS"
# EPP reads plugin config once at startup; a ConfigMap-only upgrade does NOT
# restart it, so the arm would silently not change without this.
kubectl rollout restart deploy/llm-d-router-epp -n nilig-p2p >/dev/null 2>&1
kubectl delete pod -n nilig-p2p -l app=scenc,role=prefill --wait=false >/dev/null 2>&1

echo "waiting for cold prefill + epp..."
while true; do
  pf=$(kubectl get pods -n nilig-p2p -l app=scenc,role=prefill --field-selector=status.phase=Running -o json 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(1 for p in d['items'] if p['status'].get('containerStatuses') and all(c['ready'] for c in p['status']['containerStatuses'])))")
  n=$(kubectl get pods -n nilig-p2p -l app=scenc,role=prefill --no-headers 2>/dev/null | wc -l | tr -d ' ')
  epp=$(kubectl get deploy llm-d-router-epp -n nilig-p2p -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$pf" = "8" ] && [ "$n" = "8" ] && [ "${epp:-0}" = "1" ] && break
  sleep 20
done

# assert the EPP actually loaded this arm
EPP=$(kubectl get pods -n nilig-p2p -o name | grep llm-d-router-epp | head -1 | cut -d/ -f2)
GOT=$(kubectl logs -n nilig-p2p "$EPP" -c epp 2>/dev/null | grep -c 'p2p-source-producer')
if { [ "$EXPECT" = yes ] && [ "$GOT" -eq 0 ]; } || { [ "$EXPECT" = no ] && [ "$GOT" -gt 0 ]; }; then
  echo "GATE FAIL: expected p2p=$EXPECT but loaded config has $GOT occurrences"; exit 1
fi
echo "gate: epp loaded arm correctly (p2p-source-producer=$GOT, expect $EXPECT)"

pkill -f "port-forward -n nilig-p2p svc/llm-d-router-epp" 2>/dev/null
nohup kubectl port-forward -n nilig-p2p svc/llm-d-router-epp 18095:8081 > "$SP/pf-scenc.log" 2>&1 &
sleep 5
python3 "$SP/scenC_ladder.py" http://localhost:18095 "$ARM" 1,2,3,4 2>&1 | tee "$SP/scenC_$ARM.log"
echo "--- post-run gate ---"
bash "$SP/scenC_gate.sh" "$ARM" "$EXPECT"
