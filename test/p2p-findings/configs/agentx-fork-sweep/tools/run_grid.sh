#!/usr/bin/env bash
# AgentX SLO-capacity grid: concurrency rungs x {p2p-off, p2p-on}.
#
# Reports from inside the healthy band rather than at saturation. The headline
# is the largest rung each arm sustains within the SLO fixed below; TTFT deltas
# are supporting evidence.
#
# Usage:  ./tools/run_grid.sh [rung ...]      (default: 48 64 80)
# Smoke:  SMOKE=1 DURATION=60 ./tools/run_grid.sh 4
# Smoke artifacts are not valid benchmark evidence; full runs retain the
# scenario's duration guard.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CAMPAIGN=$(cd "$HERE/.." && pwd)
COUNTERS="$HERE/engine_counter_deltas.py"
DEPLOY="$CAMPAIGN/deploy/apply.sh"

NS=nilig-agentx-slo
EPP=agentx-slo-epp
URL="http://${EPP}.${NS}:8081"
MODEL=zai-org/GLM-5.2-FP8
IMAGE=quay.io/rh-ee-robshaw/aiperf:agentx-v0

# Date-pinned corpus. The `_with_subagents` alias is rolling and advances on new
# drops, so two runs against it are not necessarily comparable.
CORPUS=semianalysis_cc_traces_weka_062126
SEED=20260707
DURATION=${DURATION:-1800}
SMOKE=${SMOKE:-0}
RUN_ID=${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}
CURRENT_ARM=""

# Must match the server's --max-model-len. A 128000 client limit against this
# 120000 server admits traces that overflow at the server and count toward the
# 1% context-overflow validity threshold.
MAX_CTX=120000

# SLO fixed before the runs, from the c32/c64 reference band, so the
# reporting point cannot be chosen after seeing the results.
SLO_TTFT_P50_MS=2500
SLO_TTFT_P95_MS=8000

RUNGS=("${@:-48 64 80}")
read -r -a RUNGS <<<"${RUNGS[*]}"
ARMS=(p2p-off p2p-on)

log() { printf '\n=== %s\n' "$*"; }

switch_arm() {
  local arm=$1
  local patch
  log "switching EPP to ${arm}"
  # Patching the arg rolls the pod. A ConfigMap-only change would not: the
  # mounted file updates in place and the running EPP never re-reads it.
  patch=$(kubectl -n "$NS" get "deploy/${EPP}" -o json | python3 -c '
import json, sys
deployment = json.load(sys.stdin)
containers = deployment["spec"]["template"]["spec"]["containers"]
container_index = next(i for i, c in enumerate(containers) if c["name"] == "epp")
args = containers[container_index]["args"]
value_index = args.index("--config-file") + 1
print(json.dumps([{
    "op": "replace",
    "path": f"/spec/template/spec/containers/{container_index}/args/{value_index}",
    "value": f"/config/{sys.argv[1]}.yaml",
}]))' "$arm")
  kubectl -n "$NS" patch "deploy/${EPP}" --type=json -p "$patch" >/dev/null
  CURRENT_ARM=$arm
  kubectl -n "$NS" rollout status "deploy/${EPP}" --timeout=5m
  kubectl -n "$NS" get deploy "$EPP" -o jsonpath='{.spec.template.spec.containers[?(@.name=="epp")].args}' | tr ',' '\n' | grep -A1 config-file
}

restore_baseline_on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$CURRENT_ARM" == "p2p-on" ]]; then
    log "restoring EPP to p2p-off after interrupted or failed grid"
    set +e
    switch_arm p2p-off
    set -e
  fi
  exit "$status"
}

trap restore_baseline_on_exit EXIT

snapshot_counters() {
  # Counter deltas, not totals: the engines are not restarted between arms.
  local tag=$1
  python3 "$COUNTERS" --namespace "$NS" --snapshot "/tmp/${tag}.json"
}

wait_job() {
  local job=$1
  local deadline=$((SECONDS + DURATION + 1800))
  local state
  while ((SECONDS < deadline)); do
    state=$(kubectl -n "$NS" get "job/${job}" -o json | python3 -c '
import json, sys
conditions = {
    condition["type"]: condition["status"]
    for condition in json.load(sys.stdin).get("status", {}).get("conditions", [])
}
if conditions.get("Complete") == "True":
    print("complete")
elif conditions.get("Failed") == "True":
    print("failed")
else:
    print("running")')
    case "$state" in
    complete) return 0 ;;
    failed)
      echo "job/${job} failed" >&2
      kubectl -n "$NS" logs "job/${job}" --tail=100 >&2 || true
      return 1
      ;;
    esac
    sleep 5
  done
  echo "timed out waiting for job/${job}" >&2
  kubectl -n "$NS" logs "job/${job}" --tail=100 >&2 || true
  return 1
}

run_one() {
  local arm=$1 c=$2
  local suffix=${3:-}
  local name="agentx-${RUN_ID}-c${c}-${arm}${suffix:+-${suffix}}"
  local dir="/workload/${name}"
  local unsafe_override=""
  if [[ "$SMOKE" == 1 ]]; then
    unsafe_override="--unsafe-override"
  fi

  switch_arm "$arm"
  snapshot_counters "${name}-pre"

  log "launching ${name} (duration ${DURATION}s)"
  kubectl -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  cat <<EOF | kubectl -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: aiperf
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
        - |
          set -e
          mkdir -p ${dir}
          exec aiperf profile \
            --scenario 'inferencex-agentx-mvp' \
            --url ${URL} \
            --model '${MODEL}' \
            --max-context-length ${MAX_CTX} \
            --endpoint-type chat \
            --streaming \
            --use-server-token-count \
            --public-dataset '${CORPUS}' \
            --concurrency ${c} \
            --benchmark-duration ${DURATION} ${unsafe_override} \
            --random-seed ${SEED} \
            --server-metrics '${URL%:8081}:9090/metrics' \
            --no-gpu-telemetry \
            --output-artifact-dir ${dir} \
            --ui simple
        env:
        - name: AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES
          value: "1"
        - name: HF_HOME
          value: /workload/.cache/huggingface
        resources:
          requests: {cpu: "4", memory: 8Gi, ephemeral-storage: 20Gi}
          limits:   {cpu: "16", memory: 32Gi, ephemeral-storage: 20Gi}
        volumeMounts:
        - {name: workload, mountPath: /workload}
      volumes:
      - name: workload
        persistentVolumeClaim: {claimName: workload-pvc}
EOF

  if ! wait_job "$name"; then
    snapshot_counters "${name}-post" || true
    return 1
  fi
  snapshot_counters "${name}-post"
  log "${name} done"
}

log "grid: id=${RUN_ID} rungs=${RUNGS[*]} arms=${ARMS[*]} seed=${SEED} corpus=${CORPUS}"
log "SLO: TTFT p50 <= ${SLO_TTFT_P50_MS}ms, p95 <= ${SLO_TTFT_P95_MS}ms"
log "validating render tokenization path"
"$DEPLOY" validate

for c in "${RUNGS[@]}"; do
  for arm in "${ARMS[@]}"; do
    run_one "$arm" "$c"
  done
done

# Drift check: repeat the first cell last. If it does not reproduce, something
# moved during the campaign and the grid is not internally comparable.
log "drift check: repeating c${RUNGS[0]} ${ARMS[0]}"
run_one "${ARMS[0]}" "${RUNGS[0]}" drift

log "grid complete -- counter deltas: $COUNTERS --results --snapshot-dir /tmp"
