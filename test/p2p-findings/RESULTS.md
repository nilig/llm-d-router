# P2P KV Cache Sharing - Benchmark Results

All measured results for peer-to-peer KV cache sharing in llm-d, across two
rigs: a 4-GPU Llama-3.1-8B deployment (small scale, plus a P/D variant) and a
16-GPU gpt-oss-120b deployment (scale-out). Robustness defects found along
the way, their fixes, and reproducers are in [README.md](README.md).

## What is measured

Three routing arms, identical pods and workload in every comparison; only
the EPP scheduling config changes:

1. **Affinity** - precise (KV-event-fed) prefix-cache affinity scoring.
   Requests steer to the pod that owns their prefix.
2. **Load, no P2P** - load-balanced placement (queue + KV-utilization
   scorers). Every cross-pod request recomputes its prefix: the recompute
   floor.
3. **Load + P2P** - the same load-balanced placement plus the
   `p2p-source-producer`: when a peer holds at least `minCachedTokenDelta`
   more cached prefix tokens than the scheduled pod, the router attaches a
   KV-source header and the pod pulls the prefix from that peer
   (CPU-to-CPU over NIXL/UCX) instead of recomputing it.

## Hardware and software

| | Small scale (Llama) | Scale-out (gpt-oss) |
|---|---|---|
| Model | `meta-llama/Llama-3.1-8B-Instruct` | `openai/gpt-oss-120b` (MXFP4) |
| Pods | 4x TP=1 (P/D variant: 4 prefill + 1 decode) | 16x TP=1 |
| GPU | NVIDIA H200 (CoreWeave) | NVIDIA H200 (CoreWeave) |
| Interconnect | RDMA (NIXL/UCX) | RDMA (NIXL/UCX) |
| KV per token | ~128 KB | ~41.5 KB (hybrid GQA + sliding window) |
| GPU KV per pod | ~0.5M tokens | ~1.38M tokens (`--gpu-memory-utilization=0.85`, `--max-model-len=65536`) |
| CPU offload tier | 32 GiB per pod | 64 GiB per pod (`/dev/shm` 96 Gi) |
| vLLM block size | 64 (matches router `blockSize`) | 64 (matches router `blockSize`) |
| `minCachedTokenDelta` | 2048 | 2048 (re-derived from the crossover below) |
| vLLM | nightly + `generic_p2p` OffloadingConnector branch + the robustness fixes in [README.md](README.md) | same |
| Router | llm-d inference gateway EPP: `token-producer` + `precise-prefix-cache-producer` (+ `p2p-source-producer` on the P2P arm) | same |
| Load generator | inference-perf (`shared_prefix` datagen), llm-d-benchmark harness | same |

Methodology notes that materially affect results:

* Every run is preceded by mechanism-engaged gates (prefix index populated,
  source header firing, `vllm:external_prefix_cache_hits_total` rising) and
  a full mesh warm-up (every directed pod pair exchanges one pull) so
  cold-session setup is excluded.
* `PYTHONHASHSEED` pinned fleet-wide; without it block hashes never match
  across pods and P2P silently measures zero.
* The EPP tokenizes every request via a render service; an under-provisioned
  render saturates and stalls every request for exactly the token-producer
  timeout, flattening all arms to the same false plateau
  ([llm-d-router#2025](https://github.com/llm-d/llm-d-router/issues/2025)).
  gpt-oss runs use 6-10 render replicas (~10 req/s capacity per replica at
  ~50K-token prompts); results below were re-measured after this fix.

## Scale-out: 16x gpt-oss-120b

### Pull versus recompute (single request)

Fresh prefix seeded on one pod, prefill latency measured on a cold pod with
and without the pull; 5-rep medians, warm mesh, unique prefix per rep.

| prefix tokens | recompute | P2P pull | delta |
|---|---|---|---|
| 2,048 | 70.6 ms | 49.0 ms | -31% |
| 8,192 | 205.4 ms | 120.1 ms | -42% |
| 16,384 | 426.3 ms | 196.2 ms | -54% |
| 32,768 | 983.0 ms | 376.3 ms | -62% |
| 49,152 | 1,695 ms | 550.5 ms | -68% |

![gpt-oss crossover](figures/gptoss-crossover.png)

The pull wins at every measured length: gpt-oss's compact KV (41.5 KB/token)
makes the transfer cheap enough to beat even its fast MoE prefill
(~29K tokens/s on H200), and the win grows with prefix length.

### Uniform pool (scenario A)

128 shared prefixes x 48K tokens (~6M-token working set, ~4.4x one pod's GPU
cache), 256-token questions, 64 output tokens, constant-rate stages 4-24
req/s x 60s. Uniform popularity is affinity's best case.

*(load+P2P arm rerunning; its column and the figure land here shortly)*

| offered | Affinity achieved / lat p50 | Load no-P2P achieved / lat p50 | Load+P2P achieved / lat p50 |
|---|---|---|---|
| 4 req/s | 3.8 / 2.4s | 3.8 / 4.2s | pending |
| 8 req/s | 7.9 / 0.7s | 6.7 / 6.5s | pending |
| 12 req/s | 11.9 / 0.7s | 9.0 / 24.9s | pending |
| 16 req/s | 15.8 / 0.7s | 8.8 / 37.3s | pending |
| 20 req/s | 19.8 / 0.7s | 9.4 / 48.8s | pending |
| 24 req/s | 23.7 / 0.8s | 9.4 / 63.5s | pending |

Affinity is near-ideal here (zero failures, flat sub-second p50): each of
the 16 pods owns ~8 of the 128 prefixes (384K tokens, comfortably within
its GPU cache), so a uniform pool with working affinity is all local hits.
The recompute arm saturates near 9.4 req/s - cross-pod placements
re-prefill 48K tokens each. The open question this scenario answers is how
much of that 2.5x gap the pull closes.

### Hot set, decode-heavy (scenario B)

8 shared prefixes x 48K tokens, 256-token questions, 512-token outputs,
stages 12/24/36/48 req/s x 60s. The hot set fits in every pod's GPU cache
(8 x 48K = 384K of ~1.38M tokens), so cache capacity does not differentiate
the arms - decode-load concentration does: affinity funnels everything into
the 8 owner pods while half the fleet idles; load+P2P serves the same hot
content from all 16 pods (each pod pulls each prefix once - ~5.9M tokens
over the mesh - then every request is a local hit).

| offered | Affinity achieved / lat p50 / fails | Load+P2P achieved / lat p50 / fails |
|---|---|---|
| 12 req/s | 9.9 / 11.8s / 0 | 11.3 / 5.6s / 0 |
| 24 req/s | 14.7 / 27.0s / 0 | 20.9 / 9.6s / 0 |
| 36 req/s | 15.3 / 53.8s / 0 | 29.1 / 15.9s / 0 |
| 48 req/s | 13.1 / 75.3s / 672 | 34.3 / 26.0s / 0 |

![gpt-oss hot set](figures/gptoss-scenarioB3.png)

The owner pods cap near 15 req/s aggregate and shed 672 requests to the
120s client timeout at offered 48; load+P2P takes 2.6x the throughput at
roughly one-third the latency with zero failures (7,200/7,200 in each arm
served, 0 restarts). TTFT stays under 1s p50 in both arms - the collapse is
pure decode concentration, which is exactly the pathology the pull
relieves: hot content scales horizontally without recompute.

At short outputs and moderate rates the same hot set shows no arm
difference (affinity holds ~0.33s TTFT p50 flat to 24 req/s, zero fails) -
a hot-set scenario below owner saturation measures headroom, not a
pathology.

## Small scale: 4x Llama-3.1-8B-Instruct

### Pull versus recompute (single request)

| prefix tokens | recompute | P2P pull | delta |
|---|---|---|---|
| 1,024 | 30 ms | 34 ms | +11% |
| 4,096 | 99 ms | 59 ms | -41% |
| 8,192 | 236 ms | 88 ms | -63% |
| 16,384 | 503 ms | 155 ms | -69% |

![Llama crossover](figures/llama-crossover.png)

The crossover sits near 2K tokens (hence `minCachedTokenDelta: 2048`);
Llama's larger per-token KV makes recompute relatively cheaper at very
short prefixes than on gpt-oss.

### One hot 16K prefix

Ramped to 24 req/s: affinity concentrates all 5,040 requests on the prefix
owner and saturates it (p50 6.1s), load-balanced routing holds p50 0.53s -
an 11x win from placement alone. P2P adds nothing for a single persistent
prefix (each pod recomputes once, it stays resident); its role is making
load-balanced routing safe when prefixes do not fit everywhere - the pool
scenarios below.

![Llama hot prefix](figures/llama-hotspot.png)

### Shared-prefix pool: 64 x 16K (128 GiB KV pool)

Moderate rates, load-balanced placement, no-P2P vs P2P (identical routing;
the only difference is pull versus recompute on cross-pod placement):

| rate | no-P2P p50 / p95 | P2P p50 / p95 | TTFT p50, P2P vs no-P2P |
|---|---|---|---|
| 2 req/s | 0.94s / 2.38s | 0.93s / 1.65s | 0.40s vs 0.57s |
| 4 req/s | 1.12s / 2.76s | 0.93s / 2.14s | 0.42s vs 0.57s |
| 6 req/s | 1.53s / 4.62s | 1.07s / 2.62s | 0.56s vs 0.59s |
| 8 req/s | 2.49s / 6.41s | 1.41s / 3.72s | 0.59s vs 0.79s |

![Llama pool latency](figures/llama-pool-latency.png)

Saturation behavior at high rates:

| offered | no-P2P achieved / p50 lat | P2P achieved / p50 lat |
|---|---|---|
| 12 req/s | 9.9 / 12.2s | 11.6 / 2.1s |
| 16 req/s | 10.3 / 21.3s | 12.6 / 7.8s |
| 20 req/s | 10.1 / 34.3s | 11.6 / 24.6s |
| 24 req/s | 10.4 / 44.1s | 11.3 / 36.4s |

![Llama saturation](figures/llama-saturation.png)

P2P raises the saturation ceiling ~22% (12.6 vs 10.3 req/s achieved) with
up to 83% lower p50 in the 12-16 req/s band, and 30% higher peak token
throughput (3,184 vs 2,420 tok/s).

### P/D disaggregation: prefill placement

4 prefill + 1 decode, NIXL between the legs, same pool workload, three
prefill-placement arms. Affinity placement saturates at ~15.7 req/s (the
single decode pod's KV intake is the topology's ceiling, not prefill
placement). Load-aware placement without P2P is recompute-bound at ~11.3
req/s (p50 33s); adding the pull recovers the decode-bound ceiling: ~14.7
req/s (+30%), p50 5.6s vs 12.2s at 16 req/s. Zero failures and restarts
across all three arms (15,123 requests).

![Llama P/D placement](figures/llama-pd-placement.png)
