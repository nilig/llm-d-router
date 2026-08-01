# GLM Weka precise routing and P2P reproduction

This directory packages the exact EPP comparison used by the
`glm-weka-paused-2p1d` campaign at concurrency 64:

- `precise-load-aware-no-p2p.yaml`: precise prefix index and load-aware
  placement, without P2P source selection.
- `precise-load-aware-with-p2p.yaml`: the identical policy plus
  `p2p-source-producer`.

The two files differ only by the `p2p-source-producer` declaration. This is
the causal P2P comparison. PR #1947 ships the exact `p2w1d1w2` topology, but
the published benchmark matrix has no result row for it. The published
approximate-prefix numbers are therefore not this comparison's control.

## Exact deployment

Use the campaign deployment in `../deploy/campaign`. It starts from
[PR #1947's `p2w1d1w2` overlay](https://github.com/llm-d/llm-d/pull/1947/changes#diff-cb54b27c6e204e8e55bae9a10d6a59558799630a56f395a26dd94744ac1de0f0),
at
`guides/wide-ep-lws/modelserver/gpu/vllm-glm-5.2/deployments/p2w1d1w2`.
Its rendered form is `../deploy/rendered-campaign.yaml`. The measured fleet
is:

- two DP8 prefill pods and one two-pod DP16 decode group, 32 H200 GPUs total;
- engine `quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302`;
- sidecar
  `quay.io/niliguy/llm-d-router-disagg-sidecar:kv-source-endpoint-92e5de82`;
- 100 GiB CPU tier per rank and a P2P secondary tier on both roles;
- KV events at compensated base `5557 - START_RANK` and P2P listeners at
  compensated base `7777 - START_RANK`;
- engine and precise-index block size 64, `podCacheSize: 64`;
- prefill GPU memory utilization 0.935 and prefill batch ceiling 2048;
- maximum model length 120,000 and MTP enabled.

The topology is an exact blog-provided topology. The engine pin, P2P tier,
KV-event feed, port compensation, and memory fixups are campaign adaptations
shared by both precise configurations. Changing any item above makes the run
a related experiment rather than a replication of this P2P comparison.

## Exact workload

The campaign runner clones `../workload/blog-campaign-job-c64.json`. It runs:

```text
aiperf profile
  --scenario inferencex-agentx-mvp
  --model zai-org/GLM-5.2-FP8
  --max-context-length 142000
  --endpoint-type chat
  --streaming
  --use-server-token-count
  --public-dataset semianalysis_cc_traces_weka_with_subagents
  --concurrency 64
  --random-seed <paired seed>
  --benchmark-duration 900
  --no-gpu-telemetry
```

The image is `quay.io/tms/aiperf:agentx-v0`, and
`AIPERF_DATASET_WEKA_LIVE_ASSISTANT_RESPONSES=1` is required. AIPerf's warmup
is excluded; the following 900-second profiling phase is measured.

## Run the matched pair

Run from the parent `glm-weka-paused-2p1d` directory. The descriptive names
below are accepted by the campaign scripts.

```bash
export NS=nilig-p2p

kubectl kustomize deploy/campaign | kubectl apply -f -
./install_epp_configmap.sh
./gates/gate1_deploy_verify.sh
./gates/gate2_p2p_proof.sh

# Seed 42, P2P first, then the matched no-P2P control.
SEED=42 ./run_arm.sh precise-p2p 64 maroon-c64-s42-precise-p2p
SEED=42 ./run_arm.sh precise-no-p2p 64 maroon-c64-s42-precise-no-p2p
```

For a second counterbalanced pair, reverse the order with seed 43:

```bash
SEED=43 ./run_arm.sh precise-no-p2p 64 maroon-c64-s43-precise-no-p2p
SEED=43 ./run_arm.sh precise-p2p 64 maroon-c64-s43-precise-p2p
```

Do not roll the engines between the two members of a pair. The runner restarts
the EPP for each precise configuration, proves all 32 KV-event subscriptions,
waits for all 32 ranks to become idle, applies the same settle interval, and
captures before/after counters. Do not run keep-warm or another benchmark job
during either measurement.

## Required evidence

Keep these outputs for each run:

- `profile_export_aiperf.csv` and `profile_export_aiperf.json` from the AIPerf
  canonical artifact directory;
- `weka-<tag>.log` for warmup, completion, and request validity;
- `epp-<tag>.jsonl` and `mechanism-<tag>.txt` for distinct source directives;
- `snap-<tag>-before.txt` and `snap-<tag>-after.txt` for all-rank engine
  counters;
- `quiescent-<tag>.txt` and the precise-subscription archive.

A valid run has four Ready model pods, zero model-container restarts,
`was_cancelled=False`, and `error_records=0`. Duration-end grace-period
cancellations and scenario-declared context-overflow trajectory termination
can appear while `error_records` remains zero; report them, but do not count
them as completed requests.

Calculate performance from `profile_export_aiperf.csv`. Use the EPP stream,
sessions, and byte counters only to prove that the intended mechanism engaged;
do not use cumulative transferred bytes as a performance metric. Analyze
within-seed P2P minus no-P2P differences before pooling the pairs.

## Configuration identity

Both configurations use:

- precise prefix index with `podCacheSize: 64` and block size 64;
- prefill prefix weight 1, queue weight 3, and active-request weight 1;
- decode active-request weight 3.

The P2P configuration adds only:

```yaml
- type: p2p-source-producer
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
    prefillProfileName: prefill
    minCachedTokenDelta: 12288
```
