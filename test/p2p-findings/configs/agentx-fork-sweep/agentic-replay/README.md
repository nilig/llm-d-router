# Agentic conversation-replay cell - reproduction recipe

Captured from `maroon-precise-kv` on kermit, 2026-08-07. Everything below was
read off the live cluster (manifests exported with `status`/`uid`/`managedFields`
stripped), not reconstructed from notes.

## What the experiment is

A multi-turn agentic workload where each conversation carries a large unique
prefix and returns after a tool-call pause. That shape puts both halves of the
P2P value condition in play: the returning turn finds its blocks gone from GPU
(destination empty), and the holder is between turns rather than saturated by
the request that created the prefix (source plausibly idle). It is the
session-resume case, as opposed to the load-driven spill that the fork campaign
measured.

## Workload

`agentic_replay.yaml` - upstream inference-perf `conversation_replay` datagen
(kubernetes-sigs/inference-perf, present in the repo; the cell runs commit
`e28d9a0` via harness image `ghcr.io/llm-d/llm-d-benchmark:v0.7.0`).

Shape: 60 conversations, concurrency 60, 1200 requests, 8 workers.

| knob | value |
|---|---|
| `shared_system_prompt_len` | 3,000 tokens |
| `dynamic_system_prompt_len` | lognormal, mean 73,000 (10K-100K) - the per-conversation unique prefix |
| `input_tokens_per_turn` | lognormal, mean 1,500 (100-10K) |
| `output_tokens_per_turn` | lognormal, mean 425 (50-10K) |
| `turns_per_conversation` | lognormal, mean 540 (1-3000) |
| `tool_call_latency_sec` | lognormal, mean 15s (1-100s) - the inter-turn pause |
| `seed` / `max_model_len` | 67 / 120000 |

`base_url` points at the EPP Service (`agentx-slo-epp`, port 80 -> envoy).

Run it from the harness pod:

```bash
kubectl -n $NS exec llmdbench-harness-launcher -- \
  inference-perf --config_file /workspace/profiles/inference-perf/agentic_replay.yaml
```

Results land under `/requests/inference-perf_<epoch>_agentic_replay_<stack>/`:
`summary_lifecycle_metrics.json`, `stage_0_lifecycle_metrics.json`,
`per_request_lifecycle_metrics.json` (~1 GB), `stdout.log`.

## Fleet

2 prefill + 2 decode LeaderWorkerSets, `size: 1`, 8 GPUs each (32 total),
GLM-5.2-FP8, DP8 + EP per pod, TP=1.

Engine image `quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302`, with two
ConfigMaps mounted as runtime patches: `vllm-hotfix-50302` (DeepSeek-V3.2
indexer `block_table_width`) and `vllm-exact-model-runner`.

Common engine flags: `--block-size 64`, `PYTHONHASHSEED=0`,
`--max-model-len 120000`, `--kv-cache-dtype fp8`,
`--gpu-memory-utilization 0.935`, `--max-num-batched-tokens 2048`, MTP with 3
speculative tokens, `deep_gemm` MoE backend. KV events published per rank on
`tcp://*:5557`, topic `kv@$POD_IP:8000@zai-org/GLM-5.2-FP8`.

Per-pod resources: 8 GPU, 8 `rdma/ib`, 64 CPU, **1500Gi memory** (the CPU tiers
below need ~800 GiB of it).

### The tier asymmetry - the part that defines the experiment

**Prefill** runs `MultiConnector[NixlConnector, OffloadingConnector]`:

```json
{"spec_name":"TieringOffloadingSpec",
 "cpu_bytes_to_use":107374182400,
 "eviction_policy":"lru",
 "offload_prompt_only":true,
 "secondary_tiers":[{"type":"p2p","host":"<own POD_IP>","port":7777}]}
```

`host` is the pod's own IP - that is the P2P server bind address, not a peer.
Boot log confirms the realized size: `Created TieringOffloadingManager with
primary tier (lru, 30624 blocks)` **per rank** = 1,959,936 tokens/rank, against
a working set of roughly 275K tokens/rank (60 x 73K spread over 16 ranks). The
tier is ~7x oversized, so nothing evicts from CPU - capacity is deliberately not
the binding constraint.

**Decode** runs `MultiConnector[NixlConnector]` only - no CPU tier at all
(verified in the spec, in `/proc/1/cmdline` on both pods, and by the absence of
a TieringOffloadingManager line). It carries the `routing-proxy` sidecar as an
initContainer; prefill has no sidecar.

So the mechanism under test is **prefill-to-prefill pull**. Decode can never be
a pull source, which is consistent with the EPP's
`p2p-source-producer.prefillProfileName: prefill`.

## Router

EPP `ghcr.io/llm-d/llm-d-router-endpoint-picker:main@sha256:7877c5c8...`, envoy
`v1.33.2` sidecar, sidecar image
`ghcr.io/llm-d/llm-d-router-disagg-sidecar:main@sha256:a6e9f4e3...`.
`InferencePool` `agentx-slo`. Single config key `precise-routing.yaml`:

- `token-producer` -> `http://glm-5-2-render-engines:8000`
- `precise-prefix-cache-producer`: `blockSize 64`, `podCacheSize 128`,
  `speculativeIndexing true`, `kvEventsConfig socketPort 5557` with
  `discoverPods`, tier weights gpu 1.0 / cpu 0.4
- `p2p-source-producer`: `minCachedTokenDelta 2048`, `prefillProfileName prefill`
- `inflight-load-producer` + `prefix-cache-affinity-filter` + `token-load-scorer`
  (the spill-capable, load-gated router)
- profiles: prefill = affinity -> token-load -> max-score; decode =
  decode-filter -> active-request -> max-score

## Render

Two Services exist; the EPP uses the second:

- `glm-5-2-render` - the standalone CPU pool, 4 replicas of
  `vllm/vllm-openai-cpu:v0.23.0`, selector `app: glm-5-2-render`. Deployed but
  **not referenced** by the EPP config.
- `glm-5-2-render-engines` - pod-less Service, selector
  `llm-d.ai/model: GLM-5.2-FP8` + `llm-d.ai/role: prefill`, port 8000 ->
  targetPort 8000. This is the render-on-model-servers pattern (llm-d#2188) with
  the prefill-selection adaptation for P/D.

## Files here

```
manifests/lws_glm-5-2-prefill.yaml     lws_glm-5-2-decode.yaml
manifests/deploy_agentx-slo-epp.yaml   manifests/cm_epp-config.yaml
manifests/deploy_glm-5-2-render.yaml   manifests/svc_glm-5-2-render.yaml
manifests/svc_glm-5-2-render-engines.yaml
manifests/svc_agentx-slo-epp.yaml      manifests/inferencepool_agentx-slo.yaml
manifests/cm_envoy.yaml                manifests/sa_glm-5-2.yaml
manifests/cm_vllm-hotfix-50302.yaml    manifests/cm_vllm-exact-model-runner.yaml
manifests/cm_inference-perf-profiles.yaml
agentic_replay.yaml
```

## What must change to redeploy elsewhere

1. `namespace: maroon-precise-kv` throughout.
2. **Prefill LWS pins specific nodes**:
   `nodeAffinity ... kubernetes.io/hostname In [g124daa, gf27fec]`. Remove or
   repoint.
3. Secret `llm-d-hf-token` must exist in the target namespace.
4. `hf-cache` / `jit-cache` hostPath volumes assume the node layout.
5. `base_url` in `agentic_replay.yaml` is the EPP Service cluster IP
   (`10.16.0.66` here) - use the new Service name or IP.
6. Cluster prerequisites: LWS controller, GIE CRDs new enough for a multi-port
   `InferencePool` (>= v1.5.0-rc.2), RDMA/IB device plugin.

## Gaps before this is a result

- **There is no A/B.** `epp-config` has a single key with P2P enabled. A
  `p2p-off` variant (same file minus `p2p-source-producer`) is needed, run as a
  pair with prefill restarts between arms.
- The one existing run predates the current engines (restarted after it), so its
  counter attribution is gone. Baseline numbers from it: prompts mean 59,307 /
  median 58,134 / p90 108,462 tokens; TTFT mean 14.47s / median 13.01s / p90
  28.27s; request latency mean 34.8s; 1.1 req/s; 1194/1200 succeeded.
- Attribution must use **prefill-side** `vllm:external_prefix_cache_hits_total`
  and `kv_offload_*`, never summed with decode (decode's P/D NIXL hits are ~100%
  by design). `tools/engine_counter_deltas.py` on the p2p-findings branch
  snapshots per-role and diffs.
- Open risk: at concurrency 60 on 2 prefill pods with 59K-token prompts the
  prefill tier is deeply queued (TTFT median 13s), which is the saturated regime
  where pulls previously cost more than they saved. The very permissive gate
  (2048 vs our 12288) will fire often.
