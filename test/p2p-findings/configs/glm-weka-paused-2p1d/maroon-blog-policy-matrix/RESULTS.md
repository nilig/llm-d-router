# GLM Weka blog-policy matrix results

Status: first c64 sequence and the c128 approximate-P2P engagement probe are
complete. These are single-seed warm-mesh results; the reverse-order
replication has not run.

## Method

- Topology: PR #1947 `p2w1d1w2` (two one-node DEP8 prefill replicas and one
  two-node DEP16 decode group; 32 H200 GPUs).
- Workload: recovered Weka agentic runner, c64, seed 42, 900-second profiling
  phase.
- Engine deployment and cache state remained in place across configurations.
- The approximate control is byte-identical to the blog EPP configuration.
- Within each index type, the P2P configuration adds only
  `p2p-source-producer` with `minCachedTokenDelta: 12288`.
- Every precise configuration established 32/32 live rank subscriptions before
  the workload.

## c64 results

| Configuration | Source directives | Request/s | TTFT avg | TTFT p50 | TTFT p99 | ITL p50 | Output tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| Blog approximate baseline | off | 4.78 | 2.837 s | 1.574 s | 18.462 s | 17.81 ms | 3,355.48 |
| Blog approximate + P2P | 0 / 4,611 (0.000%) | 4.79 | 2.831 s | 1.560 s | 18.345 s | 17.81 ms | 3,423.79 |
| Blog-policy precise | off | 4.69 | 2.931 s | 1.674 s | 19.560 s | 17.80 ms | 3,309.45 |
| Blog-policy precise + P2P | 1 / 3,868 (0.026%) | 4.73 | 2.870 s | 1.659 s | 19.035 s | 17.81 ms | 3,289.46 |

Within-index deltas:

| P2P comparison | Request/s | TTFT avg | TTFT p50 | TTFT p99 | ITL p50 | Output tok/s |
|---|---:|---:|---:|---:|---:|---:|
| Approximate + P2P vs approximate | +0.2% | -0.2% | -0.8% | -0.6% | 0.0% | +2.0% |
| Precise + P2P vs precise | +0.9% | -2.1% | -0.9% | -2.7% | +0.1% | -0.6% |

Both comparisons are ties, not P2P performance results. The approximate P2P
configuration selected no pulls, and the precise configuration selected one
source directive in 3,868 observed requests. The small metric changes cannot
be attributed to P2P at those engagement rates.

The c64 result establishes a boundary: the blog's affinity-led placement
usually routes to its chosen cache holder, so adding P2P alone has no work to
do. The separate load-first experiment is not pooled with this matrix because
it changes placement policy and deliberately creates spill.

## Acceptance evidence

All four Jobs completed with `was_cancelled=False`, zero processed
`error_records`, and zero model-pod restarts. AIPerf's fixed-duration grace
boundary cancelled a small number of in-flight credits in every run, matching
the accepted workload behavior.

Raw evidence in the parent directory uses the configuration tag:

- `weka-job-matrix-s42-*.json`: generated Job specs.
- `weka-matrix-s42-*.log`: AIPerf console logs.
- `epp-matrix-s42-*.jsonl`: streamed request-level EPP logs.
- `mechanism-matrix-s42-*.txt`: recomputed source-directive counts.
- `snap-matrix-s42-*-before.txt` and `snap-matrix-s42-*-after.txt`: model
  restarts and engine counters.
- `gates/subscriptions/subs-blog-precise-*` and
  `gates/subscriptions/subs-blog-precise-p2p-*`: 32-rank subscription proofs.

Canonical AIPerf exports copied from the workload PVC are in:

- `../artifacts/matrix-s42-blog-approximate/`
- `../artifacts/matrix-s42-blog-approximate-p2p/`
- `../artifacts/matrix-s42-blog-precise/`
- `../artifacts/matrix-s42-blog-precise-p2p/`

The stock P2P path itself was proven before the campaign by Gate 2: a 24,576
token sidecar-header pull moved 1,341.5 MB into the destination prefill engine,
matching direct engine injection, while the control moved 0.0 MB. Therefore
the near-zero directive counts here describe policy engagement, not a broken
transport.

## c128 engagement boundary

The exact blog approximate + P2P configuration was repeated at c128, changing
only workload concurrency. It emitted 0 source directives for 6,690 observed
requests (0.000%), so the predeclared 5% gate did not qualify. No c128 no-P2P
control was run.

The probe completed with 6,500 successful records, zero processed
`error_records`, `was_cancelled=False`, and zero model-pod restarts. Its
descriptive, unpaired profile was 6.89 request/s, TTFT average 5.474 s, TTFT
p50 3.087 s, TTFT p99 30.361 s, ITL p50 23.68 ms, and 4,572.74 output tok/s.

This strengthens the c64 boundary: increasing concurrency from 64 to 128 did
not cause the blog's affinity-led approximate policy to select remote cache
sources. P2P needs a placement regime that deliberately permits load spill;
adding it to this policy alone leaves it idle.

Raw c128 evidence in the parent directory:

- `weka-job-probe-c128-s42-blog-approximate-p2p.json`
- `weka-probe-c128-s42-blog-approximate-p2p.log`
- `epp-probe-c128-s42-blog-approximate-p2p.jsonl`
- `mechanism-probe-c128-s42-blog-approximate-p2p.txt`
- `snap-probe-c128-s42-blog-approximate-p2p-before.txt`
- `snap-probe-c128-s42-blog-approximate-p2p-after.txt`
- `../artifacts/probe-c128-s42-blog-approximate-p2p/` (canonical AIPerf exports
  copied from the workload PVC)
