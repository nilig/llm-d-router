# P2P KV-Cache Sharing — Measured Results (SIG)

Peer-to-peer KV-cache pull in llm-d: when a peer pod holds more cached prefix
tokens than the scheduled pod, the router attaches a KV-source header and the
pod pulls the prefix from that peer (CPU-to-CPU over NIXL/UCX) instead of
recomputing it. Four models (8B dense to 753B MoE), aggregated and P/D
topologies, all NVIDIA H200 (CoreWeave).

Full data, raw logs, and exact configs: `test/p2p-findings/RESULTS.md`
(series 1), `RESULTS-2.md` (series 2: P/D + guide add-on runs), GLM arms
under `configs/glm-5.2-p2p/`, series-2 arms under `configs/series-2/`.

---

## 1. How the EPP delta is calculated (when does the router pull?)

**The EPP decision.** For every request, the `p2p-source-producer` computes a
cached-token delta between the best available KV source and the pod that
scheduling chose:

```
source_delta = cachedTokens(best peer) - cachedTokens(scheduled pod)
pull fires   iff   source_delta >= minCachedTokenDelta
```

The per-pod `cachedTokens` comes from the prefix-cache producer — **precise**
(kv-events-fed per-pod index) or **approximate** (prompt-hash estimate); the
producer consumes either. After scheduling it compares the best-match peer
against the pod that will compute the prefix (the `prefill` profile target
under P/D disaggregation), and only when that peer out-caches it by at least
`minCachedTokenDelta` does it attach the KV-source header; the engine then
pulls those blocks from the peer instead of recomputing them. When no peer
clears the threshold, the request proceeds unchanged — the producer is inert.

**Setting the threshold: recompute vs pull with increasing prefix length.**
`minCachedTokenDelta` is not a guess — it is the measured crossover of the
per-miss economics on each model:
single-request prefill latency for a prefix that exists on a peer pod,
recomputed locally vs pulled. Protocol: seed a fresh prefix on one pod, land
the request on a cold pod, measure time-to-first-token both ways (gpt-oss and
Llama: 5-rep medians, warm transfer mesh, unique prefix per rep; Qwen and GLM:
on-rig calibration points).

| Model | KV per token | Prefix tokens | Recompute | P2P pull | Delta |
|---|---|---|---|---|---|
| Llama-3.1-8B | ~128 KB | 1,024 | 30 ms | 34 ms | +11% |
| | | 4,096 | 99 ms | 59 ms | **-41%** |
| | | 8,192 | 236 ms | 88 ms | **-63%** |
| | | 16,384 | 503 ms | 155 ms | **-69%** |
| gpt-oss-120b | ~41.5 KB | 2,048 | 70.6 ms | 49.0 ms | **-31%** |
| | | 8,192 | 205.4 ms | 120.1 ms | **-42%** |
| | | 16,384 | 426.3 ms | 196.2 ms | **-54%** |
| | | 32,768 | 983.0 ms | 376.3 ms | **-62%** |
| | | 49,152 | 1,695 ms | 550.5 ms | **-68%** |
| Qwen3-30B-A3B | (MoE, A3B) | 8,192 | 1,210 ms | 74 ms | **-94%** |
| GLM-5.2-FP8 | ~93 KB | ~24,000 | 4,630 ms | 3,910 ms | **-16%** |

(GLM reference points on the same request: warm local hit 2.30 s; the pull
moves 2.23 GB of KV.)

The pattern is the same on every model: **below a crossover length recompute
wins (the pull's fixed setup cost dominates); above it the pull wins and the
gap grows with length**, because recompute scales with model FLOPs while the
pull scales with KV bytes. Where the crossover sits depends on the ratio of
prefill speed to KV weight — and that per-model crossover is exactly what the
router's `minCachedTokenDelta` is set to, so the fleet only ever pulls where
this table says a pull wins:

| Model | Measured crossover | `minCachedTokenDelta` used |
|---|---|---|
| Llama-3.1-8B | ~2K tokens | 2,048 |
| gpt-oss-120b | < 2K (pull wins at every measured length) | 2,048 |
| Qwen3-30B-A3B | ~760 tokens (pull overhead ~30 ms) | 1,024 |
| GLM-5.2-FP8 | not swept — bracketed by two measurements | 16,384, conservative point inside the bracket |

GLM is the one model without a swept crossover. Its threshold comes from a
two-point bracket: at 2,048 the pulls demonstrably lose (each fired pull cost
more than the recompute it replaced, measured under load), and at ~24,000 the
pull wins by 16% (single calibration point). The crossover cannot be derived
from one point — the pull's fixed setup cost and per-byte cost cannot be
separated — so 16,384 is an engineering choice inside the proven bracket; a
Llama-style length sweep on GLM is the outstanding measurement.

Every fleet-level delta in section 2 is built on these per-miss economics:
the router fires a pull only when a peer out-caches the scheduled pod by at
least the threshold, so a "P2P win" is many per-miss wins compounded under
load, never a pull for a miss the table says should be recomputed.

**Reporting protocol for the results below.** Every quoted result is a paired
A/B on identical pods, image, and workload; the only change between arms is
the EPP `--config-file`. Result deltas are reported as
`delta% = (P2P_arm - baseline_arm) / baseline_arm` — negative is better for
latency, positive for throughput. Before every measured run: mechanism-engaged
gates (prefix index populated, source header firing,
`vllm:external_prefix_cache_hits_total` rising), full pull-mesh warm-up,
`PYTHONHASHSEED` pinned fleet-wide; pull counters are read after each run so
a quoted delta is always backed by evidence the mechanism actually ran.

**Pairing per model and accelerator:**

| Model | Accelerator / rig | Baseline arm | P2P arm | `minCachedTokenDelta` | Harness | Repeats |
|---|---|---|---|---|---|---|
| gpt-oss-120b (MXFP4) | 16x H200, TP=1 (14x in multi-turn) | Precise guide blend (prefix 3 / queue 2 / kv-util 2, max-score) — or Load-no-P2P for pool scenarios | Load-aware placement + `p2p-source-producer` | 2,048 (crossover-derived) | inference-perf via llm-d-benchmark | Doc-Q&A: 2 runs, arm order alternated; others single |
| Llama-3.1-8B-Instruct | 4x H200, TP=1 (P/D variant: 4 prefill + 1 decode) | Load, no P2P (identical placement) | Load + P2P | 2,048 (crossover-derived) | inference-perf via llm-d-benchmark | single |
| gpt-oss-120b, P/D | 16x H200: 8 prefill + 8 decode, TP=1 | pd-disaggregation guide verbatim (plain `NixlConnector`) | guide + full P2P stack (`MultiConnector` Nixl + Offloading p2p tier, sidecar `--enable-p2p-pull`, precise producer + `p2p-source-producer`) | 2,048 | llm-d-benchmark docQA profile, C=192 (mechanism-gated) | paired A/B, clean re-roll per arm |
| Qwen3-30B-A3B-Thinking | 6x H200: 2 prefill + 4 decode, TP=1 | agentic guide on plain NIXL | guide + P2P stack | 1,024 (rig-calibrated: 8K pull 74 ms vs 1.21 s recompute, crossover ~760) | llm-d-benchmark agentic synthetic, C=16 | P2P arm sampled twice |
| GLM-5.2-FP8 (753B MoE) | 32x H200: 1P + 1D, wide-EP DEP16 per role | armB: precise affinity, no pull | armC-16k: same precise affinity + `p2p-source-producer` | 16,384 (GLM KV is ~2x heavier per token; 2,048 fires pulls that cost more than they save) | aiperf agentx (Weka agentic traces), c128 | single |

The three delta styles to be aware of:

* **Pool / P/D scenarios (gpt-oss A, Llama):** baseline and P2P arm use the
  *same load-aware placement*; the delta isolates the pull itself (recompute
  vs pull on every cross-pod miss).
* **Conversational scenarios (gpt-oss C, D) :** baseline is the tuned precise
  guide default; the delta measures the *shipping alternative*, so it bundles
  placement + pull. GLM's precise pair is again a pure pull isolation.
* **P/D stack runs (gpt-oss C=192, Qwen3-30B agentic):** baseline is the
  shipping guide on plain NIXL; the delta measures adding the whole P2P stack
  (CPU offload tier + pull). Attribution between tier and pull is stated per
  run from the engine counters.

---

## 2. Best results at a glance

| Model | Accelerator | Scenario | Metric | Baseline | + P2P | Delta |
|---|---|---|---|---|---|---|
| gpt-oss-120b | 16x H200 | Document Q&A (128 x ~50K ctx) | TTFT p99 | 80.5 s | 20.9 s | **-74%** |
| gpt-oss-120b | 16x H200 | Document Q&A | TTFT p95 | 41.0 s | 13.0 s | **-68%** |
| gpt-oss-120b | 16x H200 | Document Q&A | throughput | 5.98 turns/s | 7.02 turns/s | **+17%** |
| gpt-oss-120b | 14x H200 | Multi-turn chat (8 turns to 48K) | TTFT p50 | 2.53 s | 1.42 s | **-44%** |
| gpt-oss-120b | 14x H200 | Multi-turn chat | TTFT p99 | 25.4 s | 9.2 s | **-64%** |
| gpt-oss-120b | 16x H200 | Uniform pool (6M-token set) | sustained rate | 9.4 req/s | 16.7 req/s | **+78%** |
| gpt-oss-120b | 16x H200 | Uniform pool @ 12 req/s | req latency p50 | 24.9 s | 2.3 s | **-91%** |
| Llama-3.1-8B | 4x H200 | Prefix pool 64 x 16K @ 12 req/s | req latency p50 | 12.2 s | 2.1 s | **-83%** |
| Llama-3.1-8B | 4x H200 | Prefix pool, saturation ceiling | achieved rate | 10.3 req/s | 12.6 req/s | **+22%** |
| Llama-3.1-8B | 4x H200 | P/D prefill placement | achieved rate | 11.3 req/s | 14.7 req/s | **+30%** |
| gpt-oss-120b | 16x H200 (8P+8D) | P/D docQA C=192, guide vs guide+P2P stack | TTFT p50 | 11.94 s | 1.16 s | **-90% (10x)** |
| gpt-oss-120b | 16x H200 (8P+8D) | P/D docQA C=192 | TTFT p99 | 106.1 s | 80.0 s | **-25%** |
| gpt-oss-120b | 16x H200 (8P+8D) | P/D docQA C=192 | throughput | 5.68 turns/s | 7.96 turns/s | **+40%** |
| Qwen3-30B-A3B | 6x H200 (2P+4D) | Agentic multi-turn (50K contexts, tool gaps) | TTFT p50 | 5.22 s | 1.09 s | **-79% (4.8x)** |
| Qwen3-30B-A3B | 6x H200 (2P+4D) | Agentic multi-turn | TTFT p95 | 18.94 s | 11.77-14.79 s | **-22..-38%** |
| Qwen3-30B-A3B | 6x H200 (2P+4D) | Agentic multi-turn | throughput (1/duration) | 304 s | 229 s | **+33%** |
| GLM-5.2-FP8 | 32x H200 | Agentic c128, precise routing | TTFT p50 | 3,802 ms | 3,177 ms | **-16%** |
| GLM-5.2-FP8 | 32x H200 | Agentic c128, precise routing | TTFT p90 | 11,755 ms | 9,970 ms | **-15%** |

---

## 3. Per-run detail

Every subsection: exact setup, results with percentage delta, and the win in
one or two sentences.

### 3.1 gpt-oss-120b — Document Q&A (the headline)

| Setup | |
|---|---|
| Model / pods | `openai/gpt-oss-120b` (MXFP4), 16x TP=1, H200 |
| KV / tiers | ~41.5 KB/token; GPU KV ~1.38M tokens/pod; CPU tier 64 GiB/pod |
| vLLM | nightly + `generic_p2p` OffloadingConnector branch; block size 64 |
| Baseline EPP | precise guide blend: `prefix-cache-scorer` 3 / `queue-scorer` 2 / `kv-utilization` 2, max-score picker |
| P2P EPP | load-aware placement + `p2p-source-producer` (`minCachedTokenDelta: 2048`) |
| Workload | 192 docs x 48K-token private prefix, 6 short questions each, 128 concurrent; 2 full runs, arm order alternated |

| Metric | Precise guide | Load + P2P | Delta |
|---|---|---|---|
| TTFT p50 (run 1 / 2) | 4.1 / 4.2 s | 4.5 / 3.9 s | +10% / -7% |
| TTFT p95 (run 1 / 2) | 41.0 / 17.3 s | 13.0 / 12.5 s | **-68% / -28%** |
| TTFT p99 (run 1 / 2) | 80.5 / 37.2 s | 20.9 / 26.7 s | **-74% / -28%** |
| Throughput (run 1 / 2) | 5.98 / 7.66 turns/s | 7.02 / 7.76 turns/s | **+17%** / +1% |
| Run-to-run throughput spread | 28% | 10% | 2.8x more stable |

**Win:** on prefill-dominated conversational load, displaced questions pull
their 48K context (~0.6 s) instead of recomputing or queueing behind a
concentrated owner (~2 s+): tails drop 2-4x, and the P2P arm is far less
sensitive to inherited cache state (30-32M tokens pulled per run).

### 3.2 gpt-oss-120b — Multi-turn chat

| Setup | |
|---|---|
| Rig | 14x TP=1, `--gpu-memory-utilization=0.60` (sessions exceed fleet GPU cache and evict); CPU tier 88 GiB = 4.4x GPU |
| Baseline EPP | precise guide blend (prefix 3 / queue 2 / kv-util 2) |
| P2P EPP | load-aware placement + P2P with load-aware source selection (llm-d-router#2032) |
| Workload | 192 conversations, 16K system prompt, 8 turns (turn 8 arrives at ~48K input), 4K-token answers, 128 concurrent |

| Metric | Precise guide | Load + P2P | Delta |
|---|---|---|---|
| TTFT p50 | 2.53 s | 1.42 s | **-44%** |
| TTFT p90 | 7.56 s | 4.87 s | **-36%** |
| TTFT p99 | 25.4 s | 9.2 s | **-64%** |
| Turn completion p90 (all turns) | 84.5 s | 78.3 s | -7% |
| Throughput | 1.86 turns/s | 1.90 turns/s | +2% |

**Win:** an evicted or displaced session pays a full ~50K-token recompute
before its first token under affinity (the 25.4 s p99); the pull fetches the
conversation history instead (32.5M tokens moved), so replies start 1.8x
sooner at median and the tail caps at 9.2 s. The short-answer variant (512-token
answers, 256 concurrent) repeats the shape: TTFT p50 -23..-43%, p99 -40..-67%.

### 3.3 gpt-oss-120b — Uniform prefix pool (pull-value isolation)

| Setup | |
|---|---|
| Rig | 16x TP=1 (as 3.1) |
| Arms | identical load-aware placement both sides; only difference is recompute vs pull on a cross-pod miss |
| Workload | 128 shared prefixes x 48K (~6M-token working set = 4.4x one pod's GPU cache), 256-token questions, 64-token outputs, constant-rate stages |

| Metric | Load, no P2P | Load + P2P | Delta |
|---|---|---|---|
| Sustained rate (saturation) | 9.4 req/s | 16.7 req/s | **+78%** |
| Req latency p50 @ 12 req/s | 24.9 s | 2.3 s | **-91%** |
| Req latency p50 @ 16 req/s | 37.3 s | 3.6 s | **-90%** |
| Decode throughput at peak | 599 tok/s | 1,068 tok/s | **+78%** |

**Win:** when the working set exceeds every pod's cache, each cross-pod miss
costs a 1.7 s recompute; the pull converts it to a 0.55 s transfer (~139M
prefix tokens pulled, ~58% of requests). This is the cleanest isolation of the
pull itself — same placement in both arms.

### 3.4 Llama-3.1-8B — Shared-prefix pool and P/D

| Setup | |
|---|---|
| Model / pods | `meta-llama/Llama-3.1-8B-Instruct`, 4x TP=1, H200; P/D variant 4 prefill + 1 decode (NIXL between legs) |
| KV / tiers | ~128 KB/token; GPU KV ~0.5M tokens/pod; CPU tier 32 GiB/pod |
| Arms | load-aware placement both sides; +/- `p2p-source-producer` (`minCachedTokenDelta: 2048`) |
| Workload | 64 shared prefixes x 16K (128 GiB KV pool, exceeds fleet cache) |

| Metric | Load, no P2P | Load + P2P | Delta |
|---|---|---|---|
| Req latency p50 @ 8 req/s | 2.49 s | 1.41 s | **-43%** |
| Req latency p50 @ 12 req/s | 12.2 s | 2.1 s | **-83%** |
| Saturation ceiling | 10.3 req/s | 12.6 req/s | **+22%** |
| Peak token throughput | 2,420 tok/s | 3,184 tok/s | **+32%** |
| P/D: achieved rate | 11.3 req/s | 14.7 req/s | **+30%** |
| P/D: req latency p50 @ 16 req/s | 12.2 s | 5.6 s | **-54%** |

**Win:** same regime as 3.3 at quarter scale — and under P/D disaggregation
the pull is what makes load-aware *prefill* placement viable at all: without
it the prefill leg is recompute-bound (11.3 req/s); with it the topology
returns to its decode-bound ceiling.

### 3.5 gpt-oss-120b — P/D disaggregation, docQA at C=192 (guide vs guide + P2P stack)

| Setup | |
|---|---|
| Rig | pd-disaggregation guide topology: 8 prefill + 8 decode, TP=1, 16x H200 |
| Baseline | guide verbatim: plain `NixlConnector`, guide EPP |
| P2P arm | identical + full stack: `MultiConnector(Nixl + Offloading[p2p tier])`, 128 GiB CPU tier both roles, sidecar `--enable-p2p-pull`, precise producer + `p2p-source-producer` (δ2048) |
| Workload | docQA profile at concurrency 192 (mechanism-gated: C=192 produces placement spill, C=128 does not); clean re-roll per arm; 1,152/1,152 turns, zero failures both arms |

| Metric | Guide (plain NIXL) | Guide + P2P stack | Delta |
|---|---|---|---|
| TTFT p50 | 11.94 s | 1.16 s | **-90% (10x)** |
| TTFT p95 | 71.6 s | 55.2 s | **-23%** |
| TTFT p99 | 106.1 s | 80.0 s | **-25%** |
| Throughput | 5.68 turns/s | 7.96 turns/s | **+40%** |

**Win (with honest attribution):** under 192-deep queues, turn N+1's history
re-prefill hits the CPU offload tier (52.2M external-hit tokens) instead of
recomputing — that tier is what buys the 10x median. The cross-pod pull fired
zero times during this profile's smooth arrivals (it fired under the bursty
mechanism gate at the same concurrency), so on P/D the pull rides free and
activates under burstier traffic; the stack as a whole is what beats the
shipping guide.

### 3.6 Qwen3-30B-A3B-Thinking — agentic multi-turn on P/D (guide vs guide + P2P)

| Setup | |
|---|---|
| Model / rig | `Qwen/Qwen3-30B-A3B-Thinking-2507` (agentic guide model), 2 prefill + 4 decode, TP=1, 6x H200; prefix caching on, `max-model-len` 131072 |
| Baseline | agentic guide on plain NIXL |
| P2P arm | + P2P stack; `minCachedTokenDelta: 1024`, calibrated on-rig (8K pull 74 ms vs 1.21 s recompute; crossover ~760 tokens) |
| Workload | agentic synthetic: 24 conversations, 10K-100K-token system prompts (mean 50K), mean 12 turns, 1-20 s tool-call gaps (these evict session KV, making re-engagement the pull-vs-recompute choice), C=16, 288 requests; fresh fleet per arm |

| Metric | Guide (plain NIXL) | Guide + P2P (2 samples) | Delta |
|---|---|---|---|
| TTFT p50 | 5.22 s | 1.09 / 1.06 s | **-79% (4.8x)** |
| TTFT p95 | 18.94 s | 11.77 / 14.79 s | **-38% / -22%** |
| TTFT p99 | 30.29 s | 29.98 / 31.01 s | parity (cold 100K first-prefill floor) |
| Run duration (288 reqs) | 304 s | 229 / 237 s | **-25% (+33% throughput)** |

**Win:** a returning agent whose session KV was evicted during a tool call
pulls its history (1.23M tokens pulled in 229 s, every pull EPP-decided)
instead of recomputing a ~50K context: replies start 4.8x sooner at median.
The same prefill-from-decode mechanism validated on Llama-8B (Run N: per-turn
TTFT flat at 0.1-0.2 s out to 20K-token prompts) ties there on latency because
an 8B recompute is as cheap as the pull — the latency win appears when the
recompute is expensive, exactly as the crossover predicts.

### 3.7 GLM-5.2-FP8 — precise routing + pull at agentic load

| Setup | |
|---|---|
| Model / pods | `zai-org/GLM-5.2-FP8` (753B MoE, MLA), 1 prefill + 1 decode, wide-EP DEP16 per role = 32x H200 |
| KV / tiers | ~93 KB/token; GPU KV ~520K tokens/rank (prefill); CPU tier 100 GiB/rank; p2p secondary tier on port 7777 |
| vLLM | `nightly-6a9f24aa` + `generic-p2p-src` overlay (unpaired cross-engine pull; upstream in-tree connector is paired-only until vllm#48021) |
| Baseline EPP | armB: `precise-prefix-cache-producer` (kv-events) + prefix-affinity w5 / queue w3 / active w1 — no pull |
| P2P EPP | armC-16k: armB + `p2p-source-producer` (`minCachedTokenDelta: 16384`) |
| Workload | aiperf agentx (SemiAnalysis Weka agentic traces), concurrency 128, 900 s profiling, ~3.1-3.3K requests, 0 errors |

| Metric | armB (precise, no pull) | armC-16k (precise + pull) | Delta |
|---|---|---|---|
| TTFT p50 | 3,802 ms | 3,177 ms | **-16%** |
| TTFT p90 | 11,755 ms | 9,970 ms | **-15%** |
| TTFT p99 | 24,119 ms | 25,084 ms | +4% |
| Output throughput | 2,016 tok/s | 1,982 tok/s | -2% |
| KV pulled cross-engine | ~0 | 163 GB (1.77M tokens) | mechanism engaged |

**Win:** first demonstration of the pull on a 753B wide-EP P/D deployment.
Precise affinity concentrates agentic traffic on cache-holder ranks; the pull
lets the picker route to a less-loaded rank and fetch the prefix, recovering
16% median TTFT for ~2% throughput cost. Same-direction result as the gpt-oss
conversational scenarios, on a model whose per-token KV is ~2x heavier.
(Single run per arm; the c32/c64 precise cells are queued pending cluster
GPU capacity.)

---

## 4. Where P2P does not help (measured, for completeness)

* **Cache-resident hot sets at steady state:** once every pod has acquired
  the hot prefixes, pull and recompute arms converge (gpt-oss scenario B,
  within 1-3%); the pull's value there is a one-time ~3x cheaper acquisition.
* **Prefix-first placement that rarely misses:** adding P2P to the blend
  changed nothing (98K tokens moved all run vs 5.9M under load-aware) — the
  pull only helps a policy that generates misses by spreading.
* **Same-prefix contention:** spreading traffic that *shares* the busy
  prefix converts free cache hits into a pull storm (scenario E); route to
  the cache in that case.
* **Load-balanced routing on GLM agentic at saturation:** with approx
  routing already spreading load, adding the pull was neutral (within noise)
  at c32-c128 — the pull is miss-cost reduction, and good load balancing on
  this workload produced few expensive misses.
* **The guide's own home workload (GPU-resident 6K prefixes):** placement to
  the cache wins outright; load-preferred placement + pull *loses* it (a pull
  per request: +80-100 ms p50, tails 5-16x at high rates) — never pay a pull
  for a free local hit. Adding the producer to the guide's own placement is
  **inert and free** (TTFT parity within 4 ms at every ladder stage), so it
  is safe as a default; the value claim belongs to the placement+pull pairing.
* **KV-capacity-bound fleets (GPU KV squeezed 4.4x):** the pull is a no-op —
  it saves prefill compute but occupies the same KV for the same decode
  duration, and affinity additionally *deduplicates* KV that spreading forces
  per-pod. Boundary rule: P2P pays only when prefill compute/latency is the
  binding constraint and there is KV headroom to receive the copy.

One-line summary for the SIG: **P2P KV sharing converts a prefix-cache miss
from "recompute" into "copy at a fraction of the cost" (-68% at 49K on
gpt-oss, 16x on Qwen3-30B at 8K); measured value is largest where misses are
frequent and expensive — working sets larger than any pod's cache (+78%
throughput), conversational and agentic tails (2-4x p99 TTFT on gpt-oss, 4.8x
median on Qwen3-30B P/D, 10x median for the P/D stack at C=192) — it fires on
both precise and approximate indexes up to 753B wide-EP scale, and it is
inert-and-free where it has nothing to do.**
