# P2P fork campaign - results and conclusions for review

Question investigated: does P2P KV pull help agentic fork workloads - one
agent spawning W siblings that share a 20-70K-token prefix - on a wide-EP
GLM-5.2-FP8 P/D cell (2-3 prefill + 1-2 decode, DP8/EP per pod, block 64)?

Conclusion under review: **no, structurally, in every regime tried** - and
the campaign claims to have pinned the mechanism well enough to say where
P2P value does live. Please poke at the attribution chain, not just the
numbers.

All raw data referenced below is in this directory: per-arm aiperf exports
and EPP decision traces under `multifork/results/` and `staggered/results/`,
composed-workload manifests, drivers under `tools/`, and the operational
gates in `CANDIDATE-GUIDE-GATES.md`.

## 1. The workloads

- `multifork-v1`: six real fork windows (W=30/15/10/6/5/4) from the AgentX
  traces, replayed sequentially with 30s gaps; tight-burst spawn timing.
- `staggered-v1`: five real fork windows replayed with their genuine
  staggered spawn timing (spans 233-995s), overlapped so 2-4 sessions are
  always active. Mining note: 19 of 22 fork groups in the raw traces have
  spawn spans over 60s - the tight burst we benchmarked first is the rare
  case, not the common one (`staggered/candidates-staggered.json`).

Metric: branch-start TTFT per sibling; primary attribution readout is the
cold population (>= 3s = did not land on a warm prefix) and per-cold mean,
because the aggregate p90 at n~35-60 flips on 2-3 requests' warm/cold
placement. Pull attribution is from engine counters
(`external_prefix_cache_hits`, `kv_offload_load_size`) plus the EPP trace,
never TTFT alone.

## 2. Burst forks: pulls fire late and small

With the tier fix (see section 5) on both index types, same image, engine
restarts between every arm:

| multifork arm | pulls | cold n @ mean |
|---|---|---|
| precise, no p2p | 0 | 29 @ 8.19s |
| precise + p2p (gate 8650) | 15 | 35 @ 7.55s |
| approx, no p2p | 0 | 31 @ 7.48s |
| approx + p2p (gate 8650) | 10 | 31 @ 6.84s |

The approx pair drew identical spill splits (31 cold / 30 warm both arms),
making it the cleanest comparison of the campaign: per-cold improvement
-8.5%, and the arithmetic closes (10 pulls x ~2s saved / 31 colds = the
0.64s per-cold delta). Same closure on the precise side.

Why only ~2s per pull: by evaluation time the destination is already
credited with the prefix head (speculative/in-flight entries land at
routing time), so deltas are ~10K tokens, not ~40K - pulls cover the tail
of a recompute already underway. Whole-prefix economics (790ms vs 13.9s,
the microbenchmark) never apply.

## 3. Staggered forks: pulls fire at volume and hurt

| staggered arm | pulls | cold @ mean | p90 |
|---|---|---|---|
| precise, no p2p | 0 | 34 @ 9.7s | 13.5s |
| precise + p2p, ungated | 80 | 35 @ 11.1s | 19.2s |
| precise + p2p, queue-depth gate (>4) | 80 | 34 @ 10.5s | 14.5s |
| precise + p2p, load gate (running+waiting>1) | 70 | 36 @ 10.3s | 16.2s |
| approx, no p2p | 0 | 30 @ 8.8s | 10.6s |
| approx + p2p | 1 | 27 @ 7.8s | 9.1s |

Here the asymmetry is fully visible (deltas to 113K tokens) and pulls fire
en masse - and every gated variant still loses to the baseline. Mechanism:
in load-driven spill the source is by definition the overloaded pod, and a
busy engine serves its P2P sessions slowly while the transfer load degrades
it further ("busy-owner tax"). Two gate iterations failed for an
instructive reason: the EPP sees load per rank, but contention is physical
per pod - the holder rank often shows running+waiting ~ 0 while sibling
ranks grind the same node, and 70 multi-GB transfers ride the compute
nodes' shared NIC regardless. The approx arm's 1-pull "win" is baseline
variance plus accidental protection: its modeled index goes blind in this
regime.

## 4. The historical claims audit

Re-attributing the earlier kermit twins runs (the -66%/-86% p90 pairs):
the winning pair carried 3 pulls, the replicate carried 0 pulls and showed
no delta, the reversed pair carried 3 pulls and regressed. Identical-config
baselines range 4.7-12.3s p90. Fork-tail p90 deltas at this n are routing
lottery unless per-request pull attribution backs them - which also
explains cross-cluster observations of large "P2P improvements" in arms
whose engine counters show zero bytes pulled.

## 5. What holds up

- **Per-pull mechanism**: 790ms vs 13.9s for a 77K prefix, counter
  verified, three clusters - when the source is idle.
- **Tier-aware source selection** (PR branch
  `fix/p2p-source-cpu-tier-pr`): selection was tier-blind, so GPU-only or
  speculative holders could be nominated and the pull then misses the
  source CPU tier. With the fix, the p2p arms post the best per-cold costs
  of their families (section 2).
- **The approximate index can drive pulls** (10 in multifork) - the earlier
  "structurally blind" claim held only for single-burst timing.

## 6. Conclusions proposed for sign-off

1. Fork workloads get no aggregate benefit from P2P as shipped: scarce
   pulls are too late (~2s tail value), abundant pulls tax the bottleneck.
2. The value condition is **destination empty AND source idle**:
   restart/preemption recovery, scale-out warm-up, session-resume - not
   load-driven spill, where pulling from the pod you just fled is
   self-defeating.
3. EPP work implied (priority order): source load gating at pod
   granularity; source attach at the spill decision (where full asymmetry
   is still visible); pull-join dedup replacing speculative
   presence-faking; economic (time-based) gate; first-class pull metrics.
4. The workload-level showcase should be restart-recovery.

## 7. Known limitations

- n=1 run per arm-condition except where noted; cold-count lottery spans
  29-36 across identical configs. Per-cold mean is the defended metric.
- The 18.8s-class pull stall seen once was never reproduced under full
  capture (zero `kv_offload_lookup_sync_delay` in instrumented runs).
- Two clusters showed engine-side fragility unrelated to routing (decode
  death on second transfer burst; one fabric rejects DC transport) -
  documented in `CAMPAIGN-SUMMARY.md`, worked around, not root-caused.
