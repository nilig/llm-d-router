#!/usr/bin/env bash
set -uo pipefail
NSP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad
source "$NSP/epp_lib.sh"
log(){ echo "$(date +%H:%M:%S) [runO-A] $*"; }
NIXL_ONLY='{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
for d in qwen-pd-prefill qwen-pd-decode; do
  idx=$($K get deploy "$d" -o json | python3 -c "import json,sys;a=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args'];print(a.index('--kv-transfer-config')+1)")
  $K patch deploy "$d" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/$idx\",\"value\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NIXL_ONLY")}]" >/dev/null
done
$K patch deploy qwen-pd-decode --type=json -p '[{"op":"replace","path":"/spec/template/spec/initContainers/0/args","value":["--port=8000","--vllm-port=8200","--kv-connector=nixlv2","--zap-log-level=2","--secure-proxy=false"]}]' >/dev/null
apply_epp "$NSP/epp-qwen-a.yaml" >/dev/null 2>&1
log "arm A config applied; clean re-roll..."
$K scale deploy qwen-pd-prefill qwen-pd-decode --replicas=0 >/dev/null
for i in $(seq 1 40); do [ "$($K get pods --no-headers 2>/dev/null | grep -cE 'qwen-pd-(prefill|decode)-')" = "0" ] && break; sleep 8; done
$K scale deploy qwen-pd-prefill --replicas=2 >/dev/null
$K scale deploy qwen-pd-decode --replicas=4 >/dev/null
for i in $(seq 1 90); do
  P=$($K get pods --no-headers 2>/dev/null | grep qwen-pd-prefill | grep -c "1/1 *Running")
  D=$($K get pods --no-headers 2>/dev/null | grep qwen-pd-decode | grep -c "2/2 *Running")
  if [ "$P" = "2" ] && [ "$D" = "4" ]; then
    nx=0
    for PP in $($K get pods --no-headers | grep -E "qwen-pd-(prefill|decode)" | awk '{print $1}'); do
      $K get pod "$PP" -o jsonpath='{.spec.containers[0].args}' 2>/dev/null | grep -q MultiConnector && nx=$((nx+1))
    done
    [ "$nx" = "0" ] && { log "fleet ready: uniform arm-A"; break; }
  fi
  sleep 12
done
[ "${P:-0}" = "2" ] && [ "${D:-0}" = "4" ] && [ "${nx:-1}" = "0" ] || { log "NOT ready - abort"; exit 1; }
log "running synthetic arm A..."
cd /Users/niliguy/github.com/llm-d-benchmark
python3 - <<'PYEOF'
NSP="/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad"
s=open(f"{NSP}/qwen-agentic-syn.yaml").read()
s=s.replace("stack_name: qwen-agentic-syn","stack_name: qwen-agentic-synA")
open(f"{NSP}/qwen-agentic-synA.yaml","w").write(s)
PYEOF
HARNESS_CPU_MEM=32Gi ./existing_stack/run_only.sh -c "$NSP/qwen-agentic-synA.yaml" -o "$NSP/qwen-syn-armA" 2>&1 | grep -E "Stage 0|completed|rc=" | tail -3
log "ARM A syn done; otel16..."
$K exec llmdbench-harness-launcher -- sh -c "cd /tmp && rm -rf otelA-out && mkdir -p otelA-out && cd otelA-out && timeout 900 inference-perf --config_file /tmp/otel16.yaml >/dev/null 2>&1 && echo otel16-armA-done"
log "ARM A DONE"
