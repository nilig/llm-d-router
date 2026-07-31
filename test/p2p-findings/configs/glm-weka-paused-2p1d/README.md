# P2P reconstruction on the blog's p2w1d1w2 topology using the recovered Weka agentic runner

Label rules: this campaign does NOT reproduce the blog's ladder or its
corpus preprocessing (o200k lineage unestablished). It is our own
campaign on the blog's deployment and runner.

Status: PREPARED, NOT RUN. Cluster untouched beyond reads. Awaiting
review sign-off before deployment.

Goal: a valid P2P A/B on the GLM agentic-serving blog's deployment and
workload, per the corrected three-arm matrix.

## Arms

| Arm | Index and placement | P2P | Config |
|---|---|---|---|
| A: blog anchor | Approx two-tier (GPU w5 / CPU w2 + active w1), affinity-led; the blog's shipped values verbatim | off | `epp/armA-blog-plugins.yaml` (extracted from `epp/armA-blog-values.yaml`, pr1947) |
| B: harder control | Precise index (podCacheSize 64), load-led (prefix w1 / queue w3 / active w1) | producer off | `epp/armB-loadfirst.yaml` |
| C: harder + P2P | identical to B | producer on (`minCachedTokenDelta: 12288`) | `epp/armC-loadfirst-p2p.yaml` |

`epp/armB-armC.diff` proves B and C differ only by `p2p-source-producer`.

Attribution rules: B-vs-C is the causal P2P A/B. A is the contextual
comparison with the published approximate policy: A-vs-C is easy-shipped
versus harder deployment, never a P2P delta. A-vs-B prices the
index/placement change without pulls.

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

One engine deployment serves all three arms (the EPP config is the only
per-arm variable). Arm A therefore runs with the P2P/CPU tiers present
but unused by its router config - disclosed, engine-identical arms.
Render: `kubectl kustomize deploy/campaign`.

## Workload

RECONSTRUCTION, not reproduction: the recovered runner is the blog
team's `p1w2d1w2` c64 cell (see `workload/README.md` for exactly what
is and is not established - the `p2w1d1w2` ladder and the corpus
preprocessing remain open asks to the blog team). The scenario
`inferencex-agentx-mvp` implements the ongoing-conversation behavior
internally (TrajectorySource; 64 active trajectories at c64).
`run_arm.sh` clones the archived Job (`workload/blog-campaign-job-c64.json`)
verbatim, changing only URL/metrics endpoints, artifact volume, and the
concurrency cell.

## Gates

- `gates/gate1_deploy_verify.sh`: deployment verification archive
  (listeners, tiers, UCX completion per rank, EPP event flow). Abort on
  any rank without a completed tier init.
- `gates/gate2_p2p_proof.sh`: fresh-prefix one-shot proof, one
  independent prefix per leg (control <50 MB; engine-inject and
  sidecar-header legs each 1,900-2,650 MB at 24,576 tokens; required
  source-session delta across the pull legs; HTTP 200), fails closed.
- `gates/armC_probe.sh`: the arm C organic-engagement probe (stage 1
  stop rule).
- `run_arm.sh` per-arm: EPP arg-swap restart, active-config and
  producer-declaration checks, fleet/foreign-job checks, warm probe,
  before/after counter snapshots (`snap_counters.sh`).

## Bring-up order

```text
kubectl kustomize deploy/campaign | kubectl apply -f -
install_epp_configmap.sh
activate_arm.sh <arm>
gates/gate1_deploy_verify.sh
gates/gate2_p2p_proof.sh
gates/armC_probe.sh <conc>   (engagement stage, per cell)
run_arm.sh <arm> <conc> <tag>  (measurement arms)
```

## Protocol

Ladder: c64 (recovered-runner anchor; likely low engagement), c128
(early spill region), c256 (expected P2P opportunity region), c400
(blog-scale stress; may expose decode saturation).

Two stages:

1. Engagement: one paired B/C run per cell; on the C side,
   `gates/armC_probe.sh <conc>` measures organic engagement first (EPP
   `set KV cache source header` emissions per distinct request in a
   streamed EPP log, plus source-session deltas). Zero directives fails
   the probe and skips the cell's A/B.
2. Measurement: at cells with successful pulls and >=5% engagement,
   three counterbalanced B/C repetitions with paired seeds
   (`SEED=42/43/44` on `run_arm.sh`). A run to anchor.

Only B-versus-C is the causal P2P result; A is the contextual anchor
and is never the no-P2P half of the P2P comparison. Cold-roll policy
and stop rules otherwise per the campaign design; <5% engagement means
a tie is expected and is reported as such.
