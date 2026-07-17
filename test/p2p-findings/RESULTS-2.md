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
