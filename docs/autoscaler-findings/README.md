# Workload-variant autoscaler benchmark findings

This directory records a 2026-08-23 evaluation of the llm-d workload-variant
autoscaler external scaler against optimized-baseline routing.

## Scope

- Kermit static two-replica calibration
- Waldorf workload-variant autoscaler with two to six standard tensor-parallel replicas
- Fixed two-replica and fixed six-replica controls
- `Qwen/Qwen3-32B`, vLLM v0.23.0, tensor parallelism 2, and two H200 GPUs per replica
- Endpoint Picker v0.9.0 with flow control enabled
- Wide expert parallelism is unsupported and was not tested

## Key results

| Deployment | Load duration | Output throughput | Median TTFT | Failed requests | GPU-minutes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fixed 2 replicas | 36m 02s | 3,318 tokens/s | 2.136s | 17 | 144 |
| Autoscaled 2-6 replicas | 24m 23s | 5,130 tokens/s | 0.196s | 39 | 252 |
| Fixed 6 replicas | 16m 36s | 7,689 tokens/s | 0.100s | 0 | 199 |

The autoscaled deployment improved output throughput by 54.6 percent and
reduced median time to first token by 90.8 percent relative to the fixed
two-replica control. It consumed more GPU-minutes and its scale-down behavior
truncated 39 active streams. The fixed two-replica control recorded 17 endpoint
queue TTL failures. The fixed six-replica control delivered the highest
throughput, lowest latency, and no request failures for this load shape.

## Contents

- `benchmark-summary.md`: initial benchmark plan and observations
- `installation-log.md`: installation steps, issues, and ease-of-use feedback
- `waldorf-autoscaling-summary.md`: autoscaling run behavior and metrics
- `waldorf-controlled-comparison.md`: fixed versus autoscaled comparison
- `profiles/`: workload profiles used for calibration and controlled runs
- `router-flow-control.values.yaml`: router flow-control settings used by the runs

## Artifact policy

Generated run directories total approximately 6.2 GiB and contain raw
per-request payloads, so they are not included. Result paths in the reports
refer to the original operator-local workspace. The summarized aggregate
measurements and reproducibility inputs are included here.

## Provenance

- llm-d benchmark v0.7.8
- Workload-variant autoscaler source commit `ff81e8c8c743d64c431d39c28bd08a59387b81b0`
- KEDA v2.18.1
