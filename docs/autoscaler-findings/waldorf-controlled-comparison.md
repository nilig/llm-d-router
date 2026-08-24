# Waldorf WVA controlled comparison

## Test design

The same five-stage workload was run against the same Waldorf deployment and EPP in three replica configurations:

- Fixed two replicas.
- WVA autoscaling from two to six replicas and back to two.
- Fixed six replicas, with all six Ready before load began.

Each replica used vLLM `v0.23.0`, `Qwen/Qwen3-32B`, TP=2, and two H200 GPUs. Each treatment submitted 7,392 streaming requests with 7,200 input tokens and 1,000 requested output tokens. Stages used concurrency 32, 64, 256, 384, and 64 with 96, 256, 2,048, 3,072, and 1,920 requests respectively.

The fixed controls disabled per-request payload reports, but kept the same lifecycle summary and per-stage reports. This changes post-load artifact generation and collection, not the request workload sent to the server.

## Aggregate result

| Treatment | Load time | Successes | Failures | Requests/s | Output tok/s | Median TTFT | P95 TTFT | Median ITL | Median request |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fixed two | 36m 02s | 7,375 | 17 | 3.41 | 3,318 | 2.136s | 46.367s | 41.34ms | 66.659s |
| WVA 2-6 | 24m 23s | 7,353 | 39 | 5.03 | 5,130 | 0.196s | 3.046s | 21.97ms | 24.518s |
| Fixed six | 16m 36s | 7,392 | 0 | 7.42 | 7,689 | 0.100s | 0.923s | 21.43ms | 22.497s |

The report-level load times differ by one or two seconds from the harness stage-transition wall times because they exclude transition overhead.

Relative to fixed two, WVA:

- Reduced load time by 32.3%.
- Increased completed request throughput by 47.4% and output-token throughput by 54.6%.
- Reduced median TTFT by 90.8%, P95 TTFT by 93.4%, and median request latency by 63.2%.
- Avoided the fixed-two saturation failure mode, but introduced a different scale-down failure mode.

Relative to warm fixed six, WVA:

- Took 46.9% longer.
- Delivered 32.3% less request throughput and 33.3% less output-token throughput.
- Had 96.7% higher median TTFT and 229.9% higher P95 TTFT.
- Failed 39 requests while fixed six failed none.

## Per-stage result

| Stage | Concurrency | Fixed two output tok/s | WVA output tok/s | Fixed six output tok/s | Fixed two median TTFT | WVA median TTFT | Fixed six median TTFT | Failures: fixed/WVA/six |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 32 | 1,335 | 1,323 | 2,295 | 2.404s | 1.466s | 0.488s | 0 / 0 / 0 |
| 1 | 64 | 2,470 | 2,648 | 3,948 | 0.556s | 0.544s | 0.141s | 0 / 0 / 0 |
| 2 | 256 | 4,078 | 5,227 | 10,648 | 1.097s | 0.388s | 0.106s | 0 / 0 / 0 |
| 3 | 384 | 3,990 | 9,415 | 13,550 | 22.878s | 0.183s | 0.109s | 17 / 0 / 0 |
| 4 | 64 | 2,498 | 3,481 | 4,538 | 0.218s | 0.096s | 0.071s | 0 / 39 / 0 |

The autoscaler's main benefit appears at saturation. At concurrency 384 it delivered 2.36 times fixed-two output throughput and avoided fixed-two's 17 failures. The fixed-six result shows the remaining headroom if capacity is already warm: 44% more output throughput than WVA in that stage.

## Failure mechanisms

- Fixed two: all 17 failures occurred at concurrency 384. EPP returned `ServiceUnavailable` because requests exceeded the queue TTL and were evicted. This is a saturation failure.
- WVA: all 39 failures occurred in the final concurrency-64 stage while reducing six replicas to two. Streaming connections ended with incomplete transfer payloads in four groups aligned with four pod removals. This is an unsafe scale-down/draining failure.
- Fixed six: zero failures.

WVA therefore fixes the fixed-capacity saturation failure, but the tested serving manifest makes scale-down less reliable than leaving either fixed pool unchanged.

## Load-window GPU efficiency

Each replica allocates two H200 GPUs. GPU-minute estimates cover only the load window; they exclude initial deployment warmup, report generation, and idle time after the load.

| Treatment | Approximate GPU-min | Successful output tokens/GPU-min |
| --- | ---: | ---: |
| Fixed two | 144 | 51,156 |
| WVA 2-6 | 252 | 29,237 |
| Fixed six | 199 | 37,121 |

The WVA estimate integrates the observed desired-replica timeline: two, four, five, six, five, four, three, and two. It is approximate because pod termination can retain GPU allocation during the 30-second grace period.

WVA used 74.5% more GPU time than fixed two for 54.6% more output throughput. It used 26.3% more GPU time than fixed six during the load because cold capacity arrived late and the 300-second stabilization window retained replicas while the workload ran longer. On successful output tokens per GPU-minute, WVA was 42.8% below fixed two and 21.2% below fixed six.

This does not include the fixed-six preparation cost. Scaling from two to six before that control exposed one vLLM pod that remained at `Loading model from scratch...` for more than 10 minutes and never opened port 8000. Recycling that pod produced a Ready replacement. Fixed-six is therefore a warm-capacity performance bound, not an end-to-end provisioning result.

## Conclusion

The supported WVA path works: it detects demand, drives KEDA/HPA from two to six replicas, and substantially improves throughput and latency under saturation. It is not yet a complete production result for this workload:

- Model cold start delays usable capacity by minutes and can be uneven or hang.
- The 300-second scale-down stabilization retains expensive capacity after demand falls.
- Scale-down terminates active streaming requests because the serving Deployment has no drain mechanism.
- Waldorf's `gpu.nvidia.com/model=H200` label is unresolved, so the GPU-inventory limiter cannot be enabled safely.
- Wide expert parallelism remains unsupported and was not tested.

The next test should first add safe endpoint draining. Then repeat with a longer steady high-load plateau and at least three repetitions per treatment to measure variance and WVA learned-capacity stability. A policy-tuning treatment should compare the current thresholds and stabilization window with earlier scale-up, a lower or workload-aware scale-down delay, and warm-capacity/Fast Model Actuation.

## Result locations

- Autoscaled: `runs/waldorf-autoscale-ramp/niliguy-20260823-142229-810`
- Fixed two: `runs/waldorf-fixed-2-control/niliguy-20260823-153246-680`
- Fixed six: `runs/waldorf-fixed-6-control/niliguy-20260823-163126-423`
