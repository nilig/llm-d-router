# PD Multi Tier Workload 3 - nightly + fixes matched set (2026-08-20)

Three-arm rerun of the Workload 3 tiered-eviction ladder after root-causing
the PD Multi Tier regression. All arms share the same engine image, sidecar
image, router config, topology, and workload seed; the only differences are
the KV connector configuration and, in the PD Multi Tier arm, the vLLM fix
under test.

## Rig

- Model: openai/gpt-oss-120b
- vLLM: docker.io/vllm/vllm-openai:nightly-5a4c8d99242e9e069b604d0e9b969e77f7dd501d
  (main 2026-08-19; contains vllm-project/vllm#51840)
- Sidecar: quay.io/niliguy/llm-d-router-disagg-sidecar:p2p-seq-e1427b0f
  (llm-d/llm-d-router#2451 sequential P->D dispatch, all arms)
- EPP: v0.10.0-rc.1; precise CPU backend weight 0.4 in every arm, podCacheSize
  36, blockSizeTokens 128, prefill scorers 3/2/2, decode active-request 2
- Topology: 8 prefill TP=1 + 8 decode TP=1 = 16x H200, one dedicated node per
  role, strategy Recreate
- Workload: 1000 groups x 5 prompts, 16K shared prefix, 256 in / 256 out,
  eight 60s Poisson stages 5..40 QPS, 10800 requests,
  data.shared_prefix.seed 20260817 (configs/tiered-eviction-seeded.yaml.in)

## Arms

| Arm | Prefill connector | P/D transport | Decode | Extra |
|---|---|---|---|---|
| PD NIXL baseline | NixlConnector | NIXL/RDMA | NixlConnector | CPU weight inert (num_cpu_blocks=None verified) |
| PD NIXL + prefill CPU offload | MultiConnector: NIXL + 100 GiB OffloadingConnector | NIXL/RDMA | NixlConnector | |
| PD Multi Tier | OffloadingConnector, TieringOffloadingSpec, 100 GiB CPU primary + p2p secondary | through the CPU tier | same spec, 100 GiB | vllm#52912 fix mounted via ConfigMap (configs/p2p-manager-nightly-pr52912.py) |

The PD Multi Tier arm requires BOTH vLLM changes: #51840 (merged post-v0.27.1,
in the nightly) and #52912 (open PR, applied via ConfigMap). On v0.27.1 the
same arm collapses: a warm producer supplies 57 of the consumer's 112 demanded
chunks and every warm-producer request eats the 30s load timeout
(vllm-project/vllm#52808). The sidecar fix is required so the decode leg is
dispatched only after the prefill leg returns (llm-d/llm-d-router#2438).

## Results

## Overall
| metric | PD NIXL baseline | PD NIXL + prefill CPU offload | PD Multi Tier (seq sidecar + PR52912) |
|---|---|---|---|
| Successful / failed | 10,800 / 0 | 10,800 / 0 | 10,800 / 0 |
| Successful req/s | 10.683 | 11.463 | 10.892 |
| Latency mean (s) | 9.249 | 3.511 | 3.644 |
| Latency P90 (s) | 24.181 | 4.443 | 4.556 |
| Latency P99 (s) | 37.850 | 5.631 | 7.380 |
| TTFT mean (s) | 6.432 | 0.428 | 0.541 |
| TTFT P90 (s) | 21.302 | 0.694 | 0.782 |
| TTFT P99 (s) | 35.033 | 2.452 | 3.029 |
| Mean TPOT (ms) | 11.1 | 12.1 | 12.2 |
| Token-count mismatches | 8,648 | 8,594 | 8,640 |

## Per stage (target QPS 5..40)
| Stage | QPS | req/s 1/2/3 | P90 latency 1/2/3 (s) | P90 TTFT 1/2/3 (s) |
|---|---|---|---|---|
| 0 | 5 | 4.75 / 4.64 / 4.78 | 2.35 / 2.26 / 2.44 | 1.04 / 0.97 / 1.08 |
| 1 | 10 | 9.63 / 10.16 / 10.51 | 2.70 / 2.48 / 2.77 | 1.08 / 0.93 / 1.10 |
| 2 | 15 | 14.64 / 14.25 / 14.50 | 3.44 / 2.60 / 3.07 | 1.53 / 0.70 / 1.06 |
| 3 | 20 | 17.82 / 18.29 / 18.43 | 3.48 / 3.06 / 3.35 | 1.35 / 0.68 / 0.73 |
| 4 | 25 | 22.38 / 24.00 / 22.98 | 5.79 / 3.93 / 3.87 | 2.67 / 0.69 / 0.70 |
| 5 | 30 | 27.18 / 28.64 / 20.71 | 9.25 / 4.02 / 4.55 | 5.78 / 0.70 / 0.90 |
| 6 | 35 | 24.89 / 32.52 / 24.67 | 18.69 / 4.25 / 4.41 | 15.35 / 0.44 / 0.55 |
| 7 | 40 | 22.99 / 36.01 / 32.97 | 36.00 / 4.62 / 4.68 | 32.71 / 0.54 / 0.62 |

## Mechanism counters (aggregate across replicas)

| | PD NIXL + prefill CPU offload | PD Multi Tier |
|---|---:|---:|
| Prefill GPU->CPU stored | 1.293 TB | 1.294 TB |
| Prefill CPU->GPU loaded | 4.223 TB | 4.157 TB |
| Decode GPU->CPU stored | 0 (no CPU tier) | 12.4 GB |
| Decode CPU->GPU loaded | 0 (no CPU tier) | 6.512 TB |
| Decode p2p-tier lookups | - | 1,131,705 |
| cannot store chunks (decode) | - | 0 |
| kv_offload allocation failures | 0 | 0 |

PD NIXL baseline: zero kv_offload counters, num_cpu_blocks=None (CPU weight
inert as designed). Decode load 6.5 TB in PD Multi Tier is the P/D handoff
arriving through the CPU tier; zero cannot-store-chunks against 14,728 in the
v0.27.1 run (decode tier now 100 GiB and the store path healthy).

## Reading

1. Baseline vs PD Multi Tier (the feature comparison, identical router
   config): PD Multi Tier holds P90 TTFT at 0.55-1.1s through the whole
   ladder while the baseline climbs to 32.7s at 40 QPS; 33.0 vs 23.0 req/s
   in the final stage. Cost: +1.1ms mean TPOT.
2. PD Multi Tier vs PD NIXL + prefill CPU offload: near parity (TTFT P90
   0.78 vs 0.69s, P99 latency 7.4 vs 5.6s, final-stage 33.0 vs 36.0 req/s).
   The CPU-offload arm keeps a small edge at the top of the ladder; the
   stage-5 dip (20.7 req/s) in PD Multi Tier is the one anomaly worth a
   follow-up look.
3. Contrast with the v0.27.1 run of the same PD Multi Tier arm (2026-08-17,
   sidecar concurrent dispatch, no vLLM fixes): 5.9 req/s overall, TTFT P90
   30.7-101.5s from stage 1 on. The three fixes turn the arm from collapsed
   to competitive.

## Provenance

Experiments inference-perf-1787183570-834kdn_1 (baseline),
inference-perf-1787185643-jf0mdt_1 (CPU offload),
inference-perf-1787187434-yo7joy_1 (PD Multi Tier); harness_rc=0 for all
three, zero engine restarts during runs, 16/16 pods ready and 16 ZMQ
subscribers gated before each launch. The llmdbenchmark CLI's local copy
step failed on every arm (websocket close 1006); results were read from the
harness PVC directly. Raw per-arm summaries and per-stage JSONs in results/.
