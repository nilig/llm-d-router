# Blog-campaign Weka workload: recovered invocation

Source: live Job spec and pod in `ecrncevi-dev-p1w2d1w2` on kermit
(the GLM agentic-serving blog team's campaign namespace), read 2026-07-31
with the namespace owner's knowledge. Job
`agentx-aiperf-c64-a1-20260729225135` (created 2026-07-29, tree
`new_nightly/results_p1w2_d1w2` - the guide's published-table campaign).
Raw spec: `blog-campaign-job-c64.json`; startup log head:
`blog-campaign-c64-log-head.txt`.

## Invocation (c64 cell; the ladder varies only `--concurrency`)

```
aiperf profile \
  --scenario inferencex-agentx-mvp \
  --url http://llm-d-inference-gateway-istio:80/v1 \
  --model zai-org/GLM-5.2-FP8 \
  --max-context-length 142000 \
  --endpoint-type chat \
  --streaming \
  --use-server-token-count \
  --public-dataset semianalysis_cc_traces_weka_with_subagents \
  --concurrency 64 \
  --random-seed 42 \
  --benchmark-duration 900 \
  --server-metrics http://llm-d-inference-gateway-istio:80/metrics \
  --no-gpu-telemetry \
  --output-artifact-dir "$ARTIFACT_DIR" \
  --ui simple
```

## Environment and image

- Image: `quay.io/tms/aiperf:agentx-v0`, running digest
  `quay.io/tms/aiperf@sha256:bb0b83cf4ec897e1e89172e5a108cc428656e2a857756291b831b8cd0c0edfc5`
- `AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1` (dataset preprocessing
  toggle; part of the workload identity)
- `UNSAFE_ARGS` unset (expands empty; the scenario lock is active)
- Canonical artifacts:
  `/mnt/lustre/agentx-mvp/dev/new_nightly/results_p1w2_d1w2/` (PVC
  `lustre-pvc-vllm`, StorageClass `shared-vast`, in the blog team's
  namespace)

## Interpretation

- There is no separate "paused-conversation" aiperf mode: the scenario
  `inferencex-agentx-mvp` locks the replay invariants (agentic replay
  with the corpus's recorded structure), and the blog's
  "ongoing conversations" prose describes the corpus (393 traces) under
  this scenario at the given `--concurrency`.
- Deltas versus the invocation used by our earlier campaigns on the same
  scenario: `--random-seed 42`, `--max-context-length 142000` (ours:
  128000), the `AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1` toggle,
  and the Istio gateway endpoint (ours: the EPP service directly).

## Open item

The published guide tables' concurrency ladder is 16/64/256 (plus
512 on larger topologies). Confirm with the blog team which cells are
canonical for `p1w2d1w2` and whether any admission filtering beyond the
scenario lock applied.
