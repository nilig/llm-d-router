#!/usr/bin/env bash
# Replay one extracted fork window against one router arm.
#
#   NS=nilig-p2p EPP=p2p-pd-epp PVC_POD=access-to-harness-data-workload-pvc \
#   ./run_fork_arm.sh windows/631738ac313214-g0 control
#
# The window replays as a plain weka_trace custom dataset, NOT under
# --scenario inferencex-agentx-mvp: this is a targeted fork experiment, not an
# AgentX submission, so no scenario locks apply and no submission_valid stamp
# is claimed.
set -euo pipefail

WINDOW=${1:?window dir from extract_fork_window.py}
ARM=${2:?arm name, e.g. control or p2p}

NS=${NS:-nilig-agentx-slo}
EPP=${EPP:-agentx-slo-epp}
PVC_POD=${PVC_POD:?set PVC_POD to a pod mounting the workload PVC}
PVC_MOUNT=${PVC_MOUNT:-/workload}
MODEL=${MODEL:-zai-org/GLM-5.2-FP8}
IMAGE=${IMAGE:-quay.io/rh-ee-robshaw/aiperf:agentx-v0}
ARM_CONFIG=${ARM_CONFIG:-}          # /config/<file>.yaml; omit to leave the EPP as-is

WID=$(basename "$WINDOW")
NAME="fork-${WID}-${ARM}"
REMOTE="${PVC_MOUNT}/fork/${WID}"
OUT="${PVC_MOUNT}/fork-runs/${WID}-${ARM}"

log() { printf '\n=== %s\n' "$*"; }

log "staging window on the PVC"
kubectl -n "$NS" exec "$PVC_POD" -- mkdir -p "$REMOTE"
kubectl -n "$NS" cp "$WINDOW/trace.json" "$PVC_POD:$REMOTE/trace.json"
kubectl -n "$NS" cp "$WINDOW/manifest.json" "$PVC_POD:$REMOTE/manifest.json"

if [[ -n "$ARM_CONFIG" ]]; then
  log "switching EPP to $ARM_CONFIG"
  # Patch the arg, not just the ConfigMap: a mounted file updates in place and
  # the running EPP never re-reads it, so the arm would silently not switch.
  # `kubectl set args` does not exist. Patch the --config-file value in place,
  # locating its index in the epp container's args array rather than hardcoding.
  IDX=$(kubectl -n "$NS" get deploy "$EPP" -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
cs=d['spec']['template']['spec']['containers']
ci=[i for i,c in enumerate(cs) if c['name']=='epp'][0]
print(f\"{ci} {cs[ci]['args'].index('--config-file')+1}\")")
  CI=${IDX% *}; AI=${IDX#* }
  kubectl -n "$NS" patch deploy "$EPP" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/${CI}/args/${AI}\",\"value\":\"${ARM_CONFIG}\"}]" >/dev/null
  kubectl -n "$NS" rollout status "deploy/${EPP}" --timeout=5m
fi

log "capturing EPP stream for pull attribution"
kubectl -n "$NS" logs -f "deploy/${EPP}" -c epp --since=1s \
  | grep --line-buffered '"requestID"' > "${WINDOW}/epp-${ARM}.jsonl" &
EPP_TAIL=$!
trap 'kill $EPP_TAIL 2>/dev/null || true' EXIT

log "launching $NAME"
kubectl -n "$NS" delete job "$NAME" --ignore-not-found >/dev/null
cat <<EOF | kubectl -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata: {name: ${NAME}}
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
          mkdir -p ${OUT}
          exec aiperf profile \\
            --model '${MODEL}' --tokenizer '${MODEL}' \\
            --url http://${EPP}.${NS}:8081 \\
            --endpoint-type chat --streaming \\
            --input-file ${REMOTE}/trace.json \\
            --custom-dataset-type weka_trace \\
            --fixed-schedule \\
            --use-server-token-count \\
            --server-metrics 'http://${EPP}.${NS}:9090/metrics' \\
            --no-gpu-telemetry \\
            --output-artifact-dir ${OUT} \\
            --ui simple
        env:
        - {name: HF_HOME, value: ${PVC_MOUNT}/.cache/huggingface}
        - name: HF_TOKEN
          valueFrom: {secretKeyRef: {name: llm-d-hf-token, key: HF_TOKEN}}
        resources:
          requests: {cpu: "4", memory: 8Gi}
          limits: {cpu: "16", memory: 32Gi}
        volumeMounts: [{name: workload, mountPath: ${PVC_MOUNT}}]
      volumes:
      - name: workload
        persistentVolumeClaim: {claimName: workload-pvc}
EOF

# aiperf does not always declare the phase finished: SPAWN_JOIN turns wait on
# every sibling, so one unfulfilled request leaves the run idling forever with
# all records already on disk. Wait for the record count to stop growing rather
# than for job completion, so both arms terminate on the same rule.
prev=-1; stable=0
for i in $(seq 1 240); do
  n=$(kubectl -n "$NS" exec "$PVC_POD" -- sh -c "wc -l < ${OUT}/profile_export.jsonl 2>/dev/null || echo 0" 2>/dev/null | tr -d "[:space:]")
  n=${n:-0}
  if [ "$n" = "$prev" ] && [ "$n" -gt 0 ]; then
    stable=$((stable + 1))
    if [ "$stable" -ge 4 ]; then echo "records stable at ${n} for 4 checks"; break; fi
  else
    stable=0
  fi
  prev=$n
  sleep 30
done
kill $EPP_TAIL 2>/dev/null || true

log "pulling artifacts"
mkdir -p "${WINDOW}/artifacts/${ARM}"
for f in profile_export.jsonl profile_export_aiperf.json server_metrics_export.json; do
  kubectl -n "$NS" cp "$PVC_POD:${OUT}/${f}" "${WINDOW}/artifacts/${ARM}/${f}" 2>/dev/null || \
    echo "  (missing ${f})"
done

# A Complete Job is not a valid run.
if grep -qE '"was_cancelled":true|errors=[1-9]' "${WINDOW}/artifacts/${ARM}/profile_export.jsonl" 2>/dev/null; then
  echo "WARNING: cancellations or errors present -- inspect before analysing"
fi

log "done: ${WINDOW}/artifacts/${ARM}"
