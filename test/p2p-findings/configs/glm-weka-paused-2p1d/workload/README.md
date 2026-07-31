# Weka workload: recovered runner, RECONSTRUCTION status

Source: live Job spec and pod in the blog team's campaign namespace on
kermit (`ecrncevi-dev-p1w2d1w2`), read 2026-07-31. Job
`agentx-aiperf-c64-a1-20260729225135`, writing to the canonical tree
`/mnt/lustre/agentx-mvp/dev/new_nightly/results_p1w2_d1w2/`. Raw spec:
`blog-campaign-job-c64.json`; startup log head:
`blog-campaign-c64-log-head.txt`.

## What this is, precisely

- It is a **`p1w2d1w2` cell at concurrency 64** - one DEP16 prefill plus
  one DEP16 decode - NOT the `p2w1d1w2` topology this campaign targets,
  and only the c64 cell was visible. No 100-400 ladder artifact was
  found.
- The scenario `inferencex-agentx-mvp` implements the
  ongoing-conversation behavior internally: the log shows
  `TrajectorySource` selecting sample times and building 64 active
  trajectories. There is no separate paused-conversation CLI mode.
- Trace admission on this run: 295 of 393 raw traces dropped, 683
  conversations reconstructed from the 98 accepted traces, exactly 64
  trajectories started. "~400 ongoing conversations" is not a property
  of this cell.
- No `o200k` step appears in the command or log; the job configures the
  GLM tokenizer. The preprocessing recipe behind the blog's corpus
  transformation is NOT established by this recovery.

**Consequently: a campaign built from this runner is a RECONSTRUCTION
of the blog workload pattern, not a reproduction of the blog campaign,
until the blog team supplies the `p2w1d1w2` ladder invocations and the
preprocessing details.** Open ask to the blog team: the concurrency
ladder and per-cell invocations for `p2w1d1w2`, any admission filtering
beyond the scenario lock, and the corpus preprocessing (tokenizer
lineage included).

## Invocation (c64 cell as recovered)

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
- `AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1` (dataset toggle;
  part of the workload identity; its exact effect is not documented
  here beyond the name)
- `UNSAFE_ARGS` unset, so the scenario lock is active

## Deltas versus our earlier campaigns on this scenario

`--random-seed 42`, `--max-context-length 142000` (ours: 128000), the
live-assistant-responses toggle, and the Istio gateway endpoint (ours:
the EPP service directly).
