#!/bin/bash
# Full Scenario C arm cycle: switch config, roll BOTH P/D roles, gate, then
# drive the ladder from an in-cluster pod.
# Usage: run_arm_full.sh <values-file> <arm-label> <expect-p2p yes|no> <rates_csv>
set -u
NS=nilig-p2p
VALS="$1"; ARM="$2"; EXPECT="$3"; RATES="$4"
SP="$(cd "$(dirname "$0")" && pwd)"
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone
cd "$SP"

echo "### ARM $ARM (rates $RATES) ###"
helm upgrade llm-d-router "$CHART" -n $NS -f "$SP/$VALS" \
  --server-side=true --force-conflicts 2>&1 | grep -E "^REVISION|^STATUS"
# EPP reads plugin config once at startup; a ConfigMap-only upgrade does not
# restart it, so without this the arm silently would not change.
kubectl rollout restart deploy/llm-d-router-epp -n $NS >/dev/null 2>&1
# Both roles together: rolling one side leaves the other holding stale NIXL
# remote sections, which either kills the peer's EngineCore or hangs every
# request.
kubectl delete pod -n $NS -l app=scenc --wait=false >/dev/null 2>&1
sleep 20
bash "$SP/run_incluster.sh" "$ARM" "$EXPECT" "$RATES"
