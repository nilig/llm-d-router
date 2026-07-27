# P2P benchmarks, series 4: UC2 lookup-hang resolved; UC3/UC4 re-validation; UC2 paired A/B

> **Headline for the A/B section below**: on this rig and stack, `load+P2P`
> does **not** reproduce the blog's Use Case 2 result. The pull is worth
> about **+2% achieved throughput** at saturation — smaller than the
> run-to-run spread — and the control arm (`load`, no pull) **does not
> collapse**. See [UC2 paired A/B](#uc2-paired-ab-load-vs-loadp2p-4-ladders-counterbalanced).

This series closes the lookup-hang blocker that stalled the blog's UC2/3/4
re-validation ([[project_p2p_guide_docs_pr]], "BLOG UC2/3/4 RE-VALIDATION
2026-07-25"), then re-runs the affected use cases on the fixed stack.

## UC2: Llama-3.1-8B 4x aggregated pool, load+P2P — hang resolved

### Background

The original UC2 +P2P run (2026-07-25, `nightly-4080263b` + `generic-p2p-src-v2`
overlay) hung under load: at 16-24 req/s achieved throughput collapsed from a
baseline of ~9.5 req/s to 2.5-3.8, with 55-81 failures per stage. Log
signatures: `malformed 'fetch': duplicate fetch ... disconnecting` and
`store job ... timed out`. Root cause traced (this session) to a server-side
round-overlap bug in `_OutboundRequestState` (upstream
[vllm#49820](https://github.com/vllm-project/vllm/issues/49820)) and a
related `HIT_PENDING`-forever leak
([vllm#49829](https://github.com/vllm-project/vllm/issues/49829)) — both
independent of, and unrelated to, the two local fixes
(`defect12_fix_lookup-deadline-sticky-miss.diff`,
`defect3_fix_pending-wait-deadline.diff`) that had previously been assumed
necessary to unblock this use case.

### Overlay and fix provenance

Deployed on `vllm/vllm-openai:nightly-1240c74c0a47473449cf0c3a9c2d87a1e159f73b`
(predates all three upstream fixes below, so all P2P-tier files are overlaid
via ConfigMap) with three upstream fixes combined:

- [vllm#48021](https://github.com/vllm-project/vllm/pull/48021) — the P2P
  secondary tier itself. **MERGED** into vllm main 2026-07-26.
- [vllm#49877](https://github.com/vllm-project/vllm/pull/49877) — scopes
  server-side fetch/serve state to individual lookup→fetch rounds, closing
  #49820's round-overlap race. Draft as of this run.
- [vllm#49850](https://github.com/vllm-project/vllm/pull/49850) — bounds how
  long a request defers on a permanently-`HIT_PENDING` block
  (`hit_pending_deadline_s`, scheduler-layer), closing #49829. Draft as of
  this run. Its `scheduler.py` was verified (line-offset diff against the
  live `p2p-fix-49671` ConfigMap) to already carry
  [vllm#49671](https://github.com/vllm-project/vllm/pull/49671)'s merged
  crash fix (`finished_signaled` deferred-cleanup pattern), so the older
  `p2p-fix-49671` overlay is superseded and dropped.

`#49850`'s own `base.py` predates a main commit that added
`ReqContext.set_state`/`get_state`/`replicated_layout` (load-bearing for the
P2P tier's `manager.py`) — using it verbatim would have silently broken the
P2P tier. Its two real additions (`DEFAULT_HIT_PENDING_DEADLINE_S`, the
`hit_pending_deadline_s` field + validation in `OffloadingSpec.__init__`)
were hand-merged onto the current, correct `base.py` instead. Overlay: 11
files at [configs/uc2-lookup-hang-resolved/overlay-files](configs/uc2-lookup-hang-resolved/overlay-files),
deployment manifest
[configs/uc2-lookup-hang-resolved/uc2-llama-resume.yaml](configs/uc2-lookup-hang-resolved/uc2-llama-resume.yaml).

**No `defect12` reimplementation.** Its diff (2026-07-14) could not even be
mechanically reapplied — the client-side lookup registry it patched
(`_lookups` dict + timeout) has since been rebuilt into a `ClientPhase`
state machine with no per-lookup timeout by design. Verified directly
against the current code
([configs/uc2-lookup-hang-resolved/repro_defect12_check.py](configs/uc2-lookup-hang-resolved/repro_defect12_check.py),
no mocks of the class under test): a lookup whose response never arrives
stays stuck with no natural recovery — until the session actually
disconnects, at which point `ClientRole.close()` reports it in
`failed_req_ids`, and `P2PSecondaryTierManager.lookup()` (`manager.py:345`)
returns `MISS` for it on the next call once `close()` populates
`_failed_req_ids` (`manager.py:702`). Full chain confirmed end-to-end in
code. This closes `defect12`'s original failure mode (a lost
`LookupMsg`/`LookupRespMsg` recovered only via full session teardown) for
exactly the trigger that caused the original hang (`#49877`'s duplicate-fetch
race). One narrower, separate gap remains in `ZmqTransport._recv_router()`
(a malformed-frame or `msgspec` decode failure is silently dropped without
marking the connection dead) — real but requires actual message corruption
to trigger, not the mechanism behind the observed hang.

### Mechanism gate

Before the load run: all 4 pods' kv-events subscriptions connected, 30/30
smoke-burst requests succeeded, `kv_offload_load_bytes_total`/
`kv_offload_store_bytes_total` both firing (3 pods pulled, 1 pod — the
seed/owner — stored), zero duplicate-fetch/disconnect signatures in engine
logs at low rate.

### Ladder result (2-24 req/s, `uc2_llama_pool.yaml.in` shape: 64-group
shared-prefix pool, 16K system prompt, 256 question/output tokens, 60s/stage)

| rate (req/s) | sent | ok | fail |
|---:|---:|---:|---:|
| 2 | 120 | 120 | 0 |
| 4 | 240 | 240 | 0 |
| 6 | 360 | 360 | 0 |
| 8 | 480 | 480 | 0 |
| 12 | 720 | 720 | 0 |
| 16 | 960 | 960 | 0 |
| 20 | 1200 | 1200 | 0 |
| 24 | 1440 | 1439 | 1 |

Raw output: [configs/uc2-lookup-hang-resolved/ladder-output.txt](configs/uc2-lookup-hang-resolved/ladder-output.txt).
Driven directly against the endpoint
([configs/uc2-lookup-hang-resolved/uc2_ladder.py](configs/uc2-lookup-hang-resolved/uc2_ladder.py))
rather than through `llmdbenchmark` — per
[[feedback_llmdbenchmark_cli_unreliable]] its CLI is unreliable for exactly
this kind of long multi-stage run, and this deployment wasn't wired through
the harness's own stack-standup.

Zero pod restarts across all 4 pods for the entire run. Zero duplicate-fetch,
disconnect, `HIT_PENDING`-expiry, or traceback signatures in any pod's logs
at any rate. The single 24 req/s failure is consistent with the driver's own
120s client-side timeout under p95=102.5s queueing at that stage, not a
defect signature. The pull mechanism stayed engaged the entire run — each
pod's `kv_offload_load_bytes_total` grew to 58-84GB by the end (store to
~2.85-2.9TB), ruling out "it just stopped pulling" as an alternative
explanation for the clean result.

**Direct contrast with the original run**: achieved throughput collapsing to
2.5-3.8 req/s with 55-81 failures at these same 16-24 req/s rates, vs. this
run's 100% success through 20 req/s and 99.93% at 24 req/s.

**Conclusion: the UC2 lookup-hang is resolved by `#48021`(merged) + `#49877`
+ `#49850` alone.** Neither local diff (`defect12`, `defect3`) is needed —
`defect3`'s effect is achieved by `#49850` at a different layer (confirmed by
direct patch comparison), and `defect12`'s target failure mode is closed by
the pre-existing `close()`/`_failed_req_ids` recovery chain once `#49877`
removes the trigger that caused disconnects in the first place.

---

## UC3: gpt-oss-120b P/D docQA (prefill-to-prefill P2P) — mechanism confirmed clean

### Background and scope

UC3's original investigation ([[project_pd_multiturn_experiment]]) established
that gpt-oss's hybrid/interleaved-sliding-window attention permanently blocks
cross-TP P2P sessions (config-fingerprint mismatch, not a bug — a vLLM
connector limitation), so prefill-pulls-from-decode never forms for this
model. The mechanism that DOES work and DOES win is **prefill-to-prefill**
pull: docQA's per-conversation document prefix gets computed once by whichever
prefill pod first serves it, and other prefill pods that later serve requests
against the same document pull it from the CPU tier instead of recomputing —
proven clean on 2026-07-18 (8P+8D TP=1, C=192: armA guide-only p50 11.94/p95
71.6/p99 106.1s at 5.68 t/s vs armB guide+P2P p50 1.16/p95 55.2/p99 80.0s at
7.96 t/s, both 1152/1152, driven by 52M P2P external-hit tokens).

Tonight's run re-validates that this mechanism is still healthy on the fixed
stack (`#48021`+`#49877`+`#49850`), scaled down for time budget: **4P+4D**
(from 8P+8D) and **48 conversations at C=48** (from 192 at C=192) — same
per-turn shape (6 turns, 256 input/256 output tokens, 49,152-token private
system-prompt document per conversation). This is a mechanism-health check,
not a fresh throughput A/B: no plain-NixlConnector baseline arm was run
tonight (each fresh rig deploy cost significant unplanned time — see below —
and re-deriving the win itself wasn't the point; the original comparison
above already establishes it). Manifests:
[configs/uc3-gptoss-pd-resolved](configs/uc3-gptoss-pd-resolved).

### Two real deploy bugs found and fixed (own manifest, not product defects)

1. **`cpu_bytes_to_use` exceeded `/dev/shm` size.** Set the CPU tier to 64GiB
   but sized the pod's shm `emptyDir` at 24Gi — `SharedOffloadRegion.__init__`
   failed with `OSError: [Errno 14] Bad address` on `mmap_obj.madvise()`,
   crash-looping every pod. Fixed: shm sized to 80Gi (> `cpu_bytes_to_use`),
   matching the established "shm > cpu_bytes" rule
   ([[project_p2p_well_lit_path_plan]]).
2. **Prefill's engine was bound to the wrong port.** Built prefill as a bare
   engine on 8200, mirroring decode's engine port (decode uses 8200 because
   its sidecar occupies 8000) — leaving nothing on 8000. Every request
   failed with `dial tcp <prefill-ip>:8000: connect: connection refused`,
   surfacing as 502.

   Root cause: `InferencePool.spec.targetPorts` is **pool-wide** (chart
   `router.modelServers.targetPorts` →
   `config/charts/routerlib/templates/_inferencepool.yaml:10-13`), so EPP
   addresses every pod matched by the pool selector on the same port, and
   hands decode's sidecar that `host:port` for the prefill leg
   (`disagg_headers_handler.go:135` builds it as
   `net.JoinHostPort(targetPod.Address, targetPod.Port)`; the sidecar just
   forwards to whatever it is given —
   `chat_completions.go:86-99` → `connector_nixlv2.go:54`). There is no
   per-role port override. Prefill must therefore serve the pool port
   itself.

   The `pd-disaggregation` recipe
   (`guides/recipes/modelserver/base/single-host/pd`) resolves this exactly:
   `base/prefill-deployment.yaml` binds prefill's **modelserver container to
   `containerPort: 8000` directly, with no sidecar**, while
   `vllm/kustomization.yaml` patches the routing-proxy in against
   `target: {kind: Deployment, name: decode}` only ("Add routing sidecar to
   the decode deployment"), and `base/kustomization.yaml` moves decode's own
   engine to 8200 to free 8000 for that sidecar. So the correct fix is
   `--port=8000` on the prefill engine.

   **The runs below were executed with a wrong fix**: a routing-proxy
   sidecar bolted onto prefill (8000 → engine 8200) instead of simply
   rebinding the engine. That satisfies the port requirement and the
   measurements are valid for the KV mechanism under test, but it adds a
   proxy hop on the prefill leg that the guide topology does not have, so
   the absolute TTFT figures carry a small amount of overhead that is not
   representative. The manifests committed here have since been corrected
   to the recipe's layout (bare prefill engine on 8000, sidecar on decode
   only) and therefore **do not byte-match what produced the numbers below**
   — rerun against them if exact latency figures matter.

### Mechanism gate

Full P/D round-trip confirmed first (single chat completion, 200 OK, correct
NIXL transfer). A 17-request low-concurrency burst against one shared prefix
landed entirely on one prefill pod — zero P2P activity — which is *expected*,
not a defect: the original investigation's own finding is that
`prefix-cache-scorer`'s affinity term dominates at low concurrency, and the
mechanism only engages once real concurrent pressure forces placement
divergence across the prefill fleet.

### docQA result (48 conversations × 6 turns, C=48, 49,152-token system
prompt each — [configs/uc3-gptoss-pd-resolved/uc3_docqa_out.log](configs/uc3-gptoss-pd-resolved/uc3_docqa_out.log))

288/288 turns succeeded, 0 failures, duration 128.8s, throughput 2.24
turns/s, TTFT p50=3.05s / p95=76.2s / p99=99.0s (tail dominated by the
49K-token cold prefill cost on a request's first turn against a given
document, at C=48 saturating 4 prefill pods).

All 4 prefill pods show **both** `kv_offload_load_bytes_total` and
`kv_offload_store_bytes_total` firing (load 90MB-17.3GB, store 10.5-76.5GB
per pod) — confirming genuine cross-pod pull activity under real placement
divergence, not just "didn't crash." Zero pod restarts across all 8 pods.
Zero duplicate-fetch, disconnect, traceback, `EngineDeadError`,
`HIT_PENDING`-expiry, or fingerprint-mismatch signatures anywhere in the
logs.

**Conclusion: the prefill-to-prefill P2P mechanism for gpt-oss docQA is
healthy on the fixed stack** — same mechanism, same topology class, same
workload shape as the original clean win, no regressions, no crashes, no
lookup-hang symptoms. The throughput win itself (10x p50, +40% tput) was
established in the original investigation and isn't re-derived here; this
run confirms it isn't broken by anything that changed since.

---

## UC4: Llama-3.1-8B P/D multi-turn chat (prefill-pulls-from-decode) — mechanism confirmed, small scale

### Background and scope

UC4 targets the harder cross-role mechanism: a fresh turn's prefill leg
pulling the *previous turn's decode-generated answer* as session history,
so it doesn't recompute the whole growing conversation from scratch. This
only works when the model's chat template is round-trip-stable
(`tokenize(generated_text) == generated_token_ids`) — proven true for
Llama-3.1-8B, proven FALSE for gpt-oss's harmony template (a same-pod
control hit exactly the prefix boundary and 0 hits on its own generated
segment — see [[project_pd_multiturn_experiment]], "ROOT CAUSE (settled
2026-07-18)"). That investigation got this working end-to-end once
(`llama-chat-pull3.sh`, 1P+1D, hand-primed session) and again at larger
scale ("Run N", 4P+4D and 2P+4D, EPP-driven, 477K-1.65M tokens pulled per
run) — but only after several days of chasing cross-TP rejection,
cold-session first-miss hangs, and the retokenization dead-end above.

Tonight's run reuses that precedent directly: same-TP=1 both roles, EPP
arm B (precise + p2p producers on the prefill profile only, delta 1024),
natural EOS (no `ignore_eos` — forced continuation breaks the
retokenization chain), the actual generated text carried forward as each
turn's assistant message (not a filler, unlike UC3's docQA driver — this
one's whole point depends on it).  Scaled down to **2P+2D** (from Run N's
4P+4D) and **16 conversations × 6 turns** for time budget. Applied both
UC3 lessons preemptively (something serving the pool port on prefill; shm
sized above `cpu_bytes_to_use`) — this rig came up clean on the first
deploy, no repeat of UC3's two bugs. As with UC3, the run used the
sidecar-on-prefill workaround rather than the recipe's bare-engine-on-8000
layout (see UC3 bug 2 above); the committed manifest has been corrected to
the recipe layout and so does not byte-match the run that produced the
numbers below. Manifests:
[configs/uc4-llama-pd-resolved](configs/uc4-llama-pd-resolved).

### Result

96/96 turns succeeded, 0 failures, duration 5.2s, throughput 18.4 turns/s,
TTFT p50=549ms/p95=1030ms
([configs/uc4-llama-pd-resolved/uc4_chat_out.log](configs/uc4-llama-pd-resolved/uc4_chat_out.log)).
This workload is short (6-word topics, ≤150-token answers) and fast enough
that it mostly didn't generate the placement pressure needed to force a
cross-pod pull — matching the same low-concurrency-favors-affinity pattern
observed in UC3's initial smoke test.

One prefill pod (`kfgzq`) shows only local `store` activity (its own
requests never needed to pull). The other (`rfxmv`) shows **both**
`kv_offload_load_bytes_total` (16.7MB) and `store` — a genuine, if modest,
confirmed prefill-pulls-from-decode event: at least one turn's prefill
leg landed on a pod that didn't own the conversation's history and
successfully pulled it from decode instead of recomputing. Small next to
Run N's 477K-1.65M tokens/run (different scale, different concurrency —
not a discrepancy), but non-zero, and that's the bar for "the mechanism
still works": zero fingerprint-mismatch, zero peer-down, zero disconnect,
zero hang signatures anywhere in the logs; zero pod restarts across all 4
pods.

**Conclusion: prefill-pulls-from-decode is confirmed healthy on the fixed
stack** — the harder of the two P/D mechanisms, reproduced cleanly on the
first attempt tonight (after applying UC3's lessons up front), where the
original investigation needed several days to work through cross-TP
rejection, cold-session hangs, and the retokenization dead-end. Not
re-derived tonight: Run N's actual throughput/latency comparison (TTFT
parity verdict — "a capacity story, not latency, at this model scale") —
that finding stands from the original investigation; this run only
confirms the underlying mechanism hasn't regressed.

---

## UC2 paired A/B: `load` vs `load+P2P` (4 ladders, counterbalanced)

The UC2 section above establishes only that the lookup-hang is fixed — it
was a single-arm run. It does **not** test the blog's Use Case 2 *claim*,
which is comparative. This section does, with a proper paired design.

### Why this was needed

The single-arm UC2 numbers landed suspiciously close to the `load`-no-pull
baseline recorded 2026-07-25, which would contradict the blog. That
comparison was invalid (different harness, different engine build), so it
could not settle anything either way — but it was close enough to parity to
require a real A/B before publishing behind the claim.

### Design

- **Arms differ by exactly one plugin.** `uc2-values-load.yaml` (control)
  vs `uc2-values-load-p2p.yaml` (treatment); identical placement policy
  (`queue-scorer` + `kv-cache-utilization-scorer` + `weighted-random-picker`),
  the only delta being `p2p-source-producer`.
- **Counterbalanced ABBA**: A1, B1, B2, A2 — so any monotonic cluster drift
  cancels rather than loading onto one arm.
- **Fresh cold rig per ladder**: all 4 engine pods deleted and recreated
  before every run, so no arm inherits a warm cache from its predecessor.
- **Mechanism gate before every ladder**, with a *unique* prefix per gate
  (see trap 2 below). Treatment gates confirmed the exact pull signature —
  1 owner pod at `load=0`, 3 non-owner pods each pulling 2.20 GB. Control
  gates confirmed `load=0` on all 4 pods against a *fresh* prefix, so the
  zero means "pull disabled", not "nothing left to pull".
- Workload identical to `uc2_llama_pool.yaml.in`: 64-group shared-prefix
  pool, 16K-token system prompt, 256 question/output tokens, stages
  2/4/6/8/12/16/20/24 req/s x 60s. 5,520 requests per ladder, **22,080
  total, zero failures across all four**.
- Driver: [configs/uc2-ab-load-vs-loadp2p/uc2_ladder2.py](configs/uc2-ab-load-vs-loadp2p/uc2_ladder2.py),
  which adds the metric the first pass lacked — **achieved throughput**
  (completions / stage wall-clock including drain), the quantity the blog's
  claim actually rests on.

### Result: achieved throughput (req/s), saturation stages

| rate | A1 | A2 | **A mean** | B1 | B2 | **B mean** | delta |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 12 | 8.04 | 8.34 | **8.19** | 8.73 | 7.86 | **8.29** | +1.3% |
| 16 | 8.30 | 8.25 | **8.28** | 8.09 | 8.41 | **8.25** | −0.3% |
| 20 | 8.07 | 8.16 | **8.12** | 8.44 | 8.81 | **8.62** | +6.3% |
| 24 | 8.06 | 8.22 | **8.14** | 8.56 | 7.88 | **8.22** | +1.0% |

Overall saturation mean: **A = 8.18, B = 8.35 → +2.0% for the pull.**

**That +2.0% is not distinguishable from noise.** The between-arm
difference is 0.168 req/s; the within-arm run-to-run spread is 0.125
(A) and 0.215 (B) req/s. The effect is smaller than the treatment arm's own
variance. Individual stages swing both directions across repeats — rate 12
went +8.6% in run 1 and −2.2% in run 2; rate 24 went +6.2% then −2.2%.
Reporting any single stage would have produced a headline number that the
repeat erases.

### Result: latency p50, saturation stages

| rate | A mean | B mean | delta |
|---:|---:|---:|---:|
| 12 | 26.0s | 22.6s | −13.2% |
| 16 | 41.5s | 39.2s | −5.6% |
| 20 | 51.2s | 50.6s | −1.2% |
| 24 | 67.0s | 65.6s | −2.1% |

Latency is the better-behaved signal: the pull is ahead at **all four**
saturation rates. Direction is consistent (4/4), so a real effect is
plausible, but the magnitude is small outside rate 12 and the design has
n=2 per arm — enough to reject a large effect, not enough to size a small
one precisely.

### The premise does not reproduce

The blog's UC2 narrative rests on load-balancing *without* the pull being
catastrophic once the working set exceeds per-pod cache — the series-1
observation that the no-pull arm "COLLAPSES", grinding to ~46s p50 at the
top of the ladder.

**That did not happen here.** The control arm saturated cleanly at ~8.2
req/s and completed 11,040 requests across two full ladders with **zero
failures** and zero restarts. It degrades with offered load exactly as a
saturated system should, and the pull arm saturates at essentially the same
ceiling. Both arms are prefill-capacity-bound at the same point; the pull
shifts where time is spent, not how much total work the fleet can do.

The working-set premise itself does hold on this rig (64 x 16K = ~1.02M
tokens against a 16 GiB per-pod CPU tier, ~131K tokens at Llama-8B's ~128
KB/token — so the pool genuinely does not fit per-pod). The regime is
right; the dramatic outcome is not there.

### What this does and does not license

- It does **not** support publishing the blog's UC2 comparison as-is on
  this stack.
- It does **not** prove the pull is worthless — latency is consistently
  better, and this is one workload shape at one scale on a 4-pod rig.
  Series-1's collapse was observed on a different engine build with a
  different harness; something real may have changed (the upstream fixes
  altered exactly this path), or the original may have been measuring a
  configuration that no longer exists.
- It **does** mean the UC2 numbers need re-derivation before they back a
  public claim, and that any re-derivation must be paired, counterbalanced,
  and report achieved throughput with its run-to-run spread.

### Two methodology traps found while running this

Both are silent — they produce plausible-looking numbers rather than errors —
and both would corrupt any A/B that hits them.

1. **Switching EPP arms by editing the ConfigMap does not switch the arm.**
   `helm upgrade` with only a `pluginsCustomConfig` change leaves the
   Deployment podspec untouched, so no rollout fires, and the EPP reads its
   plugin config once at startup. The first Arm B attempt ran with Arm A's
   config still loaded (verified: zero occurrences of `p2p-source-producer`
   in the running pod's log, pod creation timestamp predating the upgrade).
   It looked like "the pull mechanism is dead". **An explicit
   `kubectl rollout restart deploy/llm-d-router-epp` is required after every
   arm switch**, and the loaded config should be asserted before trusting a
   gate.
2. **A gate prefix already cached on every pod cannot demonstrate the pull.**
   Re-gating with the same prefix warms it everywhere; subsequent requests
   are local hits, so `load` stays 0 and `store` stops growing. This is
   indistinguishable from a broken mechanism by metrics alone. Gates must
   use a **fresh, never-served prefix each time**
   ([configs/uc2-ab-load-vs-loadp2p/gate_fresh.py](configs/uc2-ab-load-vs-loadp2p/gate_fresh.py)).
   The tell that distinguishes the two cases: a frozen `store` counter means
   "everything is already cached", a growing one means "computing locally
   instead of pulling".

Raw per-stage output for all four ladders:
[ab_armA_run1.log](configs/uc2-ab-load-vs-loadp2p/ab_armA_run1.log),
[ab_armB_run1.log](configs/uc2-ab-load-vs-loadp2p/ab_armB_run1.log),
[ab_armB_run2.log](configs/uc2-ab-load-vs-loadp2p/ab_armB_run2.log),
[ab_armA_run2.log](configs/uc2-ab-load-vs-loadp2p/ab_armA_run2.log).

---

## Scenario C - P/D prefill placement (partial; 2 of 3 arms)

The guide lists Scenario C as "not yet run". This is a partial run: the rig,
topology and two arms are measured; **arm 3 (`load + P2P`) was not run**, and
it is the arm that actually exercises the pull. Treat the arm comparison
below as inconclusive on the feature.

### What was built

8 prefill (TP=1) + 8 decode (TP=1), gpt-oss-120b, H200, 16 GPUs, on the same
combined overlay as UC2 (#48021 merged + #49877 + #49850). Manifest and arm
configs: [configs/scenario-c-pd](configs/scenario-c-pd). Arms are the guide's
own shipped plugin sets (`epp-affinity.yaml`, `epp-affinity-p2p.yaml`,
`epp-load-p2p.yaml`) mapped onto the P/D `prefill` scheduling profile.

**P2P tier on prefill only; decode runs plain NixlConnector.** This matches
what the guide describes (the pull is driven by `--enable-p2p-pull` on the
decode sidecar, whose source is another *prefill* pod) and it structurally
avoids the cross-TP fingerprint failure: in the original P/D attempt both
roles carried the tier and reject/reconnect churn killed 7/8 prefill engines.
Result here: **zero fingerprint rejects, zero restarts** across every run.
That alone is a usable finding for the scenario.

### Topology deviation, and why

The guide's stated topology is 8 prefill (TP=1) + 2 decode (TP=4). Rebalanced
to 8+8 at TP=1 - identical GPU count - after the 2xTP=4 decode pool appeared
to bind. **That diagnosis was later shown wrong** and is recorded here because
the instrument matters: `vllm:num_requests_running` read 0 on every prefill
pod under load, which looked like an idle prefill fleet waiting on decode
intake. Counter deltas told the opposite story - prefill was processing
**271K tok/s across 8 pods (33.9K tok/s per pod)**, i.e. running flat out.
The system is **prefill-compute-bound**; decode's growing `deferred` count is
a symptom of requests queued awaiting KV, not the cause. Lesson:
`num_requests_running` is unreliable for attributing a bottleneck on this
stack; use counter deltas.

### Measured (rates 1-4 req/s; 128 prefixes x 48K, 256-token questions, 64-token outputs)

Fleet ceiling is ~2.1 req/s for this workload, so the ladder was retargeted
from 4-24 to 1-4; at 8 req/s the rig sheds requests to the client timeout.
Each arm: fresh cold prefill pods, warmup over all 128 prefixes under that
arm's own placement policy, config assertion before load.

| rate | arm1 `affinity` achieved / TTFT p50 | arm2 `affinity + P2P` achieved / TTFT p50 |
|---:|---|---|
| 1 | 0.90 / 4.8s | 0.93 / 4.6s |
| 2 | 1.72 / 7.1s | 1.84 / 4.7s |
| 3 | 2.11 / 12.6s | 2.21 / 15.3s |
| 4 | 2.08 / 47.1s | 2.08 / 40.9s |

600/600 requests per arm, zero failures, zero restarts in both.

### The arm2 result does not measure the pull

**arm2's P2P pull was inert: zero P2P session activity** (`LookupMsg` /
`FetchMsg` / `TransferDone`) in any prefill pod's logs, despite the EPP being
verified to have loaded `p2p-source-producer`. With affinity holding an 80.2%
GPU prefix-cache hit rate, placement almost never diverges from the cache
holder, so `minCachedTokenDelta` is rarely met and the pull has nothing to
do. This reproduces the guide's own Scenario A observation that under
affinity "the pull mostly sits idle here (placement rarely diverges from
cache)". The arm1/arm2 deltas above are therefore **not** a P2P effect and
should not be read as one.

Arm 3 (`load + P2P`), which deliberately scatters placement and is the
configuration under which the pull actually fires, remains unrun. Until it
is, Scenario C has no verdict on prefill-placement P2P.

### Metric caveat that also affects UC3/UC4 above

`vllm:kv_offload_load_bytes_total` counts **local CPU-tier restores**, not
only P2P pulls. Arm1 here carries no p2p producer and has zero P2P session
activity, yet reports 23.30 GB of `kv_offload_load_bytes_total`; arm2 reports
26.72 GB with the pull equally inert. The same is true of
`external_prefix_cache_hits` (arm1: 762,112 hits with no P2P at all) - so
"external" means "outside GPU cache", i.e. the offload tier, local included.

Consequently the UC3 and UC4 sections above **overstate their mechanism
evidence**: both cite load/store byte counters as proof of "genuine cross-pod
pull activity", which those counters cannot establish on their own. Those
claims should be read as "offload-tier activity occurred; P2P was not
isolated". The UC2 A/B mechanism gate is unaffected - it was a controlled
comparison (identical config, arm A at load=0 vs arm B at 2.2 GB on
non-owner pods, p2p producer the only difference), which is what makes it
evidence. The reliable single-arm signal is P2P session log activity.
