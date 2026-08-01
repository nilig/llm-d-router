# Weka workload: recovered runner

Sources: (1) live Job spec and pod in the blog team's campaign
namespace on kermit (`ecrncevi-dev-p1w2d1w2`), read 2026-07-31 - Job
`agentx-aiperf-c64-a1-20260729225135`, writing to the canonical tree
`/mnt/lustre/agentx-mvp/dev/new_nightly/results_p1w2_d1w2/`; raw spec
`blog-campaign-job-c64.json`, startup log head
`blog-campaign-c64-log-head.txt`. (2) The author's full result tree
(`blog-ladder-archive/`), which confirms the invocation generalizes to
every rung of every measured cell with only `--concurrency` varying.

## What this is, precisely

- The recovered Job is a **`p1w2d1w2` cell at concurrency 64** - one
  DEP16 prefill plus one DEP16 decode - NOT the `p2w1d1w2` topology
  this campaign targets. The author's archive establishes the full
  ladder as c16/32/64/128 per 142k cell; no group contains
  `p2w1d1w2`, so the campaign topology has no measured counterpart.
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

**Status: the workload protocol is a reproduction** (invocation,
ladder, seed, duration, and dataset artifact all match the author's
archive; whatever preprocessing produced the published
`semianalysis_cc_traces_weka_with_subagents` dataset is upstream of
both campaigns and identical by construction). The deployment remains
a campaign variant: `p2w1d1w2` was not measured by the blog.

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
