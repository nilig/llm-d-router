#!/usr/bin/env bash
# Cache-pressure sweep: how much more of the prefix does the best peer hold
# than the rank we chose, as concurrent fork groups increase?
#
# One fork group on this cell produced a median advantage of 0 tokens against a
# 12,288 gate -- prefix affinity places every sibling on a rank that already has
# the blocks, so there is nothing to pull. Shrinking the CPU tier does not fix
# that: with ~288K tokens/rank of GPU KV against a 40K prefix, the prefix stays
# resident regardless. The lever that actually evicts is the working set, so
# this replays K distinct fork groups at once and watches the delta move.
#
# Measures router decisions, not latency, so it needs no A/B and no saturation.
set -uo pipefail
cd "$(dirname "$0")"

NS=nilig-agentx-slo
EPP=agentx-slo-epp
POD=workload-access
MODEL=zai-org/GLM-5.2-FP8
IMAGE=quay.io/rh-ee-robshaw/aiperf:agentx-v0
KS=${KS:-"1 4 8 14"}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
WINDOWS=($(ls windows))
log "${#WINDOWS[@]} windows staged; sweeping K = $KS"

for K in $KS; do
  log "=== K=$K concurrent fork groups"

  # Reset the EPP so every point starts from an empty precise index.
  kubectl -n "$NS" rollout restart "deploy/${EPP}" >/dev/null 2>&1
  kubectl -n "$NS" rollout status "deploy/${EPP}" --timeout=5m >/dev/null 2>&1
  sleep 30   # subscriptions are not established at Ready; they lag ~20-30s

  STREAM="sweep-K${K}.jsonl"
  kubectl -n "$NS" logs -f "deploy/${EPP}" -c epp --since=1s 2>/dev/null \
    | grep --line-buffered '"requestID"' > "$STREAM" &
  TAIL=$!

  names=()
  for i in $(seq 0 $((K - 1))); do
    w=${WINDOWS[$i]}
    n="sweep-k${K}-$(echo "$w" | tr -cd 'a-z0-9-' | cut -c1-30)"
    names+=("$n")
    kubectl -n "$NS" delete job "$n" --ignore-not-found >/dev/null 2>&1
    cat <<EOF | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: ${n}}
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
          mkdir -p /workload/sweep/K${K}/${w}
          exec aiperf profile --model '${MODEL}' --tokenizer '${MODEL}' \\
            --url http://${EPP}.${NS}:8081 --endpoint-type chat --streaming \\
            --input-file /workload/fork/${w}/trace.json \\
            --custom-dataset-type weka_trace --fixed-schedule \\
            --use-server-token-count --no-gpu-telemetry \\
            --output-artifact-dir /workload/sweep/K${K}/${w} --ui simple
        env:
        - {name: HF_HOME, value: /workload/.cache/huggingface}
        - name: HF_TOKEN
          valueFrom: {secretKeyRef: {name: llm-d-hf-token, key: HF_TOKEN}}
        resources:
          requests: {cpu: "2", memory: 6Gi}
          limits: {cpu: "8", memory: 24Gi}
        volumeMounts: [{name: workload, mountPath: /workload}]
      volumes:
      - name: workload
        persistentVolumeClaim: {claimName: workload-pvc}
EOF
  done
  log "launched ${#names[@]} jobs"

  # Every window's replay spans <= ~290s; give the tail room then stop.
  prev=-1; stable=0
  for t in $(seq 1 40); do
    n=$(wc -l < "$STREAM" 2>/dev/null | tr -d ' ')
    if [ "$n" = "$prev" ] && [ "${n:-0}" -gt 0 ]; then
      stable=$((stable+1)); [ "$stable" -ge 4 ] && break
    else stable=0; fi
    prev=$n; sleep 30
  done
  kill $TAIL 2>/dev/null
  for n in "${names[@]}"; do kubectl -n "$NS" delete job "$n" --ignore-not-found >/dev/null 2>&1; done

  ./.venv/bin/python delta_stats.py "$STREAM" --label "K=$K" | tee -a sweep-results.txt
  ./.venv/bin/python delta_stats.py "$STREAM" --label "K=$K" --json >> sweep-results.jsonl
done

log "sweep complete"
cat sweep-results.txt
