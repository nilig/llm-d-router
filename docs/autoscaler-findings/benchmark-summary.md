# Static two-replica saturation benchmark

## Configuration

- Cluster: `kermit_US-EAST-01A`
- Namespace: `nilig-wva-benchmark`
- Model: `Qwen/Qwen3-32B`
- Serving: two vLLM `v0.23.0` replicas, TP=2, two H200 GPUs per replica
- Routing: optimized-baseline standalone EPP `v0.9.0`
- Benchmark source: llm-d-benchmark tag `v0.7.8`, commit `00e1516e76cfe3872044188df38a31c63f7cff9a`
- Harness image: `ghcr.io/llm-d/llm-d-benchmark:v0.7.8`
- Traffic: Poisson arrivals, 7,200 input tokens, 1,000 requested output tokens, shared-prefix data
- Result directory: `runs/static-2-targeted/niliguy-20260823-092751-328/results/inference-perf-1787466490-8vf20b_1`

## Per-stage results

All 1,770 requests succeeded. Stage 0 is warm-up; stages 1 through 7 are the measured ladder.

| Stage | Offered req/s | Requests | Completed req/s | Output tok/s | Mean TTFT ms | Mean ITL ms | P90 ITL ms | Mean request s | P90 request s | Peak pool KV | Peak pool queue |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 2 warm-up | 60 | 1.36 | 1,783 | 527.7 | 16.6 | 19.5 | 22.7 | 26.8 | 26.3% | 0 |
| 1 | 2 | 90 | 1.35 | 1,625 | 184.7 | 13.5 | 17.2 | 16.6 | 20.3 | 12.8% | 0 |
| 2 | 3 | 135 | 2.13 | 2,297 | 188.9 | 18.5 | 22.5 | 20.8 | 26.0 | 28.3% | 0 |
| 3 | 4 | 180 | 2.80 | 2,923 | 148.4 | 21.5 | 25.2 | 23.5 | 28.1 | 37.8% | 0 |
| 4 | 5 | 225 | 3.24 | 3,326 | 145.6 | 24.6 | 31.5 | 26.3 | 32.4 | 50.1% | 0 |
| 5 | 6 | 270 | 3.95 | 3,988 | 162.1 | 30.5 | 38.9 | 32.1 | 37.2 | 67.1% | 0 |
| 6 | 8 | 360 | 4.33 | 4,346 | 200.8 | 38.8 | 50.5 | 40.4 | 48.2 | 83.9% | 0 |
| 7 | 10 | 450 | 4.79 | 4,925 | 228.6 | 50.0 | 67.2 | 53.0 | 60.0 | 98.6% | 0 |

## Interpretation

- The useful operating knee is between 6 and 8 offered requests/s. Above 6, marginal throughput gains are small relative to latency and KV-cache growth.
- Ten requests/s is a reliable saturation load for the two-replica baseline: peak average pool KV utilization reaches 98.6%, mean request latency reaches 53.0 seconds, and completed throughput flattens at 4.79 requests/s.
- TTFT remains below 230 ms on average through 10 requests/s. Degradation is primarily decode-side: mean ITL rises from 13.5 ms at 2 requests/s to 50.0 ms at 10 requests/s.
- The EPP-reported pool queue remains zero at every stage. Saturation is visible in KV utilization, running requests, throughput flattening, and ITL rather than queue depth.
- Both replicas remained ready throughout. At 10 requests/s, their prefix-cache hit rates ended at 77.7% and 81.3%, and neither replica added a preemption during the targeted run.

## Recommended autoscaler workload

Use the same model and request shape so the static result is directly comparable:

1. Hold 2 requests/s for two minutes to establish a stable low-load baseline.
2. Step to 10 requests/s and hold for at least 15 minutes, long enough to observe scale-out and model startup.
3. Return to 2 requests/s and hold long enough to observe stabilization and scale-down behavior.
4. Record desired, current, and ready replicas; pod scheduling and readiness timestamps; WVA and KEDA decisions; request errors; TTFT; ITL; completed throughput; KV utilization; and GPU utilization.
5. Compare the autoscaled service against this static two-replica baseline and a static deployment sized to the autoscaler's peak replica count.

This test targets standard TP replicas. It does not exercise wide expert parallelism.
