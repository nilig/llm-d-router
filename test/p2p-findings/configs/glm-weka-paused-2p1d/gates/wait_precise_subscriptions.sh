#!/bin/bash
# Waits until the current EPP pod holds live ZMQ subscriptions to every
# per-rank KV-event endpoint of every model pod, then archives the proof.
# Live-connection evidence replaces log greps: subscription lines log once
# at endpoint discovery and age out of any bounded tail at --v=5, and this
# EPP build exposes no subscriber gauge or event counter.
#
# PASS requires, within SUBS_TIMEOUT seconds:
#   - exactly FLEET_EXPECT model pods (llm-d.ai/inference-serving=true, Ready)
#   - on every model pod, for every local port 5557-5564: a /proc/net/tcp
#     entry in state 01 (ESTABLISHED) whose remote address is the current
#     EPP pod IP; deduplicated by (pod, port); total == FLEET_EXPECT * 8
#
# Usage: wait_precise_subscriptions.sh <archive-dir>
# Env: NS, FLEET_EXPECT (4), SUBS_TIMEOUT (180), EPP_APP_LABEL (p2p-pd-epp)
set -euo pipefail
NS=${NS:-nilig-p2p}
FLEET_EXPECT=${FLEET_EXPECT:-4}
SUBS_TIMEOUT=${SUBS_TIMEOUT:-180}
EPP_APP_LABEL=${EPP_APP_LABEL:-p2p-pd-epp}
OUT=${1:?usage: wait_precise_subscriptions.sh <archive-dir>}
mkdir -p "$OUT"

# newest Ready EPP pod: a rollout can leave the old pod Terminating
EPP_IP=$(kubectl -n "$NS" get pods -l "app=$EPP_APP_LABEL" -o json | python3 -c '
import json, sys
pods = json.load(sys.stdin)["items"]
ready = []
for p in pods:
    if p["metadata"].get("deletionTimestamp"):
        continue
    conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
    if conds.get("Ready") == "True" and p["status"].get("podIP"):
        ready.append((p["metadata"]["creationTimestamp"], p["status"]["podIP"]))
if not ready:
    raise SystemExit("no Ready EPP pod")
print(sorted(ready)[-1][1])')
echo "current EPP pod IP: $EPP_IP" | tee "$OUT/precise-subscriptions.txt"

DEADLINE=$((SECONDS + SUBS_TIMEOUT))
while :; do
  PODS=$(kubectl -n "$NS" get pods -l 'llm-d.ai/inference-serving=true' --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") print $1}')
  NPODS=$(echo "$PODS" | grep -c . || true)
  MATCHED=""
  TOTAL=0
  for pod in $PODS; do
    got=$(kubectl -n "$NS" exec "$pod" -c vllm -- python3 -c "
hexip = ''.join(f'{int(o):02X}' for o in reversed('$EPP_IP'.split('.')))
ports = set()
for line in open('/proc/net/tcp').readlines()[1:]:
    f = line.split()
    lport = int(f[1].split(':')[1], 16)
    if 5557 <= lport <= 5564 and f[3] == '01' and f[2].split(':')[0] == hexip:
        ports.add(lport)
print(' '.join(str(p) for p in sorted(ports)))" 2>/dev/null || true)
    n=$(echo "$got" | wc -w | tr -d ' ')
    TOTAL=$((TOTAL + n))
    MATCHED="$MATCHED$pod ports=[$got] covered=$n/8"$'\n'
  done
  if [ "$NPODS" -eq "$FLEET_EXPECT" ] && [ "$TOTAL" -eq $((FLEET_EXPECT * 8)) ]; then
    {
      echo "PASS: $TOTAL/$((FLEET_EXPECT * 8)) rank endpoints subscribed by $EPP_IP"
      echo "$MATCHED"
    } | tee -a "$OUT/precise-subscriptions.txt"
    exit 0
  fi
  if [ $SECONDS -ge $DEADLINE ]; then
    {
      echo "FAIL: $TOTAL/$((FLEET_EXPECT * 8)) rank endpoints subscribed (pods ready: $NPODS/$FLEET_EXPECT) after ${SUBS_TIMEOUT}s"
      echo "$MATCHED"
    } | tee -a "$OUT/precise-subscriptions.txt"
    exit 1
  fi
  echo "waiting: $TOTAL/$((FLEET_EXPECT * 8)) subscribed, pods $NPODS/$FLEET_EXPECT"
  sleep 5
done
