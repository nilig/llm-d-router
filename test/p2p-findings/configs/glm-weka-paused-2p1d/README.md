# GLM + Weka P2P campaign on the blog deployment (p2w1d1w2)

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

Attribution rules: B-vs-C is the causal P2P A/B. A-vs-C is easy-shipped
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
  START_RANK))`; `PYTHONHASHSEED=0`; `--block-size 64`

One engine deployment serves all three arms (the EPP config is the only
per-arm variable). Arm A therefore runs with the P2P/CPU tiers present
but unused by its router config - disclosed, engine-identical arms.
Render: `kubectl kustomize deploy/campaign`.

## Workload

The blog campaign's own invocation, recovered from the campaign
namespace's live Job spec - see `workload/README.md` (scenario
`inferencex-agentx-mvp`, corpus
`semianalysis_cc_traces_weka_with_subagents`,
`AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1`, seed 42,
max-context 142000, 900 s cells, ladder over `--concurrency`).
`run_arm.sh` clones the archived Job (`workload/blog-campaign-job-c64.json`)
verbatim, changing only URL/metrics endpoints, artifact volume, and the
concurrency cell.

## Gates

- `gates/gate1_deploy_verify.sh`: deployment verification archive
  (listeners, tiers, UCX completion per rank, EPP event flow). Abort on
  any rank without a completed tier init.
- `gates/gate2_p2p_proof.sh`: fresh-prefix one-shot proof (control
  ~0.0 MB vs pull ~2,276.4 MB at 24,576 tokens, source accept, HTTP
  200) before any Weka run.
- `run_arm.sh` per-arm: EPP arg-swap restart, active-config and
  producer-declaration checks, fleet/foreign-job checks, warm probe,
  before/after counter snapshots (`snap_counters.sh`).

## Protocol

Per cell (concurrency in {64, 128, 256}): three valid repetitions of B
and C, counterbalanced; A run to anchor. Cold-roll policy, stop rules,
and low-engagement interpretation per the campaign design (no
performance A/B if the short probe shows zero source deltas or zero
injected pulls; <5% pull-rate means a tie is expected and reported as
such).
