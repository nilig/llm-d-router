# Waldorf WVA autoscaling benchmark

## Configuration

- Cluster: `waldorf_US-EAST-04A`
- Namespace: `nilig-wva-benchmark`
- Model: `Qwen/Qwen3-32B`
- Serving: vLLM `v0.23.0`, TP=2, two H200 GPUs per replica
- Routing: optimized-baseline standalone EPP `v0.9.0`
- Autoscaling: WVA external scaler through KEDA `2.18.1`, two to six replicas
- WVA image digest: `sha256:456aebd2d54f2debf4e001f8abe6d72240b0556a8d5739097ba21e7b92a3afcd`
- HPA scale-down stabilization: 300 seconds
- Traffic: concurrent requests, 7,200 input tokens, 1,000 requested output tokens, shared-prefix data
- Benchmark source: llm-d-benchmark tag `v0.7.8`, commit `00e1516e76cfe3872044188df38a31c63f7cff9a`
- Harness image: `ghcr.io/llm-d/llm-d-benchmark:v0.7.8`
- Load window: `2026-08-23T11:23:43Z` to `2026-08-23T11:48:08Z`
- Result directory: `runs/waldorf-autoscale-ramp/niliguy-20260823-142229-810/results/inference-perf-1787484197-nhwp16_1`

This test covers ordinary TP replicas. It does not exercise wide expert parallelism.

## Per-stage results

| Stage | Concurrency | Requests | Failures | Ready replicas | Report duration s | Completed req/s | Output tok/s | Mean TTFT ms | P95 TTFT ms | Mean ITL ms | Mean request s | P95 request s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 32 | 96 | 0 | 2 | 49.4 | 1.46 | 1,323 | 2,195 | 5,972 | 19.8 | 21.4 | 25.7 |
| 1 | 64 | 256 | 0 | 2 | 78.5 | 2.61 | 2,648 | 861 | 2,894 | 21.7 | 23.7 | 28.5 |
| 2 | 256 | 2,048 | 0 | 2 to 6 | 364.0 | 5.12 | 5,227 | 681 | 2,256 | 44.7 | 47.9 | 79.0 |
| 3 | 384 | 3,072 | 0 | 6 | 293.7 | 9.21 | 9,415 | 1,074 | 6,096 | 35.8 | 39.0 | 84.2 |
| 4 | 64 | 1,920 | 39 | 6 to 2 | 538.2 | 3.39 | 3,481 | 181 | 524 | 16.6 | 17.8 | 25.0 |

The harness completed all five stages in 24 minutes 24 seconds. In total, 7,353 of 7,392 requests succeeded. The overall failure rate was 0.53%; all 39 failures occurred during stage 4, for a stage failure rate of 2.03%.

## Scaling behavior

- WVA first recommended four replicas at `11:24:27Z`, 44 seconds after load began. It recommended five at `11:24:57Z` and six at `11:25:12Z`.
- The Deployment reached six current replicas at approximately `11:25:41Z`. The additional replicas became Ready one at a time from `11:27:12Z` through `11:29:12Z`, roughly 2.5 to 3.5 minutes after creation.
- WVA reached the six-replica maximum during the concurrency-64 stage. This was driven by observed demand against only two Ready replicas while the new replicas were starting, not by the later concurrency-256 or concurrency-384 stages.
- WVA first recommended six to five at `11:37:12Z`, while stage 3 was still draining. HPA applied six to five at `11:42:12Z`, exactly matching its 300-second stabilization window.
- The subsequent observed reductions were five to four at `11:44:17Z`, four to three at `11:44:28Z`, and three to two at `11:45:03Z`.
- The deployment, EPP, WVA controller, ScaledObject and HPA were healthy after the run, with two Ready model replicas.

## Scale-down request loss

All 39 failed requests reported the same error:

`ClientPayloadError: Response payload is not completed: TransferEncodingError: Not enough data to satisfy transfer length header.`

The failures form four timestamp groups, one for each replica removal. Each group consists of streams that began before the removal and failed together about 25 to 30 seconds afterward. The live Deployment has `terminationGracePeriodSeconds: 30` and no `preStop` hook.

This shows that replica-count actuation and HPA stabilization work, but the serving deployment does not safely drain long in-flight streams during scale-down. The result is user-visible request loss even though the autoscaler chooses and applies a valid lower replica count. A production test needs endpoint removal plus an in-flight drain mechanism, with a termination grace period long enough for the configured request timeout.

## Initial efficiency observations

- The load window consumed approximately 250 allocated GPU-minutes based on the observed Deployment replica timeline. Holding the two-replica minimum for the same 24.4-minute window would consume approximately 98 GPU-minutes. This is resource accounting, not yet a controlled cost/performance comparison.
- Six replicas were allocated from about `11:25:41Z` through `11:42:12Z`. Cold-starting replicas consumed GPUs before they could serve, and the 300-second downscale window intentionally retained capacity after demand fell.
- The highest measured stage throughput was 9,415 output tokens/s at concurrency 384 with six Ready replicas.
- WVA's compute-bound capacity observation varied materially during the run. The first loaded estimate was 83,490 tokens per observed replica; later observed values included 242,869 and 484,016. Some new or idle pods continued to use the 628,902-token memory-bound fallback. The mixed and changing estimates deserve a repeatability test before drawing a cost-efficiency conclusion.
- Aggregate telemetry reached 99.8% per-pod KV-cache use and 104 waiting vLLM requests at the worst samples. The EPP flow-control queue remained zero, while EPP running requests reached the configured concurrency levels.

## What this validates

- Standard Deployment replica scaling through the WVA external scaler and KEDA works on Waldorf.
- KEDA `2.18.1` accepts the scaler and maintains a Ready and Active ScaledObject.
- The configured two-replica minimum, six-replica maximum, scale-up actuation and HPA scale-down stabilization all work.
- Model cold start, rather than controller or KEDA actuation, dominates scale-up response time.

## Limitations and untested paths

- Wide expert parallelism is unsupported and was not tested.
- Waldorf's `gpu.nvidia.com/model=H200` label is not resolved by WVA, so accelerator inventory limiting and accelerator-keyed accounting were not tested. Enabling the limiter in this state would block scale-up.
- Scale-to-zero, multi-variant cost allocation, failure recovery and cluster-capacity limiting were not tested.
- Scale-down safety is not provided by the tested serving manifest; long streaming requests were truncated.

## Benchmark-tool observations

- Report generation took approximately 6.5 minutes after the 24.4-minute load and used about 8 GiB of harness memory.
- The result directory was 5.1 GiB, dominated by a 4.8 GiB per-request lifecycle file containing full prompts and streaming responses.
- The runner copied results through one `kubectl cp` stream for approximately 8.2 minutes. The stream ended with a WebSocket EOF after 4.9 GiB, the runner marked the treatment failed, and cleanup deleted the harness pod.
- All compact stage reports, plots and Prometheus summaries survived. The local per-request file is truncated after 7,115 of 7,392 request objects, but the complete generated reports contain the authoritative totals and all 39 errors.
- Run-only component discovery again used generated-stack labels rather than the existing `optimized-baseline` labels. Model and EPP log capture reported no pods, and the processed replica-status and startup-time reports were empty despite the live replicas. Prometheus time series still captured the Ready replica count.

## Controlled follow-up

The fixed-two and fixed-six controls are complete. The full comparison is in `waldorf-controlled-comparison.md`.

- WVA reduced load time by 32.3%, increased output-token throughput by 54.6%, and reduced median TTFT by 90.8% relative to fixed two.
- Fixed two had 17 EPP queue-TTL failures under saturation. WVA avoided those failures, but had 39 scale-down stream truncations. Fixed six had zero failures.
- Warm fixed six was 33.3% faster in output-token throughput than WVA and used fewer GPU-minutes during the load window.
- Disabling per-request payload output reduced collected result size from 4.9 GiB to 55 MiB and 46 MiB. Streamed compressed collection completed in about three seconds for each control.

Before repeating scale-down, add safe endpoint draining and verify that no in-flight stream is terminated. The next policy test should use repeated runs, a longer steady high-load plateau, and explicit comparison of cold-start and scale-down settings.
