#!/usr/bin/env bash
# Keep the engines out of the gpu-pruner's sights for the whole campaign.
#
# The pruner scales idle LWS roles to 0 within ~15-20 minutes. A gap between
# arms is enough: tonight the control arm drained at 19:47, the treatment arm
# started at 20:50, and the engines were reclaimed at ~20:28 in between. The
# treatment then ran to completion against nothing -- 246 records, 0 TTFT, and
# aiperf reported no errors.
#
#   ./keep_warm.sh &     # run for the whole campaign, not per-arm
set -uo pipefail
NS=${NS:-nilig-agentx-slo}
INTERVAL=${INTERVAL:-240}
POD=${POD:-workload-access}
EPP=${EPP:-agentx-slo-epp}

while true; do
  n=$(timeout 30 kubectl -n "$NS" get lws -o json 2>/dev/null \
      | python3 -c "import json,sys;print(sum(x.get('status',{}).get('readyReplicas',0) or 0 for x in json.load(sys.stdin)['items']))" 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ]; then
    # Direct per-engine-pod pings FIRST: the gateway path needs the whole
    # fleet, so during any single role's boot the other role idles and the
    # reclaimer takes it (lost decode twice this way). Rank-0 completions on
    # each engine pod keep every pod individually non-idle.
    for ep in $(timeout 30 kubectl -n "$NS" get pods -o json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    n=p['metadata']['name']
    if not n.startswith('glm-5-2-') or 'render' in n: continue
    ip=p['status'].get('podIP')
    if not ip: continue
    port=8200 if 'decode' in n else 8000
    print(f'{ip}:{port}')" 2>/dev/null); do
      timeout 60 kubectl -n "$NS" exec "$POD" -- python3 -c "
import json,urllib.request
b=json.dumps({'model':'zai-org/GLM-5.2-FP8','prompt':'ping','max_tokens':1}).encode()
try:
    urllib.request.urlopen(urllib.request.Request('http://${ep}/v1/completions', b,
        {'Content-Type':'application/json'}), timeout=45).read()
except Exception: pass
" >/dev/null 2>&1 &
    done
    wait
    timeout 90 kubectl -n "$NS" exec "$POD" -- python3 -c "
import json,urllib.request
b=json.dumps({'model':'zai-org/GLM-5.2-FP8',
              'messages':[{'role':'user','content':'ping'}],
              'max_tokens':1,'stream':False}).encode()
try:
    urllib.request.urlopen(urllib.request.Request(
        'http://${EPP}.${NS}:8081/v1/chat/completions', b,
        {'Content-Type':'application/json'}), timeout=120).read()
except Exception as e:
    print('keep-warm ping failed:', type(e).__name__)
" >/dev/null 2>&1
    echo "[$(date -u +%H:%M:%S)] pinged ($n ready)"
  else
    echo "[$(date -u +%H:%M:%S)] WARNING: 0 ready replicas -- engines reclaimed"
  fi
  sleep "$INTERVAL"
done
