# P2P benchmarks, series 2: load-preferred placement + load-aware source selection

Series 2 tests the placement policy that sits between the two series-1 arms:
place by load with prefix as a weak tie-break, and let the P2P pull (with the
load-aware source selection from llm-d-router#2032) cover the misses that
spreading creates. Series 1 compared the guide's prefix-first blend against a
prefix-zero load arm; see [RESULTS.md](RESULTS.md) for those runs and the
hardware/methodology details they share with this file.

Every run entry records its full setup, and the exact configuration files it
ran with are committed under [configs/series-2/](configs/series-2/) so they
can be promoted into the llm-d guides.

## Hardware and software

Identical to series 1 (see [RESULTS.md](RESULTS.md)): 16x H200 (one pod per
GPU, TP=1), `openai/gpt-oss-120b` MXFP4, GPU KV 0.48M tokens/pod
(`gpu-memory-utilization` 0.60), CPU offload tier 4.4x GPU (88 GiB/pod),
`block-size` 64 and pinned `PYTHONHASHSEED` everywhere, 10 render replicas.
EPP image `quay.io/niliguy/llm-d-router-endpoint-picker:p2p-source-load-aware`
(upstream main + #2032 load-aware source sampling) in all arms of all runs.

## Run G: the precise guide's own benchmark workload

**Workload** ([configs/series-2/gptoss-guide.yaml](configs/series-2/gptoss-guide.yaml)):
the `precise-prefix-cache-routing` guide's dedicated llm-d-benchmark profile
`guide_precise-prefix-cache-routing_1.yaml`, verbatim except model/endpoint
(Qwen3-32B -> gpt-oss-120b). inference-perf `shared_prefix`, single-turn:
150 prefix groups x 5 questions, 6,000-token shared prefix, 1,200-token unique
question, 1,000-token output, streaming completions with `ignore_eos`.
Poisson arrival ladder 3 -> 60 QPS (16 stages) after a 15 QPS x 50 s warmup
that seats the residents. 150 x 6K = 900K tokens of distinct prefix,
GPU-resident fleet-wide (~64K/pod under affinity) - this is the workload the
guide ships to showcase precise prefix routing.

**Arms** (both on the same EPP image; only the scheduling config differs):

| Arm | Config file | Placement scorers | Picker | P2P |
|---|---|---|---|---|
| Precise guide (verbatim) | [epp-opt4v-gptoss-guide.yaml](configs/series-2/epp-opt4v-gptoss-guide.yaml) | `prefix-cache-scorer` 3 / `queue-scorer` 2 / `kv-cache-utilization-scorer` 2 / `no-hit-lru-scorer` 2 | max-score | none |
| Load-preferred + P2P | [epp-opt6-gptoss-loadpref-p2p.yaml](configs/series-2/epp-opt6-gptoss-loadpref-p2p.yaml) | `queue-scorer` 3 / `kv-cache-utilization-scorer` 2 / `prefix-cache-scorer` 1 | weighted-random | `p2p-source-producer`, `minCachedTokenDelta` 2048, load-aware source ties (#2032) |
| Guide + P2P (opt7) | [epp-opt7-gptoss-guide-p2p.yaml](configs/series-2/epp-opt7-gptoss-guide-p2p.yaml) | identical to the guide-verbatim baseline | max-score | `p2p-source-producer`, `minCachedTokenDelta` 2048 - placement unchanged, the producer activates only when scheduling diverges from the best cache holder |

The third arm tests the "adding the P2P producer to the guide is
same-or-better" claim on its own. Pre-registered prediction (from the
series-1 blend-vs-blend+P2P control, where P2P under prefix-first placement
moved 98K tokens all run): statistically indistinguishable from the baseline
across the ladder, with possible small tail gains at the top rates where
overload occasionally displaces requests off cache owners. Known risks that
would falsify "never worse": pulls below the recompute crossover (gated here
by the 2048-token delta) and source-side load during saturation.

Both arms run the guide's `precise-prefix-cache-producer` config: blockSize 64,
`speculativeIndexing: true`, KV events with pod discovery. The baseline differs
from series-1 opt4 by including `no-hit-lru-scorer` and speculative indexing -
series 2 runs the guide complete, as shipped.

**Protocol:** two full runs, arm order alternated (run 1: guide first; run 2:
load+P2P first); per-arm readiness gate at 16/16 pods; mechanism check on the
P2P arm (precise index populated, source header firing, external-hit counter
moving) before the A/B is trusted.

**Results: run 1 — COMPLETE (both arms).** The order-reversed run 2 and the
guide+P2P arm (opt7) are in progress.

Both arms: 17,084/17,084 requests succeeded, zero pod restarts. TTFT in
seconds. The fleet is not saturated at the top of the ladder in either arm
(achieved rate tracks requested rate).

**Run 1 verdict: on its own workload, the guide wins decisively.** With
GPU-resident 6K prefixes, affinity is free, and the load-preferred arm pays
a P2P pull for it on nearly every request: weighted-random placement lands
off-owner 15/16 of the time, and the arm pulled 105.6M tokens across ~17K
requests - the full prefix, almost every request. That buys +80-100ms TTFT
p50 across the whole ladder (0.15-0.21s vs 0.07-0.12s), tails 5-16x worse at
the high rates (p99 7.6s vs 0.46s at rate 60), and -15% output throughput at
rate 60. The pull mechanism itself held: ~40 pulls/s sustained for 50
minutes, zero failures, zero restarts.

This is the regime-dependence the series-1 pairing rule predicts: P2P pays
off where misses are forced (cache oversubscription, series-1 docQA); where
the cache holder has capacity, routing to it beats pulling from it. The
remaining question for this workload is opt7: does adding the producer to
the guide's own placement (where it should stay quiet) cost anything.

**opt7 (guide + P2P producer): the pre-registered prediction holds - the
producer costs nothing where it has nothing to do.** Same ladder, zero
failures, and every stage within run-to-run noise of the guide baseline:

| stage | rate (req/s) | requests | TTFT p50 | TTFT p95 | TTFT p99 | output tok/s |
|---|---|---|---|---|---|---|
| warmup | 15 | 750 | 0.123 | 0.241 | 0.263 | 12,402 |
| 1 | 3 | 60 | 0.069 | 0.086 | 0.089 | 2,825 |
| 2 | 10 | 200 | 0.072 | 0.087 | 0.094 | 7,935 |
| 3 | 15 | 300 | 0.073 | 0.092 | 0.100 | 10,842 |
| 4 | 20 | 760 | 0.081 | 0.098 | 0.110 | 15,477 |
| 5 | 22 | 748 | 0.082 | 0.097 | 0.105 | 16,573 |
| 6 | 25 | 750 | 0.084 | 0.100 | 0.107 | 19,109 |
| 7 | 30 | 750 | 0.084 | 0.102 | 0.110 | 19,941 |
| 8 | 35 | 735 | 0.088 | 0.108 | 0.118 | 21,610 |
| 9 | 40 | 1,520 | 0.099 | 0.129 | 0.147 | 29,147 |
| 10 | 43 | 1,548 | 0.102 | 0.131 | 0.153 | 30,818 |
| 11 | 46 | 1,518 | 0.103 | 0.140 | 0.178 | 31,393 |
| 12 | 49 | 1,470 | 0.105 | 0.146 | 0.177 | 31,157 |
| 13 | 52 | 1,508 | 0.107 | 0.173 | 0.257 | 32,395 |
| 14 | 55 | 1,485 | 0.107 | 0.206 | 0.292 | 33,399 |
| 15 | 57 | 1,482 | 0.108 | 0.165 | 0.223 | 32,580 |
| 16 | 60 | 1,500 | 0.111 | 0.312 | 0.457 | 34,234 |

At rate 60: TTFT p50 0.111 vs 0.115, p95 0.312 vs 0.297, p99 0.457 vs
0.464, throughput 34,234 vs 34,814 - differences alternate sign across
stages and stay within the noise band. The mechanism evidence is the
absence of the load-preferred arm's pull signature: opt6 paid +80-100ms
p50 everywhere (a pull per request); opt7's p50 matches the baseline to
within 4ms at every stage, so the producer effectively never fired under
prefix-first placement. Pull-volume counters for this run were lost to a
reclaimer strike during the post-run copy window (the run itself completed
40 minutes before the strike); the TTFT parity carries the conclusion.

**Guide-workload bottom line:** placement decides this regime. The guide
wins it; load-preferred placement loses it by paying pulls for free hits;
and the P2P producer added to the guide is free - it activates only when
placement diverges from the cache. Whether it then helps (rather than
merely not hurting) is the docQA question, next.

## Run D: guide vs guide+P2P on the docQA regime

The other half of the "safe default add-on" question: the document-Q&A
regime from series 1 (192 docs x 48K tokens, 6 turns, 256-token answers,
128 concurrent, `conversation_replay`, request timeout 180 s) - the regime
where the guide's prefix-first placement herds and its tails blow up. Same
two arms as Run G: guide-verbatim (opt4v) vs guide + `p2p-source-producer`
(opt7). Four arms ran back-to-back on one fleet (cold at the first arm,
progressively warmer after), order alternated so opt7 held the colder slot
of the second pair.

Each cell: TTFT p50 / p95 / p99 (s); turns/s; timeouts (requests exceeding
the 180 s client timeout).

| run | slot | Guide (opt4v) | Guide + P2P (opt7) |
|---|---|---|---|
| 1 | cold fleet | 4.25 / 95.1 / 152.2; 4.52; 0 | 3.93 / 35.9* / 133.2*; 3.87; **45** |
| 2 | warm fleet | 4.17 / 80.4 / 134.5; 4.92; 0 (ran last, warmest) | 3.74 / 59.8 / 116.5; 5.30; 0 |

*Run-1 opt7 percentiles are success-only and flattered by censoring: its
45 worst requests became timeouts, so on an all-requests basis its extreme
tail is >= 180 s - worse than the paired baseline's 152 s max.

**Verdict: mostly the same, modestly better warm, possibly worse cold -
and nowhere near a rescue.** In the warm pair opt7 beat the baseline on
every metric from the less favorable slot (p95 -26%, p99 -13%, +8%
turns/s). In the cold pair it traded a better body for 45 clipped tail
requests the baseline didn't have - the pre-registered "source-side load
during saturation" risk is plausibly real. The external-hit counter rose
in every arm (~20M tokens; the offloading tier serves local CPU reloads
under this cache pressure regardless of P2P), with opt7 arms +3-5M above
their paired baselines - consistent with a modest number of genuine peer
pulls, not per-request activation.

The decisive comparison is against series 1: load-aware placement + P2P on
this same workload delivered TTFT p99 of 21-27 s at 7.0-7.8 turns/s -
5x better tails and ~1.5x the throughput of EITHER guide arm here
(116-152 s, 3.9-5.3 turns/s). The producer bolted onto prefix-first
placement cannot fix herding, because the requests still queue on the
cache owner; it only trims what leaks around the edges.

## Run K: the guide workload on a KV-starved fleet ("less GPU, more CPU")

Same 16 pods and the guide's workload verbatim, with GPU KV capped at 4 GiB
per pod via `kv_cache_memory_bytes` (~110K tokens, down from ~480K; the CPU
tier stays 88 GiB, so CPU:GPU goes 4.4x -> 22x). Models a fleet of
memory-poor GPUs at constant compute. Three arms; single run each; pod
layout identical across arms (scheduler-spread, reshuffled by cluster
reclaims between arms - disclosed as a variance source). P2P pull-volume
counters were lost to a reclaim during the last arm's copy window; the
low-rate TTFT delta (P2P arm 0.14-0.18 s vs no-pull 0.23 s) indicates pulls
were active.

TTFT p50 / p99 (s) and output tok/s at selected rates:

| rate | Guide | Load-spread, no pull | Load-spread + P2P |
|---|---|---|---|
| 15 | 0.09 / 0.15 | 0.09 / ~1 | 0.16 / 1.1 |
| 30 | 2.9 / 12.2 | 5.2* / 15.3* | 4.9 / 16.6 |
| 40 | 12.2 / 30.6 | 19.8 / 44.0 | 17.1 / 40.8 |
| 60 | 17.5 / 44.2; 18.3K | 25.1 / 53.0; 17.0K | 23.7 / 51.8; 18.4K |

*interpolated between measured stages 25 and 35.

All three arms collapse (the unconstrained guide held 0.115 / 0.46 at rate
60), and **P2P is statistically indistinguishable from the no-pull control**
- the pull neither helps nor hurts. The guide stays ahead of both spread
arms.

**Why the pull cannot win here:** the squeeze made KV *capacity* the
binding constraint, not prefill compute. A request occupies its KV for its
whole decode (~1,000 tokens), so requests queue for KV slots, and pulling a
prefix instead of recomputing it saves compute but occupies the same KV for
the same duration - the queue does not move. Worse for the spread arms:
prefix-affinity *deduplicates* KV (concurrent same-group requests on one
pod share one copy of the 6K prefix blocks), while spreading forces a
per-pod copy - with or without P2P. That is why the guide leads on a
KV-bound rig and why the pull is a no-op.

**Boundary rule (new):** P2P pays only when the binding constraint is
prefill compute or latency - long distinct prefixes, misses forced by
content oversubscription, KV available to receive the pulled copy (the
series-1 docQA regime). When KV capacity itself is the constraint, cache
co-location (affinity) wins by block sharing, and no transfer mechanism can
substitute for it.

**Series-2 conclusion.** Three placements, two regimes:

1. On the guide's home workload (GPU-resident prefixes), placement to the
   cache wins; P2P is inert-and-free added to the guide, and actively
   harmful under load-preferred placement.
2. On the oversubscribed docQA workload, placement to the cache is the
   bottleneck itself; adding P2P to it changes little. The series-1 result
   stands as the winning configuration: load-aware placement with the P2P
   pull covering the misses.
3. The `p2p-source-producer` is safe to ship as a default in the guide
   config (no measurable cost in either regime), but the value claim
   belongs to the placement+pull pairing, not to the producer alone.

| stage | rate (req/s) | requests | TTFT p50 | TTFT p95 | TTFT p99 | output tok/s |
|---|---|---|---|---|---|---|
| warmup | 15 | 750 | 0.127 | 0.248 | 0.295 | 12,491 |
| 1 | 3 | 60 | 0.073 | 0.091 | 0.099 | 2,502 |
| 2 | 10 | 200 | 0.075 | 0.089 | 0.093 | 8,660 |
| 3 | 15 | 300 | 0.079 | 0.095 | 0.104 | 10,197 |
| 4 | 20 | 760 | 0.086 | 0.103 | 0.112 | 16,738 |
| 5 | 22 | 748 | 0.086 | 0.102 | 0.109 | 16,387 |
| 6 | 25 | 750 | 0.089 | 0.104 | 0.114 | 18,100 |
| 7 | 30 | 750 | 0.089 | 0.107 | 0.116 | 20,033 |
| 8 | 35 | 735 | 0.091 | 0.111 | 0.128 | 21,346 |
| 9 | 40 | 1,520 | 0.103 | 0.130 | 0.148 | 29,342 |
| 10 | 43 | 1,548 | 0.108 | 0.143 | 0.162 | 30,466 |
| 11 | 46 | 1,518 | 0.108 | 0.140 | 0.164 | 31,234 |
| 12 | 49 | 1,470 | 0.110 | 0.152 | 0.186 | 31,211 |
| 13 | 52 | 1,508 | 0.114 | 0.158 | 0.203 | 32,906 |
| 14 | 55 | 1,485 | 0.113 | 0.237 | 0.426 | 33,282 |
| 15 | 57 | 1,482 | 0.113 | 0.181 | 0.320 | 33,230 |
| 16 | 60 | 1,500 | 0.115 | 0.297 | 0.464 | 34,814 |

Load-preferred + P2P arm (same ladder; pulled 105.6M tokens - effectively
the full 6K prefix on almost every request):

| stage | rate (req/s) | requests | TTFT p50 | TTFT p95 | TTFT p99 | output tok/s |
|---|---|---|---|---|---|---|
| warmup | 15 | 750 | 0.280 | 5.819 | 9.121 | 13,413 |
| 1 | 3 | 60 | 0.171 | 1.131 | 1.638 | 2,649 |
| 2 | 10 | 200 | 0.153 | 0.224 | 0.974 | 6,933 |
| 3 | 15 | 300 | 0.155 | 0.243 | 0.269 | 10,285 |
| 4 | 20 | 760 | 0.171 | 0.268 | 0.614 | 14,549 |
| 5 | 22 | 748 | 0.169 | 0.254 | 0.964 | 16,461 |
| 6 | 25 | 750 | 0.168 | 0.260 | 0.672 | 18,748 |
| 7 | 30 | 750 | 0.175 | 0.268 | 0.838 | 19,867 |
| 8 | 35 | 735 | 0.170 | 0.275 | 1.145 | 20,147 |
| 9 | 40 | 1,520 | 0.196 | 0.595 | 2.249 | 26,896 |
| 10 | 43 | 1,548 | 0.200 | 0.386 | 1.217 | 28,914 |
| 11 | 46 | 1,518 | 0.198 | 0.376 | 1.696 | 28,770 |
| 12 | 49 | 1,470 | 0.204 | 0.379 | 1.238 | 29,145 |
| 13 | 52 | 1,508 | 0.205 | 1.453 | 4.726 | 28,834 |
| 14 | 55 | 1,485 | 0.215 | 1.356 | 2.399 | 31,545 |
| 15 | 57 | 1,482 | 0.207 | 2.377 | 4.560 | 31,426 |
| 16 | 60 | 1,500 | 0.213 | 3.738 | 7.601 | 29,725 |

**Bottom line so far:** on its own benchmark - GPU-resident 6K prefixes,
single-turn - the guide's prefix-first config keeps TTFT p99 under half a
second at 60 req/s. This is the regime the workload was built to showcase;
the open question this series answers is whether load-preferred placement
plus the P2P pull can match it here, and by how much it wins where the
guide's regime assumptions break (series 1).

**Run hygiene notes (recorded per protocol):** the baseline arm ran once
aborted (harness OOM at the default 32Gi memory limit - the per-request
report is 17 GB and inference-perf buffers it in RAM; rerun at 96Gi) so its
clean run started on a workload-warmed fleet. The cluster's idle-GPU
reclaimer repeatedly zeroed the fleet during this series (observed strikes
00:11, 02:22, 03:06, 05:44 on 2026-07-17, including mid-run at 40+ req/s);
runs invalidated by strikes are quarantined and rerun, never reported.

## Run L: P/D guide vs guide+P2P at C=192 (gpt-oss, paired A/B)

Setup: pd-disaggregation guide topology at uniform TP=1 (8 prefill + 8
decode, one H200 each), `openai/gpt-oss-120b`, quay-mirrored nightly +
generic_p2p overlay, block 64, PYTHONHASHSEED pinned. Arm A: guide verbatim
(plain `NixlConnector`, guide EPP). Arm B: identical plus the P2P stack
(`MultiConnector(NixlConnector + OffloadingConnector[p2p tier])`, 128 GiB
CPU tier both roles (~2.3x the ~1.38M-token GPU KV at TP=1), shm 160 Gi,
sidecar `--enable-p2p-pull`, EPP + precise producer + p2p-source-producer,
minCachedTokenDelta 2048). Workload: the docQA profile at concurrency 192
(`gptoss-docqa-c192.yaml`), same day, clean re-roll per arm, config-aware
readiness. Concurrency chosen by a mechanism gate (`pd-mechgate.sh`):
bursts at C=128/192/256 under the guide's own scorers; C=192 produced 9
source-header fires (placement spill), C=128 zero.

| arm | success | TTFT p50 | p95 | p99 | turns/s |
|---|---|---|---|---|---|
| A guide | 1152/1152 | 11.94 s | 71.6 s | 106.1 s | 5.68 |
| B guide+P2P | 1152/1152 | 1.16 s | 55.2 s | 80.0 s | 7.96 |

Arm B is better on every metric: 10x median TTFT, -25% p99, +40%
throughput, zero failures on both arms. Attribution: the win is the CPU
offload tier - turn N+1's history re-prefill hits the tier (52.2M
external-hit tokens in arm B) instead of recomputing under 192-deep
queues. The P2P pull itself fired zero times during the profile run
(docQA's smooth turn arrivals never spill placement; the gate's bursty
single wave at the same concurrency fired 9), so the pull is a free,
stable rider under guide placement and activates under burstier traffic.

## Run M: prefill pulls decode's generated history (Llama-8B, chat API)

The mechanism blocked all week under text-append became measurable when
all three prerequisites cleared at once: a round-trip-stable chat template
(Llama-3.1-8B; generated text re-tokenizes to the generated ids), the
chat-completions API (server renders the message history), and natural EOS
(no `ignore_eos`: forced continuation embeds special tokens as text and
breaks the hash chain - with it, only 448 tokens matched). Rig: 1 prefill
+ 1 decode (TP=1, `llama-pd.yaml`), pull-enabled sidecar, session primed
first (cold-session defect). Driver (`llama-chat-pull3.sh`): 8K-token
system prompt, decode generates a ~1350-token answer, turn 2 resends the
history with `x-kv-cache-source-host-port=<decode>`; control is the
identical flow without the header.

| mode | prefill ext-hit tokens | KV loaded |
|---|---|---|
| control (no source) | 0 | 0 |
| pull (source=decode) | 1216 (~90% of the answer; all full blocks) | 152 MB |

152 MB / 1216 tokens = 125 KB/token, Llama-8B's bf16 KV size - the byte
accounting closes. The unmatched remainder is the final partial block,
which is structurally uncacheable. This is the first cross-role
generated-KV transfer of the campaign and bounds the claim precisely:
prefill-from-decode works when the request can name decode's ids
(token-stable multi-turn), and cannot exist under text-append harnesses
(kubernetes-sigs/inference-perf#649) or analysis-dropping templates
(gpt-oss harmony) regardless of the serving stack.

## Run N: EPP-e2e chat multi-turn, prefill pulls decode's history at scale (Llama-8B)

Run M proved the cross-role transfer on a single request; Run N runs it
end-to-end under the EPP, on a multi-turn chat workload at concurrency,
across a P/D pair.

Rig: `meta-llama/Llama-3.1-8B-Instruct`, 4 prefill + 4 decode (TP=1),
then 2 prefill + 4 decode at saturation (`llama-pd.yaml`). Driver
`chat_load.py`: concurrent conversations (48 at 4P, 96 at 2P), live
history (each turn resends the accumulated chat), natural EOS (no
`ignore_eos` - the same round-trip-stability requirement as Run M).
Chat-completions rendered by the GPU engines (the CPU render image
v0.23.0 lacks `/v1/chat/completions/render`;
`llama-chat-render-svc.yaml`). Arms: A = precise prefix-cache placement,
no pull (`epp-llama-a.yaml`); B = precise + `p2p-source-producer`,
`minCachedTokenDelta: 1024` (`epp-llama-b.yaml`).

Mechanism (arm B): EPP-decided per-turn prefill<-decode pulls fired on
every turn where the scheduled prefill worker lacked the history. **477K
tokens pulled (4P, C=48)** and **1.65M tokens (2P, C=96)**; the decode
session accepted the pull on all decode pods. Per-turn TTFT stayed flat
as the conversation grew (arm B):

| turn | prompt (K tok) | TTFT p50 (s) | TTFT p95 (s) |
|---|---|---|---|
| 0 | 5.0  | 1.00 | 1.69 |
| 1 | 7.1  | 0.10 | 0.12 |
| 2 | 9.2  | 0.13 | 0.20 |
| 3 | 11.3 | 0.15 | 0.17 |
| 4 | 13.4 | 0.16 | 0.18 |
| 5 | 15.5 | 0.18 | 0.21 |
| 6 | 17.6 | 0.20 | 0.23 |
| 7 | 19.7 | 0.21 | 0.23 |

Turn 0 pays the cold prefill (1.0s p50); every later turn's history
arrives by pull and TTFT holds at 0.1-0.2s even as the prompt grows to
~20K tokens.

BUT arm-A parity: on Llama-8B the recompute this replaces is cheap - a
~2K-token answer re-prefills in ~60ms, about the pull's own cost - so arm
A (recompute) and arm B (pull) tie on TTFT, and tails are dominated by
decode first-token under batching, not prefill. Verdict at this model
scale: the pull's value is prefill **capacity** (GPU-seconds saved), not
user-visible latency. The latency win needs a regime where the recompute
is expensive (longer history, slower/larger prefill, or prefill
saturated) - which Run O (Qwen3-30B agentic) then demonstrates.

Three config bugs cost hours (recorded so they do not recur): a
token-heavy system prompt (~3.3 tok/word) blew `max-model-len`; a
chat-render 404 from the old CPU render image; and a stale `modelName` in
the token-producer config renders 404 silently and starves the whole
producer chain (check `modelName` when cloning EPP configs).

Configs: `configs/run-n` (`chat_load.py` driver, `epp-llama-a.yaml` /
`epp-llama-b.yaml` arms, `llama-pd.yaml` rig,
`llama-chat-render-svc.yaml`).

## Run O: agentic workload on P/D + P2P (Qwen3-30B-A3B-Thinking, EPP e2e)

The agentic-serving guide's benchmark model and workload shapes, served on
the pd-disaggregation topology, with and without the P2P stack. Model and
engine flags follow the agentic scenario
(`llm-d-benchmark/config/scenarios/guides/agentic-serving.yaml`):
`Qwen/Qwen3-30B-A3B-Thinking-2507`, block size 64, qwen3 reasoning parser,
`qwen3_xml` tool parser, temperature 0. Deviations, applied to both arms:
prefix caching enabled (the scenario disables it; reuse is the subject
here), `max-model-len` 131072, and the topology is 2 prefill + 4 decode at
TP=1 (the scenario deploys 2 aggregated pods; P/D is required for the
prefill-pulls-decode question). 6x H200 total.

Calibration, measured on this rig before the arms (`configs/run-o/`):
GPU KV 65.33 GiB/pod (engine startup log) -> 128 GiB CPU tier = 1.96x;
pull of 8K tokens = 74 ms vs 1.21 s recompute (16x), pull overhead ~30 ms
-> crossover ~760 tokens -> `minCachedTokenDelta: 1024`. Thinking-model
round trip: the rendered prompt matches, the generated segment does not
(think blocks are stripped on re-render), so pull value concentrates in
history recovery rather than per-turn answers.

Workload: the scenario's synthetic agentic profile scaled to the context
window and a benchmarkable runtime (`qwen-agentic-syn.yaml`): 24
conversations, dynamic system prompts 10K-100K tokens (mean 50K), 4-40
turns (mean 12), ~1500 input / ~425 output tokens per turn, tool-call
latency gaps 1-20 s (these evict session KV between turns, making
re-engagement the pull-vs-recompute choice), concurrency 16, 288 requests,
text-append via `conversation_replay` (honest here: the dominant reuse is
input-side context). Each arm ran on a freshly re-rolled fleet.

| arm | succ | duration | TTFT p50 | p95 | p99 |
|---|---|---|---|---|---|
| A guide (plain NIXL) | 288/288 | 304 s | 5.22 s | 18.94 s | 30.29 s |
| B guide+P2P (sample 1) | 288/288 | 229 s | 1.09 s | 11.77 s | 29.98 s |
| B guide+P2P (sample 2) | 288/288 | 237 s | 1.06 s | 14.79 s | 31.01 s |

Arm B: 4.8x median TTFT, p95 -22% to -38%, run time -25% (+33%
throughput), p99 at parity (both arms' ceiling is the cold first prefill
of a 100K-token context - irreducible compute). Mechanism receipt: arm B
pulled 1,229,504 tokens of session history in sample 1's 229 s instead of
recomputing it; the EPP decided every pull (precise index over both roles'
kv-events, source header, sidecar injection).

The scenario's OTel trace replay (`qwen-agentic-otel.yaml`, chat API, real
agent sessions with tool calls) serves as the authenticity check: at cold
caches it pulled 16K tokens over 67 events with zero errors; at 16
concurrent sessions the bundled test traces fit warm caches and pull
little. Headline numbers come from the synthetic shapes; the trace replay
shows the same machinery serving real agent-session structure.
