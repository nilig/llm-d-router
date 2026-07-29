#!/bin/bash
# Run O re-run, one arm end to end on the fixed stack.
# A = plain NIXL P/D (engine NixlConnector-only, sidecar without pull, EPP qa.yaml)
# B = + P2P (engine MultiConnector w/ p2p tier, sidecar --enable-p2p-pull, EPP qb.yaml)
# Usage: runO_arm.sh <A|B>
set -u
NS=nilig-p2p
ARM="$1"
SP="$(cd "$(dirname "$0")" && pwd)"; cd "$SP"
CHART=/Users/niliguy/github.com/llm-d-router/config/charts/llm-d-router-standalone
NIXL_ONLY='{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
MULTI='{"kv_connector":"MultiConnector","kv_role":"kv_both","kv_connector_extra_config":{"connectors":[{"kv_connector":"NixlConnector","kv_role":"kv_both"},{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_connector_extra_config":{"spec_name":"TieringOffloadingSpec","cpu_bytes_to_use":137438953472,"offload_prompt_only":false,"secondary_tiers":[{"type":"p2p","host":"$(POD_IP)","port":7777}]}}]}}'
if [ "$ARM" = "A" ]; then CONN="$NIXL_ONLY"; VALS=runO-values-a.yaml; CFG=qa.yaml; EXPECT=no;
  SIDE='["--port=8000","--vllm-port=8200","--kv-connector=nixlv2","--zap-log-level=2","--secure-proxy=false"]'
else CONN="$MULTI"; VALS=runO-values-b.yaml; CFG=qb.yaml; EXPECT=yes;
  SIDE='["--port=8000","--vllm-port=8200","--kv-connector=nixlv2","--enable-p2p-pull","--zap-log-level=2","--secure-proxy=false"]'
fi
echo "### RUN-O ARM $ARM ###"
for d in qwen-pd-prefill qwen-pd-decode; do
  idx=$(kubectl -n $NS get deploy "$d" -o json | python3 -c "import json,sys;a=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args'];print(a.index('--kv-transfer-config')+1)")
  kubectl -n $NS patch deploy "$d" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/$idx\",\"value\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$CONN")}]" >/dev/null
done
kubectl -n $NS patch deploy qwen-pd-decode --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/initContainers/0/args\",\"value\":$SIDE}]" >/dev/null
helm upgrade llm-d-router "$CHART" -n $NS -f "$SP/$VALS" --server-side=true --force-conflicts > /tmp/_helm_runO_$ARM.log 2>&1 \
  || { echo "ABORT helm"; tail -5 /tmp/_helm_runO_$ARM.log; exit 1; }
grep -E "^REVISION" /tmp/_helm_runO_$ARM.log
kubectl -n $NS rollout restart deploy/llm-d-router-epp >/dev/null 2>&1
echo "clean re-roll..."
kubectl -n $NS scale deploy qwen-pd-prefill qwen-pd-decode --replicas=0 >/dev/null
for i in $(seq 1 40); do [ "$(kubectl -n $NS get pods --no-headers 2>/dev/null | grep -cE 'qwen-pd-(prefill|decode)-')" = "0" ] && break; sleep 8; done
kubectl -n $NS scale deploy qwen-pd-prefill --replicas=2 >/dev/null
kubectl -n $NS scale deploy qwen-pd-decode --replicas=4 >/dev/null
for i in $(seq 1 90); do
  # the gpu-pruner reclaims idle deployments mid-wait; re-assert every loop
  [ "$(kubectl -n $NS get deploy qwen-pd-prefill -o jsonpath='{.spec.replicas}')" = "2" ] || kubectl -n $NS scale deploy qwen-pd-prefill --replicas=2 >/dev/null 2>&1
  [ "$(kubectl -n $NS get deploy qwen-pd-decode  -o jsonpath='{.spec.replicas}')" = "4" ] || kubectl -n $NS scale deploy qwen-pd-decode  --replicas=4 >/dev/null 2>&1
  P=$(kubectl -n $NS get pods --no-headers 2>/dev/null | grep qwen-pd-prefill | grep -c "1/1 *Running")
  D=$(kubectl -n $NS get pods --no-headers 2>/dev/null | grep qwen-pd-decode | grep -c "2/2 *Running")
  epp=$(kubectl -n $NS get deploy llm-d-router-epp -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "[$i] prefill=$P/2 decode=$D/4 epp=${epp:-0}/1"
  [ "$P" = "2" ] && [ "$D" = "4" ] && [ "${epp:-0}" = "1" ] && break
  sleep 12
done
[ "${P:-0}" = "2" ] && [ "${D:-0}" = "4" ] || { echo "ABORT: fleet"; exit 1; }
bash "$SP/arm_gate.sh" "$EXPECT" "$CFG" || exit 1
code=$(kubectl exec -n $NS scenc-loadgen -- python3 -c "
import urllib.request,json
b=json.dumps({'model':'Qwen/Qwen3-30B-A3B-Thinking-2507','prompt':'hello','max_tokens':4,'temperature':0}).encode()
r=urllib.request.Request('http://llm-d-router-epp:8081/v1/completions',data=b,headers={'Content-Type':'application/json'})
try: print(urllib.request.urlopen(r,timeout=240).status)
except Exception as e: print('ERR',type(e).__name__)
" 2>&1 | tail -1)
echo "probe: $code"; [ "$code" = "200" ] || { echo "ABORT probe"; exit 1; }
python3 - "$ARM" <<'PY'
import sys
s=open('qwen-rerun-syn.yaml').read()
arm=sys.argv[1]
s=s.replace('stack_name: qwen-rerun', f'stack_name: qwen-rerun{arm}')
open(f'qwen-rerun-syn{arm}.yaml','w').write(s)
PY
echo "=== workload arm $ARM (llmdbenchmark harness) ==="
cd /Users/niliguy/github.com/llm-d-benchmark
HARNESS_CPU_MEM=32Gi ./existing_stack/run_only.sh -c "$SP/qwen-rerun-syn$ARM.yaml" -o "$SP/runO-$ARM" 2>&1 | tail -5
DIR=$(kubectl exec -n $NS llmdbench-harness-launcher -- sh -c "ls -dt /requests/inference-perf_*rerun$ARM* 2>/dev/null | head -1" 2>/dev/null)
[ -n "$DIR" ] && kubectl exec -n $NS llmdbench-harness-launcher -- sh -c "cat $DIR/stage_0_lifecycle_metrics.json" > "$SP/runO-results/arm$ARM.json" 2>/dev/null
[ -s "$SP/runO-results/arm$ARM.json" ] && echo "arm$ARM json SAVED" || echo "arm$ARM json MISSING"
S=0
for p in $(kubectl -n $NS get pods -l app=qwen-pd -o name); do
  S=$((S + $(kubectl -n $NS logs $p -c modelserver 2>/dev/null | grep -c 'created connected session')))
done
echo "sessions=$S"
echo "RUN-O ARM $ARM COMPLETE"
