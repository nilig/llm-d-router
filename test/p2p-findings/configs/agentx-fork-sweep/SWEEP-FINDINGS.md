# When can P2P help? A direct measurement

## The question

Two campaigns struggled to show P2P value, and both hit the same wall: pulls
would only fire when the prefill CPU tier was shrunk to 25 GiB/rank (later
12 GiB) against the blog's 100-150, and the effect only reproduced at a
concurrency the campaign's own handoff called saturated.

The usual next move is another A/B. Instead this measures the precondition
directly.

## What is measured, and why it needs no A/B

`p2psource/producer.go` `PreRequest` compares, for every request, how many
prefix tokens the **best peer** holds against how many the **rank the router
chose** already holds, and emits the pull directive only when

    bestCachedTokens - computingCachedTokens >= minCachedTokenDelta

That difference is the entire precondition for P2P, it is logged per request at
`V(logging.TRACE)`, and it is a property of routing state rather than timing. So
it can be read off a single arm -- no control, no counterbalancing, no
sensitivity to cache carryover, arm order, TTFT noise, or saturation.

`tools/delta_stats.py` extracts it from the EPP stream.

## Method

One fork group per replay (a burst of sibling subagents sharing an exact
prefix), K groups replayed concurrently to scale the working set. Distinct
windows, so K multiplies distinct prefix bytes rather than re-running the same
blocks. EPP restarted before each point so every K starts from an empty precise
index; the first ~30 s of each run is therefore index warm-up and inflates
`no_peer`.

Cell: `nilig-agentx-slo`, GLM-5.2-FP8, 8 prefill + 8 decode ranks,
**288,760 tokens/rank** of GPU KV (measured), 100 GiB/rank CPU offload tier on
both roles, `minCachedTokenDelta: 12288`. Router config is `nilig-p2p`'s
`blog-precise-p2p.yaml` verbatim -- the pair with published engagement.

## Results

| K | distinct prefix | evals | self-match | non-self | median Δ | p90 Δ | max Δ | clearing gate | pulls |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | ~40 K | 50 | 26 (52%) | 24 | 0 | 0 | 0 | 0 | 0 |
| 4 | ~163 K | 385 | 190 (49%) | 195 | 0 | 0 | 1,920 | 0 | 0 |
| 8 | ~330 K | 777 | 459 (59%) | 318 | 0 | 0 | 2,560 | 0 | 0 |
| 14 | ~600 K | 1,690 | 833 (49%) | 857 | 0 | 0 | **12,224** | 0 | 0 |

Δ = `bestCachedTokens - computingCachedTokens`, in tokens.

## Reading

**The median advantage is zero at every K.** Not small -- zero. The p90 never
leaves zero either. Only the extreme tail moves (0 -> 1,920 -> 2,560 ->
12,224 tokens) -- at K=14 it reached one 64-token block short of the gate, so
working-set pressure demonstrably moves the tail toward the crossover without
reaching it inside this sweep's range.

**Affinity gets better under load, not worse.** The self-match share rises
(52% -> 59%): the busier the cell, the more often the router places a request on
a rank that already holds its prefix. The hypothesis this campaign was built on
-- that parallel subagent siblings cannot all sit on the holder -- is false
here. They can, because the blocks are on every rank that needs them.

**The tiers are working.** 4,080 store operations and 372 GB written across the
8 prefill ranks. Peers are not empty; they simply hold nothing the chosen rank
lacks.

So P2P's addressable gap on this cell is not "small", it is **structurally
absent**. Prefix affinity plus ample per-rank capacity leaves no residual. This
is consistent with the control arm capturing 89.4% of a 91.3% theoretical
ceiling -- 98% of available reuse.

## What this implies

P2P is a **capacity** feature, not a routing feature. It pays when ranks
genuinely cannot all hold the working set. The weka campaign's asymmetric
prefill tier was therefore not a thumb on the scale but the necessary
condition -- it manufactured the eviction that creates a peer advantage.

The deployment guidance that follows: enable P2P when per-rank cache capacity is
small relative to the live working set. Where capacity is ample, prefix-aware
routing already captures the reuse and P2P has nothing to add.

## Caveats

- K=8 and K=14 are **saturated** (91 requests waiting at K=8), so no latency
  claim is made from them. The Δ statistic is a routing-decision property and is
  unaffected.
- 14 concurrent groups is ~600 K tokens of distinct prefix against
  288,760 tokens/rank across 16 ranks -- still comfortably inside per-rank GPU
  capacity. This sweep bounds the region it covers; it does not prove Δ stays
  zero at far larger working sets.
- The obvious next lever is `PREFILL_GPU_MEM_UTIL`, which shrinks per-rank GPU
  KV without touching the workload and moves the pressure ratio directly.

## Addendum: the pull, achieved and measured (2026-08-04)

The sweep isolated why pulls were not firing; fixing those conditions produced
one, verified at all three layers, on an idle cluster.

### What had to change

1. **Router semantics, not capacity.** The prior arms (`blog-precise`) score
   affinity against the actual queue, which is empty at low load -- they never
   place a sibling anywhere but the holder. The `token-precise` pair's
   `prefix-cache-affinity-filter` instead *models* the holder as busy for
   `in-flight tokens / peakPrefillThroughput` seconds, so a sibling arriving
   inside the seed's ~21 s modeled window spills to a cold rank, and
   `p2p-source-producer` directs the pull. Spill is the pull generator; tier
   eviction is not (nothing evicts at K=1 on any tier size).
2. **Spawn gaps longer than prefix compute.** ~21 s gaps vs ~12 s compute let
   the index seed between spawns. Bursty groups scatter and all recompute.
3. **The measured window itself**: trace `d5654f…` group 3, W=8,
   75,520-token shared prefix, cut at the last child's first request; 6 tail
   turns of one child dropped for our `max-model-len 120000` (the source cell
   ran `MAX_MODEL_LEN=auto`; its own replay served a 172,285-token input).

### The result (run 1, this cell)

| branch start (~77 K tok) | control TTFT | p2p TTFT | placement |
|---|---:|---:|---|
| seed `_007` | 13,800 ms | 13,904 ms | cold compute, both arms |
| 6 warm siblings | 1,002-1,598 | 910-1,278 | affinity, warm rank |
| **`_011`, pulled** | 1,019 | **790** | **spilled cold; pulled 77,312 tok from decode rank 3** |

Three-layer verification: router directive (`delta = 77,376 -> set header ->
10.0.11.101:8003`), source session (`P2P 10.0.11.101:7780: accepting incoming
connection from 10.0.6.151:7781`, decode DP3), destination counters
(`external_prefix_cache_hits += 77,312`, frozen through the 0-pull control).
The header carries the serving endpoint and the engine resolves the
rank-compensated p2p port across pods.

### Reading

- **Per-pull value: ~13.1 s of prefill becomes 790 ms** (the 13.8-13.9 s cold
  price is measured in the same table). Pre-registered prediction was 12.38 s;
  measured within 6%. Implied avoided-prefill rate 5,861 tok/s, consistent
  with the prior cell's 6,069-6,273.
- The pulled branch also beat the cache-favored control (790 vs 1,019 ms).
- **At idle, the aggregate arm difference is ~zero** -- affinity already serves
  most siblings warm. The system-level claim is therefore: *P2P makes
  load-spill placement free.* The router can move work off a modeled-busy rank
  knowing the destination pulls in ~0.8 s instead of recomputing for ~13 s.

### Caveats

- n=1 pull on this cell (replicates r2-r4 in progress); 1 of 7 opportunities
  spilled vs the source cell's 5/7 and 3/7 (8 prefill ranks here vs 16 there).
- Control ran second and warm (`--cache-bust` requires the AgentX scenario's
  timing mode, unavailable off-scenario on this aiperf build) -- a bias that
  favors the control and survived anyway.
- `subagent_009` absent from the p2p arm's export (loader quirk, open).
- EPP `requestID` does not join to aiperf `x_request_id` (envoy re-mints);
  attribution used timing + ISL correlation and engine counters.

## Addendum 2: fork value is tail cleanup (wide twins, 2P+2D)

Two further experiments on 2026-08-04, cell scaled to 2 prefill + 2 decode pods
(32 GPUs) after a W=44 burst overran single-pod decode KV (1.76M live tokens vs
1.68M capacity; engine 500s, pod replaced -- see gate D2 for how a dead-fleet
run still yields a complete-looking export).

### Hot-spot twins, one prefill pod (W=10, ~70K prefix, bursty)

p2p arm fired 5 pulls (352,000 tokens, engine-confirmed) but LOST on latency:
pulled branches 3.5-4.2 s vs the baseline's 1.0-1.8 s. The baseline had a fast
path this analysis has not yet attributed (candidates: same-pod tier service,
in-flight prefix sharing). Recorded as a negative result: on a single prefill
pod, router-level P2P is not the cheapest rescue.

### Wide twins, two prefill pods (W=44 baseline / W=43 p2p, ~40K prefix)

| | baseline W=44 | p2p W=43 |
|---|---|---|
| starts < 2 s | 26/36 | 31/33 |
| starts 2-6 s | 7 | **0** |
| burst-head colds (6-12 s) | 2 | 2 |
| pathological | 1 x 363.8 s | none |
| p50 | 1,339 ms | 1,248 ms |
| **p90** | **4,686 ms** | **1,606 ms (-66%)** |
| pulls | 0 | 3 (121,728 tok, engine-confirmed) |

Reading: recompute at 40K costs only ~6.6 s and holders multiply exponentially,
so the fork self-heals and the median floors at ~1.3 s in both arms. What P2P
removes is the straggler band -- every 2-6 s entry -- leaving only the two
burst-head colds that no mechanism can serve (they predate any copy existing).

Convergence across three campaigns: Maroon's forks (aggregate flat, p99
-43%/-37%), our W=8 (one tail event), our W=43/44 (p90 -66%, median flat).
**Fork value is tail cleanup.** An aggregate-mean win requires the no-live-holder
regime instead (restart/preemption recovery), where every session pays the cold
price in baseline.

Twin caveat: matched-but-different windows per arm (43 vs 44 children,
prefixes within 0.8%); reverse-assignment replicate in progress.
