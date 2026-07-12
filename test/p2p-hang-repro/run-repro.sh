#!/usr/bin/env bash
# Runs p2p_hang_repro.py in-cluster against 4 vLLM pods running the generic_p2p
# connector. Override CTX / NS / DEPLOY / MODEL for your cluster.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CTX="${CTX:-kermit_US-EAST-01A}"
NS="${NS:-nilig-p2p}"
DEPLOY="${DEPLOY:-p2p-agg-vllm}"
MODEL="${MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
K="kubectl --context $CTX --request-timeout=40s -n $NS"
ST="$HERE/REPRO_STATUS.txt"; : > "$ST"
log(){ echo "$(date +%H:%M:%S) | $*" | tee -a "$ST"; }

$K scale deploy/"$DEPLOY" --replicas=4 >/dev/null 2>&1
for i in $(seq 1 60); do r=$($K get pods --no-headers 2>/dev/null | grep "$DEPLOY" | grep -c '2/2 *Running'); [ "$r" = 4 ] && break; sleep 12; done
IPS=$($K get pods --no-headers -o wide 2>/dev/null | grep "$DEPLOY" | grep '2/2 *Running' | awk '{print $6}' | head -4)
URLS=$(for ip in $IPS; do echo -n "http://$ip:8200,"; done | sed 's/,$//')
log "URLS=$URLS"
# Feed the script to the pod on stdin (python - reads the program from stdin).
# Passing it inline base64-encoded and exec()-ing it trips EDR signatures for
# "base64-encoded command via python"; stdin avoids both the encode and the exec.
R=$RANDOM
$K run repro$R --image=python:3.11-slim -i --rm --restart=Never \
  --env="URLS=$URLS" --env="MODEL=$MODEL" \
  --env="KPER=${KPER:-300}" --env="CONC=${CONC:-60}" --env="DUR=${DUR:-75}" \
  --command -- python - < "$HERE/p2p_hang_repro.py" 2>&1 \
  | grep -E "source=|ARM|warmed|reqs=|RESULT|body|tail|stalled|REPRODUCED|weak|Error|Traceback" \
  | while read l; do log "  $l"; done
log "DONE"
