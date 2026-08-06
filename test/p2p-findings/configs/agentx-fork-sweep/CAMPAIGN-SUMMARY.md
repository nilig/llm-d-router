# P2P fork campaign: findings summary (2026-08-05/06)

Question: does P2P KV pull help agentic fork workloads (one agent spawns W
siblings sharing a 20-70K-token prefix)?

Answer: no - structurally, in both timing regimes - and the campaign pins the
mechanism. The pull machinery itself is sound; the value condition it needs
(destination empty AND source idle) is exactly what fork workloads never
provide.

## The two failure regimes, both measured

**Burst forks (siblings arrive within one prefill duration).** Spill and pull
race on the same timeline. The index credits the destination the moment the
first sibling is routed there (speculative/in-flight credit), so pull
evaluations see deltas of ~0-10K tokens instead of the full prefix. Pulls that
fire are tail-pulls worth ~2s each; most siblings are suppressed and join the
local recompute. Result across every configuration (precise/approx index,
fitted/unfitted LRU, gate 12288/8650, 3 clusters): 10-19 pulls per run, ~8%
per-cold-start improvement, aggregate wash.

**Staggered forks (real trace timing: 19 of 22 mined fork groups spread
spawns over 60s-74min).** The asymmetry is fully visible - deltas to 113K
tokens, 80 pulls fired (stag-p2p) - and the outcome got WORSE: cold mean
9.7s -> 11.1s, p90 13.5s -> 19.2s, max 22.6s -> 39.2s. Mechanism: in
load-driven spill the source is by definition the overloaded pod (that is why
siblings spilled), and a busy engine serves P2P sessions slowly while the
transfer load degrades it further. 80 concurrent ~35K-token pulls against
saturated holders arrive slower than recompute. With one holder per prefix,
load-aware source sampling has no alternative to offer.

## What holds up

- Per-pull mechanism: 790ms vs 13.9s recompute for a 77K prefix, counter
  verified, reproduced on 3 clusters - WHEN the source is idle.
- Tier-aware source selection fix (fix/p2p-source-cpu-tier): source ranking
  was tier-blind; GPU-only or speculative holders could be nominated and the
  pull then misses the source CPU tier. Fixed arms show the best per-cold
  costs of their families (precise 7.55s, approx 6.84s) with clean closure
  arithmetic (~2s x pulls / cold count).
- The approximate index CAN drive pulls (10 pulls multifork, engagement equal
  to precise under the same conditions); the earlier "structurally blind"
  claim held only for single-burst timing.
- Historical claims audit: the kermit twins' -66/-86% p90 pairs carried 3, 0,
  and 3 pulls respectively with a null replicate and a negative reversal;
  baselines range 4.7-12.3s across identical runs. Fork-tail p90 deltas at
  n~35 are routing-lottery noise unless per-request pull attribution backs
  them.

## Where P2P value lives (destination empty AND source idle)

- Restart/preemption recovery: prefills die, decode's tier holds every live
  session's prefix, fresh prefills pull from a source with no prefill load.
- Scale-up warming: a new pod pulls the working set before taking traffic.
- Hot-replica offload with multiple holders: sampling has real alternatives.

## EPP backlog implied by the data

1. Source-load gate: never emit a source header pointing at a pod whose
   queue/utilization exceeds a threshold - at any delta. (The staggered
   result is the motivation.)
2. Spill-time header attach: the affinity filter knows holder + asymmetry
   before in-flight credit lands; the producer re-derives too late.
3. Pull-join registry instead of speculative presence-faking: dedup by
   "pull inbound to this pod for this prefix", compute deltas on confirmed
   blocks only.
4. Economic gate: fire on saved-time (pullable/peakPrefillThroughput vs
   expected pull time under source load), not a static token delta.
5. First-class pull metrics (headers set, per-pull bytes/latency) - all
   attribution this campaign required engine-counter diffs and log streams.

## Operational findings (cluster-side)

- waldorf fabric fails under NIXL transfer bursts (mlx5dv_devx syndrome
  0x5d668c on DC transport - worked around with UCX_TLS=^dc - then silent
  worker deaths, then NIXL transfer_exception); kermit and piggy fine.
- Decodes die on their SECOND tokenload burst on waldorf and piggy (fresh
  decodes survive identical load); suspected NIXL/UCX leak across bursts;
  engine restart between arms is protocol.
- 100 GiB CPU tier: boot-time UCX registration takes ~6.5 min (silent) and
  intermittently hangs (~40-50% of boots, any node, both clusters); 20 GiB
  tiers never hang. Reproduced signature: silence after "NixlTransport ...
  backends=[UCX]", healthy boots log agent init within seconds.
- The gpu-pruner reclaims weight-loading engines as idle (~35 min lookback);
  boots need a replica guard.
