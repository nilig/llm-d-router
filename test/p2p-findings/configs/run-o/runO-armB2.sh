#!/usr/bin/env bash
set -uo pipefail
NSP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad
source "$NSP/epp_lib.sh"
log(){ echo "$(date +%H:%M:%S) [runO-B2] $*"; }
MULTI='{"kv_connector":"MultiConnector","kv_role":"kv_both","kv_connector_extra_config":{"connectors":[{"kv_connector":"NixlConnector","kv_role":"kv_both"},{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_connector_extra_config":{"spec_name":"TieringOffloadingSpec","cpu_bytes_to_use":137438953472,"offload_prompt_only":false,"secondary_tiers":[{"type":"p2p","host":"$(POD_IP)","port":7777}]}}]}}'
for d in qwen-pd-prefill qwen-pd-decode; do
  idx=$($K get deploy "$d" -o json | python3 -c "import json,sys;a=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args'];print(a.index('--kv-transfer-config')+1)")
  $K patch deploy "$d" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/$idx\",\"value\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$MULTI")}]" >/dev/null
done
$K patch deploy qwen-pd-decode --type=json -p '[{"op":"replace","path":"/spec/template/spec/initContainers/0/args","value":["--port=8000","--vllm-port=8200","--kv-connector=nixlv2","--enable-p2p-pull","--zap-log-level=2","--secure-proxy=false"]}]' >/dev/null
apply_epp "$NSP/epp-qwen-b.yaml" >/dev/null 2>&1
log "arm B config; re-roll..."
$K scale deploy qwen-pd-prefill qwen-pd-decode --replicas=0 >/dev/null
for i in $(seq 1 40); do [ "$($K get pods --no-headers 2>/dev/null | grep -cE 'qwen-pd-(prefill|decode)-')" = "0" ] && break; sleep 8; done
$K scale deploy qwen-pd-prefill --replicas=2 >/dev/null
$K scale deploy qwen-pd-decode --replicas=4 >/dev/null
for i in $(seq 1 90); do
  P=$($K get pods --no-headers 2>/dev/null | grep qwen-pd-prefill | grep -c "1/1 *Running")
  D=$($K get pods --no-headers 2>/dev/null | grep qwen-pd-decode | grep -c "2/2 *Running")
  [ "$P" = "2" ] && [ "$D" = "4" ] && break; sleep 12
done
[ "${P:-0}" = "2" ] && [ "${D:-0}" = "4" ] || { log "not ready"; exit 1; }
log "fleet ready; synthetic arm B (sample 2)..."
python3 - <<'PYEOF'
NSP="/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad"
s=open(f"{NSP}/qwen-agentic-syn.yaml").read()
s=s.replace("stack_name: qwen-agentic-syn","stack_name: qwen-agentic-synB2")
open(f"{NSP}/qwen-agentic-synB2.yaml","w").write(s)
PYEOF
cd /Users/niliguy/github.com/llm-d-benchmark
HARNESS_CPU_MEM=32Gi ./existing_stack/run_only.sh -c "$NSP/qwen-agentic-synB2.yaml" -o "$NSP/qwen-syn-armB2run" 2>&1 | grep -E "Stage 0|rc=" | tail -2
DIRB=$($K exec llmdbench-harness-launcher -- sh -c "ls -dt /requests/inference-perf_*synB2* 2>/dev/null | head -1")
$K exec llmdbench-harness-launcher -- sh -c "cat $DIRB/stage_0_lifecycle_metrics.json" > "$NSP/runO-results/armB2.json" 2>/dev/null
[ -s "$NSP/runO-results/armB2.json" ] && log "armB2 json SAVED" || log "armB2 json MISSING"
log "DONE"
