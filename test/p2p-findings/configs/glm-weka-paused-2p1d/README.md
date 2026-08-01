# P2P reconstruction on the blog's p2w1d1w2 topology using the recovered Weka agentic runner

Label rules: the workload protocol reproduces the blog's ladder
verbatim (invocations recovered for every rung - see
`workload/blog-ladder-archive/`). PR #1947 ships the exact
`p2w1d1w2` topology, but its published benchmark matrix has no result
row for that topology. This campaign adapts that manifest with a newer
patched engine and the P2P stack. Absolute comparisons to the measured
blog rows carry those caveats; the within-index P2P comparisons are
unaffected.

Status: ACTIVE. The deployment and P2P proof gates pass. A c64 probe with
the precise load-first policy produced organic source directives for 10.6%
of requests (412 of 3,889); engagement is measured again for each P2P
configuration in the blog-policy matrix.

Goal: measure P2P on the GLM agentic-serving blog's deployment and workload
without changing placement policy. The exact blog approximate policy is
measured with and without P2P, followed by its one-index precise equivalent
with and without P2P.

Shareable instructions and descriptively named EPP files are in
`maroon-blog-policy-matrix/`.

## Configurations

| Configuration | Index and placement | P2P | Config |
|---|---|---|---|
| Blog approximate baseline | Two approximate producers: GPU w5 and CPU w2, plus active w1; PR #1947 config byte-for-byte | off | `maroon-blog-policy-matrix/01-blog-approximate-no-p2p.yaml` |
| Blog approximate + P2P | Identical to the baseline | on (`minCachedTokenDelta: 12288`) | `maroon-blog-policy-matrix/02-blog-approximate-with-p2p.yaml` |
| Blog-policy precise | One precise index covering GPU and CPU tiers; GPU w1.0 and CPU w0.4 under scorer w5, plus active w1 | off | `maroon-blog-policy-matrix/03-blog-policy-precise-no-p2p.yaml` |
| Blog-policy precise + P2P | Identical to the precise control | on (`minCachedTokenDelta: 12288`) | `maroon-blog-policy-matrix/04-blog-policy-precise-with-p2p.yaml` |

Approximate uses two producers because the blog independently estimates GPU
and CPU locality. Precise uses one index because the KV-event index already
records both device tiers. The precise tier weights preserve the blog's 5:2
GPU-to-CPU preference. Precise selects the best tier for each block, while the
blog's two approximate scorers can add their independent estimates, so the
cross-index comparison includes that unavoidable semantic difference.

Within each index type, the P2P YAML differs from its control only by
`p2p-source-producer`. Those two within-index comparisons are the causal P2P
results. Approximate versus precise measures the value and operational cost of
the index, not P2P alone.

## Deployment

`deploy/` carries the blog's manifests verbatim from llm-d PR #1947
(`deploy/PROVENANCE.txt`) plus `deploy/adapt_p2p.py`, which applies the
campaign deltas in place (already applied to this copy):

- engine pinned `nightly-6f91edf9` (P2P-tier floor), sidecar
  `kv-source-endpoint-92e5de82` with `--enable-p2p-pull
  --p2p-connector-port=7777`
- `OFFLOADING_MODE=p2p-tiered` on both roles: CPU tier 100 GiB/rank +
  P2P secondary at compensated `P2P_BASE=$((7777 - START_RANK))`,
  `offload_prompt_only: false`
- per-rank KV events at compensated `KV_EVENTS_BASE=$((5557 -
  START_RANK))` with serving-endpoint topics (`kv@POD_IP:8000@model`);
  `VLLM_P2P_SIDE_CHANNEL_HOST` + `VLLM_NIXL_SIDE_CHANNEL_HOST` bound to
  the pod IP on both roles; decode memory/shm raised to 1500Gi for the
  8x100 GiB tier; `PYTHONHASHSEED=0`; `--block-size 64`

Campaign adaptations versus the blog engine config (identical across all
configurations): prefill `PREFILL_GPU_MEM_UTIL=0.935` and
prefill `--max-num-batched-tokens 2048`, the deployment author's own
fixups (elvircrn/llm-d `f6a89192`, archived in `elvir-fixups/`) for the
same KV-floor/warmup OOM class we measured on this topology (crash logs
in `workload/prefill-kv-oom-crash.log`); engine image carries the vllm
#50302 block-table alignment fix (`pr50302-port/`; merged upstream
2026-07-31 as `a0cd2b69`, so any nightly containing that commit needs
no patch), which his `hotfix-50302` component applies equivalently at
boot.

One engine deployment serves all four configurations; the EPP config is the
only per-run variable. The no-P2P configurations therefore run with the
P2P/CPU tiers present but unused by the router config. This keeps the engine
deployment identical across comparisons.
Render: `kubectl kustomize deploy/campaign`.

## Workload

The runner protocol is fully established: the recovered c64 Job plus
the author's result archive (`workload/blog-ladder-archive/`) prove
the whole ladder varies only `--concurrency` around a fixed invocation
(seed 42, 900 s per rung, `--public-dataset
semianalysis_cc_traces_weka_with_subagents`). The scenario
`inferencex-agentx-mvp` implements the ongoing-conversation behavior
internally (TrajectorySource; 64 active trajectories at c64).
`run_arm.sh` clones the archived Job (`workload/blog-campaign-job-c64.json`)
verbatim, changing only URL/metrics endpoints, artifact volume, and the
concurrency cell.

## Gates

- `gates/gate1_deploy_verify.sh`: deployment verification archive
  (listeners, tiers, UCX completion per rank, EPP event flow). Abort on
  any rank without a completed tier init.
- `gates/gate2_p2p_proof.sh`: fresh-prefix proof, one independent
  prefix per leg (control <50 MB; engine-inject and sidecar-header legs
  each 1,200-1,550 MB at 24,576 tokens per the measured 54.6 KB/token
  footprint, with the sidecar leg additionally within 5% of the
  engine-inject positive control; HTTP 200; session evidence =
  new-session delta >= 1 OR a live ESTABLISHED exact-peer connection on
  the source's P2P port at gate completion), fails closed and is
  repeatable on a warm mesh.
- `gates/armC_probe.sh`: the legacy precise-P2P organic-engagement probe.
- `run_arm.sh` per configuration: EPP arg-swap restart, active-config and
  producer-declaration checks, fleet/foreign-job checks, warm probe,
  before/after counter snapshots (`snap_counters.sh`).

## Bring-up order

```text
kubectl kustomize deploy/campaign | kubectl apply -f -
install_epp_configmap.sh
activate_arm.sh <configuration>
gates/gate1_deploy_verify.sh
gates/gate2_p2p_proof.sh
run_arm.sh <configuration> <conc> <tag>
```

## Protocol

Ladder: c16/32/64/128 - the blog's own rungs (every 142k group ran
exactly these; `workload/blog-ladder-archive/cli_commands.txt`). The
author's data shows the comparable `p1w2d1w2` cell entering prefill
contention at c64 (TTFT p99 25 s) and saturation at c128 (p99 38 s),
so the P2P opportunity region is inside the blog ladder; c256 is an
optional extension only if engagement stays <5% through c128.

At c64, run all four configurations with seed 42 in this order: blog
approximate, blog approximate + P2P, blog-policy precise, blog-policy precise
+ P2P. Repeat with seed 43 in reverse order to balance cache and order effects.
The workload, deployment, concurrency, seed, duration, and placement policy
remain fixed inside each P2P pair. Count organic EPP `set KV cache source
header` emissions per distinct request for each P2P run. An engagement rate
below 5% predicts a tie and is reported rather than hidden.

Compare P2P with no P2P within approximate first and within precise second.
Report approximate versus precise separately as an index comparison.

### Cache-state policy

The primary result estimates sustained operation on a warm mesh. Engines,
CPU tiers, and P2P sessions persist across variants; engines are not rolled
within the ladder. Every precise-configuration activation restarts the EPP and
re-proves all 32 precise-index subscriptions. AIPerf's excluded warmup
phase is the fixed per-run warm-in (its request count varies with the
paired seed); the following 900-second profiling phase is the measured
window.

Before each variant, stop keep-warm traffic, require zero running and waiting
requests on every rank, use the same settle interval, and snapshot the
mechanism counters. Resume keep-warm only during an extended operator
pause. Archive source-directive engagement and transferred-byte evidence
for every run with P2P.

Analyze the within-seed P2P differences first and report the forward-order and
reverse-order groups separately. If the P2P advantage reverses sign between
those order groups, or appears in only one order, the pooled warm-mesh result
is not causal evidence; run a cold validation pair with each configuration
preceded by its own engine roll. Any unexpected pod recreation
also invalidates the current pair and requires the deployment gates again.
