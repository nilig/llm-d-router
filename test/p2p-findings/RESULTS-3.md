# P2P benchmarks, series 3: the missing affinity+P2P arm, and where it wins

Series 1 ([RESULTS.md](RESULTS.md)) and the llm-d guide's own benchmark
report both leave a gap: `epp-affinity-p2p` — precise prefix-cache
affinity *plus* the pull, the guide's shipped default — was never
isolated on the guide's own two flagship scenarios. Every published table
compares affinity-alone or load-alone against load+P2P; the arm actually
recommended by default was untested. This series fills that gap on both
scenarios and finds they disagree with each other.

Run on the guide's own manifests (`guides/p2p-kv-cache-sharing`, commit
`d4a5fb91`), the pinned nightly
(`nightly-4080263bb2c5d10deac17aaeb88e0823bc35bca9`) with the
`generic_p2p` overlay (`145a460c`) plus the request-finalization crash
fix (`orozery/vllm@fa07027d` — see
[p2p-request-finalization-crash.md](p2p-request-finalization-crash.md))
overlaid via ConfigMap. Fix overlay:
[configs/2026-07-capacity-and-scenarios/patch-p2p-fix-scaffolding.yaml](configs/2026-07-capacity-and-scenarios/patch-p2p-fix-scaffolding.yaml),
fix source:
[configs/2026-07-capacity-and-scenarios/vllm-fix-orozery-scheduler.py](configs/2026-07-capacity-and-scenarios/vllm-fix-orozery-scheduler.py).
Every deployment verified in-pod before running load: pinned image
digest, `finished_signaled` present in the mounted `scheduler.py` (fix
live), `remote_kv_source` present in the mounted `manager.py` (branch
overlay live).

## Scenario D: document Q&A (14 pods, session-ownership regime)

Guide's own headline workload
([guide_p2p-kv-cache-sharing_1.yaml.in](configs/2026-07-capacity-and-scenarios/guide_p2p-kv-cache-sharing_1.yaml.in) —
also lives at `llm-d-benchmark#1656`): 192 conversations, private 48K-token
document prefix, 6 turns of 256-token questions/answers, 128 concurrent.
Two independent runs of the new arm (order-alternation doesn't apply with
only one non-baseline arm running).

| run | affinity (no pull) | **affinity + P2P** | load + P2P |
|---|---|---|---|
| 1 | 4.1 / 41.0 / 80.5s; 5.98 turns/s | 4.0 / 27.7 / 48.8s; 5.6 turns/s | 4.5 / 13.0 / 20.9s; 7.02 turns/s |
| 2 | 4.2 / 17.3 / 37.2s; 7.66 turns/s | 2.6 / 33.6 / 67.2s; 5.7 turns/s | 3.9 / 12.5 / 26.7s; 7.76 turns/s |

(TTFT p50/p95/p99; throughput. affinity+P2P's throughput is slightly
undercounted by a sub-1% tail of gpt-oss requests that generated
unusually long reasoning output under `ignore_eos:true` — median/p90/p95
output length all land on the intended 256-token target, only `p99.9`
blows out. TTFT is unaffected, measured at first token before that
generation happens.)

**affinity+P2P sits between the other two arms, in both runs, not one.**
It improves on affinity-alone's worst case (48.8-67.2s p99 vs 80.5s) but
never reaches load+P2P's range (20.9-26.7s p99). Likely mechanism:
affinity+P2P still queues a request behind a busy owner pod whenever the
scorer's affinity term outweighs load, and only pulls once a peer already
out-caches the scheduled pod — it recovers the *cache-locality* cost of a
cross-pod placement but not the *queueing* cost of a placement decision
that still prefers a busy owner. load+P2P never makes that tradeoff:
placement always goes to the least-loaded pod.

Zero restarts, zero failures, 1,152/1,152 turns completed on both runs of
the new arm (2,304 turns total).

## Scenario A: uniform shared-prefix pool (16 pods, capacity regime)

128 shared 48K-token prefixes, 256-token questions, 64-token outputs,
constant-rate stages 4-24 req/s. Profile built for this series:
[guide_p2p-kv-cache-sharing_2.yaml.in](configs/2026-07-capacity-and-scenarios/guide_p2p-kv-cache-sharing_2.yaml.in)
(now also `llm-d-benchmark#1656`). Raw per-stage results:
[configs/2026-07-capacity-and-scenarios/scenario-a-raw/](configs/2026-07-capacity-and-scenarios/scenario-a-raw/).

| offered | affinity | **affinity + P2P** | load, no P2P | load + P2P |
|---|---|---|---|---|
| 4 req/s | 3.8 / 2.4s | 3.9 / 2.4s | 3.8 / 4.2s | 3.9 / 2.4s |
| 8 req/s | 7.9 / 0.7s | 7.9 / 0.73s | 6.7 / 6.5s | 7.7 / 1.6s |
| 12 req/s | 11.9 / 0.7s | 11.9 / 0.75s | 9.0 / 24.9s | 11.4 / 2.3s |
| 16 req/s | 15.8 / 0.7s | 15.8 / 0.76s | 8.8 / 37.3s | 15.1 / 3.6s |
| 20 req/s | 19.8 / 0.7s | 19.8 / 0.77s | 9.4 / 48.8s | 15.4 / 15.6s |
| 24 req/s | 23.7 / 0.8s | 23.6 / 0.82s | 9.4 / 63.5s | 16.7 / 30.0s |

(achieved req/s / request latency p50)

**Here the result reverses.** affinity+P2P matches affinity's near-ideal
ceiling within noise at every offered rate, tracking offered to
saturation at 24 req/s. load+P2P — the arm that won Scenario D — degrades
sharply at the top of the ladder: p50 30.0s at 24 req/s, achieving only
16.7 of 24 offered. Likely mechanism: load-aware placement scatters each
prefix's traffic across more pods than affinity does; at saturation that
costs more in pull/transfer contention than affinity+P2P ever pays, since
affinity+P2P never scatters a prefix's traffic in the first place — the
pull mostly sits idle here (placement rarely diverges from cache), so it
costs nothing to have it available for the rare miss.

Zero restarts, zero failures, 5,040/5,040 requests.

## No single arm wins both regimes

Consistent with series 1's own cross-regime conclusion ("no single
configuration wins both regimes") — this series supplies the specific
data point that was missing: **affinity+P2P**, not just affinity-alone,
loses the concurrency/ownership-contention regime (Scenario D) and wins
the capacity/replication regime (Scenario A). The two regimes:

- **Capacity-driven** (working set spread wider than any pod's cache,
  traffic uniformly distributed across owners — Scenario A here, series
  1's uniform pool, series 1's small-scale Llama pool): affinity-based
  placement concentrates each prefix's traffic tightly enough that pulls
  stay cheap and local; load-aware placement's scattering costs more at
  saturation than it saves in balance.
- **Concurrency/ownership-driven** (many concurrent sessions each pinned
  to a fixed owner pod by a composite scorer, contention builds
  independent of aggregate capacity — Scenario D here): load-aware
  placement avoids the owner-pod queue by never preferring a busy owner;
  affinity-based placement still pays that queueing cost even with the
  pull covering the cache-locality half of it.

The guide ships `epp-affinity-p2p` as the default (reverted back to it
after this series' Scenario A result, having briefly flipped to
`epp-load-p2p` on Scenario D's evidence alone) — the safer
general-purpose choice: close to affinity's ceiling in the capacity-driven
regime, and still a clear improvement over affinity-alone in the
concurrency-driven one, even though it does not match load+P2P there.
`epp-load-p2p` remains the documented recommendation specifically for
workloads shaped like Scenario D.
