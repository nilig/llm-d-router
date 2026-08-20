#!/bin/bash
# deploy_arm.sh <arm>  - recreate engines for an arm, restart EPP, verify gates
set -u
ARM=$1
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/157fda50-ea95-416f-aaf6-9e3afa6c3eb8/scratchpad
K="kubectl --context kermit_US-EAST-01A -n nilig-p2p"

$K delete deploy pd-disaggregation-nvidia-gpu-vllm-prefill pd-disaggregation-nvidia-gpu-vllm-decode >/dev/null 2>&1
until [ "$($K get pods -l llm-d.ai/guide=pd-disaggregation --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; do sleep 5; done
$K apply -f $SP/arm$ARM.yaml >/dev/null 2>&1
$K rollout restart deploy pd-disaggregation-epp >/dev/null 2>&1
echo "applied arm$ARM; waiting for 16 ready..."
for i in $(seq 1 60); do
  n=$($K get pods -l llm-d.ai/guide=pd-disaggregation --no-headers 2>/dev/null | grep -cE " ([12])/\1 +Running")
  [ "$n" = "16" ] && break
  sleep 20
done
echo "ready pods: $n  restarts: $($K get pods -l llm-d.ai/guide=pd-disaggregation --no-headers 2>/dev/null | awk '{s+=$4} END {print s+0}')"
P=$($K get pods -l llm-d-router-gateway=pd-disaggregation-epp --no-headers 2>/dev/null | awk '$3=="Running"{print $1}' | head -1)
echo "subscribers: $($K logs $P -c epp --tail=3000 2>/dev/null | grep -o 'tcp://[0-9.]*:5556' | sort -u | wc -l | tr -d ' ')"
echo "sidecar: $($K get deploy pd-disaggregation-nvidia-gpu-vllm-decode -o jsonpath='{.spec.template.spec.initContainers[0].image}' 2>/dev/null)"
echo "kv-connector: $($K get deploy pd-disaggregation-nvidia-gpu-vllm-decode -o jsonpath='{.spec.template.spec.initContainers[0].args}' 2>/dev/null | tr ',' '\n' | grep kv-connector)"
