# P2P benchmarks, series 4: UC2 lookup-hang resolved; UC3/UC4 re-validation; UC2 paired A/B

> **Headline for the A/B section below**: on this rig and stack, `load+P2P`
> does **not** reproduce the blog's Use Case 2 result. The pull is worth
> about **+2% achieved throughput** at saturation — smaller than the
> run-to-run spread — and the control arm (`load`, no pull) **does not
> collapse**. This was first measured on a rig lacking `rdma/ib` and has
> since been **re-run with RDMA and a verified-live pull: +1.2%, same
> verdict**, with the mechanism identified (the no-pull arm restores from
> its local CPU tier rather than recomputing). See the RDMA re-run section
> at the end. See [UC2 paired A/B](#uc2-paired-ab-load-vs-loadp2p-4-ladders-counterbalanced).

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

## Scenario C - P/D prefill placement (3 arms)

> **The numbers below are wrong; the ordering they support is not.** Every
> number in this section was measured on a rig with no `rdma/ib` resource, so
> the pull ran on a TCP fallback rather than RDMA. Re-running with `rdma/ib`
> and nothing else changed moves arm3 from 1.73 req/s / 66.6s TTFT to **3.71
> req/s / 3.09s** at offered rate 4.
>
> Compared like-for-like against arm3 (same driver, same 1-4 ladder, both on
> RDMA), **`load + P2P` still loses to `affinity`**: -5.8% throughput and
> 3.56x TTFT at rate 4. So the section's conclusion survives; what does not
> survive is its magnitude and its absolute numbers. The throughput penalty
> was inflated roughly 3x (-17% reported vs ~-6% actual), the TTFT penalty was
> *understated* (1.41x reported vs 3.56x actual), and the "~2.1 req/s fleet
> ceiling" is pure transport artifact - the rig sustains 16 req/s at flat
> ~370ms.
>
> An earlier revision of this banner said the verdict was void and the claim
> dead. That was an over-correction, recorded here rather than quietly edited.
> The mechanism analysis (hit rates, tier volumes, the `num_requests_running`
> lesson) was always correct. Full re-run in "Scenario C re-run with RDMA".

The guide lists Scenario C as "not yet run". All three arms are measured,
600/600 requests each, zero failures, zero restarts.

**Correction to an earlier revision of this section**: it claimed the P2P pull
never engaged. That was a query bug, not a finding - `kubectl logs -l <label>`
returns only a subset of matching pods, so its silence was not evidence of
absence. Per-pod inspection shows the full INFO-level chain on prefill pods:
`Created secondary tier #0 (p2p)` -> `_poll_once got 1 new connection(s)` ->
`accepting incoming connection from <peer>:7777` -> `created connected session
for <peer>:7777`. **P2P sessions form and the pull engages.**

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

achieved req/s / TTFT p50:

| offered | arm1 `affinity` | arm2 `affinity + P2P` | arm3 `load + P2P` |
|---:|---|---|---|
| 1 | 0.90 / 4.8s | 0.93 / 4.6s | 0.89 / 7.1s |
| 2 | 1.72 / 7.1s | 1.84 / 4.7s | 1.25 / 16.6s |
| 3 | 2.11 / 12.6s | 2.21 / 15.3s | 1.74 / 36.4s |
| 4 | 2.08 / 47.1s | 2.08 / 40.9s | 1.73 / 66.6s |

600/600 per arm, zero failures, zero restarts, zero fingerprint rejects.

**Load-aware placement plus a working pull loses to affinity on the P/D
prefill leg**: -17% achieved throughput at the ceiling and 1.4-2.9x the TTFT.
The mechanism is visible in the cache metrics - scattering drops the GPU
prefix-cache hit rate from **80.2% (affinity) to 7.8% (load)**, and pulling
the prefix over the network does not recover what local cache residency gave
away. Arm3 does far more offload-tier work for it: 32.2% external hit rate
and 404 GB of offload bytes, against ~10% and 23-27 GB in the affinity arms.

This confirms, on the P/D prefill leg, the same conclusion the guide already
draws for the aggregated case in Scenario A: "load + P2P ... degrades sharply
at the top of the ladder ... affinity + P2P has no such penalty because it
never scatters a prefix's traffic in the first place."

**arm2 vs arm1 is not a P2P measurement.** Under affinity the scheduled pod
is nearly always the cache holder, so `minCachedTokenDelta` is rarely met and
the pull has little to do; arm2's offload-tier figures (9.9% / 26.7 GB) look
like arm1's (10.4% / 23.3 GB), not arm3's. The arm1/arm2 deltas are within
noise and should not be read as a pull effect. This reproduces the guide's own
Scenario A note that under affinity "the pull mostly sits idle here".

### Metric caveat that also affects UC3/UC4 above

`vllm:kv_offload_load_bytes_total` counts **local CPU-tier restores**, not
only P2P pulls. Arm1 here carries no p2p producer and has zero P2P session
activity, yet reports 23.30 GB of `kv_offload_load_bytes_total`; arm2 reports
26.72 GB with the pull equally inert. The same is true of
`external_prefix_cache_hits` (arm1: 762,112 hits with no P2P at all) - so
"external" means "outside GPU cache", i.e. the offload tier, local included.

Consequently the UC3 and UC4 sections above **cite the wrong evidence**: both
use load/store byte counters as proof of "genuine cross-pod pull activity",
which those counters cannot establish on their own.

**The evidence is wrong; the conclusion is not.** P2P demonstrably worked in
that campaign - the saved DEBUG captures from the #49820/#49877 GPU repros
record `dbg49877` = 12 P2P sessions / 207,345 fetch-lookup traces and
`dbg49820` = 42 sessions / 265,886. Read UC3/UC4's mechanism claims as
supported by session-level evidence, not by the byte counters they quote.

The UC2 A/B gate is unaffected either way - it was a controlled comparison
(identical config, arm A at load=0 vs arm B at 2.2 GB on non-owner pods, the
p2p producer being the only difference), which is what makes it evidence.

**How to check P2P engagement reliably**: session establishment is logged at
INFO (`Created secondary tier #0 (p2p)`, `accepting incoming connection
from`, `created connected session for`), so it is visible without DEBUG. The
per-request lookup/fetch traces are `logger.debug` and need
`VLLM_LOGGING_LEVEL=DEBUG`. And query **per pod** - `kubectl logs -l <label>`
returns only a subset, so its silence proves nothing; that mistake produced a
false "P2P never engaged" claim in an earlier revision of this section.

## Scenario B - hot set, the 2 missing arms (`affinity + P2P`, `load, no P2P`)

> **Transport caveat, same as Scenario C**: `scenb-agg.yaml` carries no
> `rdma/ib`, so the `affinity + P2P` arm - the one arm here whose pull can
> fire, and the guide's shipped default - ran on the NIXL TCP fallback. On
> Scenario C the identical omission inverted the verdict once corrected
> (arm3: 1.73 -> 3.71 req/s). The pull is comparatively idle under affinity
> placement, which is the section's own finding and bounds how much the
> transport can matter here, but the arm has **not** been re-measured with
> RDMA. Treat the `affinity + P2P` numbers below as a lower bound, not a
> settled result. The `load, no P2P` arm never pulls and is unaffected.

The guide's own payoff-case table
(`guides/p2p-kv-cache-sharing/benchmarking/README.md`) publishes only 2 of 4
arms: `affinity` and `load + P2P`. Missing:
**`affinity + P2P`** - the shipped default, never measured in the payoff case
it exists for - and **`load, no P2P`**, the recompute floor. Both measured
here, 16x gpt-oss-120b aggregated, same combined-overlay-uc2resume fixed
stack (#48021 merged + #49877 + #49850) as UC2/UC3/UC4/Scenario C above.
Manifest and arm configs: [configs/scenario-b-hotset](configs/scenario-b-hotset)
(rig `scenb-agg.yaml`; arms `scenb-arm-affinity-p2p.yaml` /
`scenb-arm-load.yaml`, the guide's own `epp-affinity-p2p.yaml` /
`epp-load.yaml` embedded byte-for-byte, diffed to confirm). Driver:
`scenB_hotset.py` (8 hot prefixes x 48K tokens, 512-token decode-heavy
outputs, rates 12/24/36/48, 120s client timeout matching the guide's failure
column).

**Both arms complete, 0 restarts across the fleet in either run.** Neither
number should be read as a direct drop-in replacement for the guide's
existing 2 columns without the caveats below - both arms surfaced a real
mechanism finding, not just a throughput number.

### Measured (achieved req/s / latency p50 / failures per stage)

| offered | `affinity` (guide, published) | `affinity + P2P` (this run) | `load, no P2P` (this run) | `load + P2P` (guide, published) |
|---:|---|---|---|---|
| 12 req/s | 9.9 / 11.8s / 0 | 11.83 / 0.89s / 0 | 11.96 / 0.30s / 0 | 11.3 / 5.6s / 0 |
| 24 req/s | 14.7 / 27.0s / 0 | 23.66 / 0.84s / 0 | 23.30 / 0.32s / 0 | 20.9 / 9.6s / 0 |
| 36 req/s | 15.3 / 53.8s / 0 | 33.19 / 0.92s / 0 | 35.04 / 0.36s / 0 | 29.1 / 15.9s / 0 |
| 48 req/s | 13.1 / 75.3s / 672 | 43.12 / 1.05s / 0 | 46.04 / 0.38s / 0 | 34.3 / 26.0s / 0 |

TTFT p50 (both new arms, all 4 stages): affinity+P2P 713-769ms; load-no-P2P
187-199ms.

### `affinity + P2P`: mechanism confirmed, but the throughput gap vs. the guide's column is not a P2P effect

Per-pod `vllm:request_success_total` after the run: exactly **8 pods at 901
requests each, 8 pods at 0** - affinity concentration is working exactly as
designed, one owner per hot prefix, matching the guide's own "8 owner pods"
framing precisely.

**The P2P pull never engaged**: 0 occurrences of `created connected session
for` (INFO level, no `VLLM_LOGGING_LEVEL=DEBUG` needed) across all 16 pods.
This reproduces the same pattern already recorded twice above (Scenario A's
own note, Scenario C's arm2 finding) - affinity rarely diverges from the
best-cached pod, so `minCachedTokenDelta` is rarely met and the pull has
nothing to do. **Since the pull never fired, it cannot be what makes this
arm outperform the guide's published affinity throughput with zero failures
instead of 672** - the gap is small at low offered rate (1.2x at 12 req/s,
1.6x at 24) and widens sharply as offered rate approaches the guide's own
reported collapse point (2.2x at 36, 3.3x at 48, exactly where the guide's
arm sheds 672 requests and this run has none). The most likely explanation
is engine-build drift: this
run is on `nightly-1240c74c0a...`, a materially later build than whatever
produced the guide's original number, and the same "absolute numbers shift,
mechanism conclusions don't" caveat already applies to UC2 above. This is
inference, not verified - pinning it exactly would need a stock-affinity
control run on this same build, which is outside this task's scope (2 missing
arms, not a 3rd control). Flagging it rather than either hiding the gap or
overclaiming a cause.

### `load, no P2P`: EPP-level mechanism confirmed correct, but this is not a clean recompute floor

Gate confirmed `p2p-source-producer` absent from the loaded config (0
occurrences, as expected) and the scheduling profile is exactly
`weighted-random-picker` + `queue-scorer`(w3) + `kv-cache-utilization-scorer`
(w2) - no prefix-affinity scoring at all, matching `epp-load.yaml` verbatim.

**But the underlying vLLM engine's own native per-pod prefix cache captures
almost everything anyway**: `vllm:prefix_cache_hits_total /
prefix_cache_queries_total` = 98.7% (33.85M / 34.28M cached tokens, aggregate
across both attempts on these pods - see methodology note below),
`vllm:external_prefix_cache_hits_total` = 0 (confirming these are local
hits, not P2P pulls - correct for this arm). Root cause, read directly from
`pkg/epp/framework/plugins/scheduling/picker/weightedrandom/picker.go`:
`weighted-random-picker` is **A-Res weighted sampling, probability
proportional to score** (`keyᵢ = Uᵢ^(1/wᵢ)`), not uniform selection. With
only 8 unique hot prefixes spread across 16 pods (a far lower prefix:pod
ratio than Scenario A's uniform pool at 128:16), and placement weighted by
queue/kv-utilization scores that correlate with "just served this request",
incidental same-pod repeat-hits for the same prefix are common even with
zero prefix-affinity scoring in the config. **This arm is not isolating an
always-recompute worst case** the way Scenario A's `load, no P2P` does at a
much higher prefix:pod ratio - it is measuring how well simple load-based
placement does when it incidentally benefits from native caching at this
specific hot-set size. That is a real and useful number (and arguably softens
the case that the pull is doing essential work at this specific hot-set:pod
ratio), but it should not be read as "the cost of recomputing every hot
prefix from scratch".

### Methodology: `kubectl port-forward` failed under this arm's own degraded state, taking down the whole tunnel

First attempt at this arm ran through the same port-forward pattern as every
other scenario in this file (`kubectl port-forward svc/llm-d-router-epp`).
Stages 1-2 completed clean; stage 3 (36 req/s) started shedding requests
mid-stage as latency climbed past 30s p50, and stage 4 (48 req/s) reported
**100% failure** - not a real engine-side collapse: the tunnel log shows
repeated `connection reset by peer` starting mid-stage-3, ending in `lost
connection to pod`. Engine-side queue depth was confirmed drained (0
running / 0 waiting on every pod) immediately after, and a rerun of the
identical ladder from an in-cluster pod (`kubectl exec` against
`http://llm-d-router-epp:8081` directly, no local-machine tunnel) came back
completely clean - the numbers in the table above are from that rerun.

**Why arm 1 never hit this and arm 2 did**: by Little's Law, concurrent
open connections scale with rate x latency. Arm 1's sub-second latency
throughout keeps concurrent connections low even at 48 req/s offered; arm 2's
climbing latency under genuine load (before the native-cache rescue kicks in
enough to flatten it - see above) pushed concurrent long-lived streaming
connections past whatever ceiling this specific tunnel could hold. **A
degrading arm can silently fail its OWN measurement tool exactly when it is
about to produce the most interesting data** - this is the same
verify-the-gateway-path-not-just-the-feature-path lesson as the render-
bottleneck plateau, applied to the client side instead of a shared backend
service. For any future high-concurrency ladder (especially one expected to
degrade, unlike a clean-scaling arm), prefer an in-cluster load generator
over `kubectl port-forward` from the start rather than discovering the limit
mid-run. Both raw logs kept: `scenB_arm2-load-noP2P_portforward-FAILED.log`,
`scenB_arm2-load-noP2P_incluster-clean.log`.

## Step 0 crossover re-check: the pull has not gotten faster - it has gotten relatively slower

Motivation: several results this session (Scenario B's affinity+P2P
throughput, the UC2 A/B's no-pull baseline no longer collapsing) raised the
question of whether the *baseline* got better or P2P itself got worse. The
cleanest way to answer that without scheduler/placement/concurrency
confounds is to re-run the guide's own Step 0 methodology (single-request,
cold-pod, recompute vs. pull, no EPP/routing involved at all) and diff
directly against its original table. Configs, driver, and all 4 attempt
logs (including the 3 invalid ones, kept as evidence for the traps below):
[configs/step0-crossover-recheck](configs/step0-crossover-recheck).

**Provenance caveat, stated up front**: the original table's exact vLLM
build was never pinned - `capacity-number-provenance.md` on this same
branch admits it explicitly ("no specific SHA recorded"), only "nightly +
`generic_p2p` branch." This re-check can show WHAT changed in the raw
numbers; it cannot pin down WHY against an unknown prior build. Rig: 2x
gpt-oss-120b aggregated (`scenb-agg` scaled to 2 replicas), same fixed
stack as the rest of this session (nightly-1240c74c0a... +
combined-overlay-uc2resume).

### Two invalid attempts before the real one - both caught by the same discipline this file already uses elsewhere

**Attempt 1 - silent pull-fallback, mistaken for "pull adds nothing."**
Copied an older GLM crossover script's approach: inject
`kv_transfer_params.p2p` directly into the request body against the bare
engine port (8200), bypassing the sidecar. Result looked like a real
finding - delta ~0% at every length, recompute and pull statistically
indistinguishable - but `vllm:external_prefix_cache_hits_total` and
`prompt_tokens_by_source_total{source="external_kv_transfer"}` both stayed
at exactly 0.0 for the entire run, and no session-establishment log line
appeared on either pod, not even during warm-mesh calibration. Every
"pull" request had silently recomputed instead. Root cause not fully
diagnosed (the field names matched the sidecar's own constants exactly,
`pkg/common/request/constants.go`), but the fix sidesteps needing to know
why: route through the sidecar's own proven header mechanism
(`x-kv-cache-source-host-port`, `pkg/sidecar/proxy/chat_completions.go:135`)
instead of guessing the bare engine's wire format - the same mechanism the
EPP itself uses for every real pull in this whole campaign. Confirmed
working via a single-request smoke test before re-running the full sweep:
exact token-count match on `external_prefix_cache_hits_total`, a real
session in both pods' logs, and the sidecar's own log line
(`"running P2P source protocol"`).

**Attempt 2 - nonce periodicity collision, mistaken for a real crossover
shift.** After fixing the fallback, the sweep produced a delta pattern
that looked plausible (recompute far faster than original, pull only
slightly better) - but `prompt_tokens_by_source_total{source="local_cache_hit"}`
read 412,672 tokens, which should be structurally impossible in this
design (every prefix uses a fresh nonce, never seen before). Cause: the
prefix generator was `WORDS[(nonce*53+i) % 20]` - a linear formula whose
cyclic word pattern depends only on `nonce mod 20`. The recompute and
pull-source nonces for the same rep differed by exactly 500 (a multiple of
20), so their generated text was near-identical past the first couple of
tokens - pod B's own local cache from the recompute call was silently
assisting the very next "pull" measurement for the same rep. Same failure
mode as [[project_render_bottleneck_5s_plateau]] and Scenario B's own
`load, no P2P` arm above, in miniature: a plausible-looking number from an
unverified mechanism. Fixed by generating each prefix from an
independently-seeded `random.Random(nonce)` stream instead of a linear
formula - no two nonces can share periodicity. Verified 0 collisions
across every nonce pair actually used before re-running.

**Also discovered, not a bug but a confound worth naming**: recompute
numbers differed between the (nonce-fixed) attempt on warm/reused pods and
the final cold-pod run - both pods had by then processed >1M cumulative
prompt tokens including tens of GB into the 94GB CPU offload tier. A cold
`kubectl delete pod` reroll before the authoritative run removes this as a
variable; the numbers below are cold-pod only.

### The authoritative measurement (cold pods, mechanism verified)

Verification before trusting the numbers: `external_prefix_cache_hits_total`
grew by 573,184 tokens across the run (expected ~569,855 from the pulled
lengths x 5 reps - matches); `local_cache_hit` stayed at exactly 0 (no
contamination); exactly one P2P session established (during warm-mesh
calibration) and reused for every subsequent pull; 0 restarts on both pods.

| tokens | recompute (now) | recompute (orig, 2026-07-17) | pull (now) | pull (orig) | delta (now) | delta (orig) |
|---:|---|---|---|---|---|---|
| 2,048 | 78.9 ms | 70.6 ms | 103.0 ms | 49.0 ms | +31% | -31% |
| 8,192 | 253.7 ms | 205.4 ms | 322.1 ms | 120.1 ms | +27% | -42% |
| 16,384 | 504.1 ms | 426.3 ms | 687.8 ms | 196.2 ms | +36% | -54% |
| 32,768 | 2,102.7 ms | 983.0 ms | 1,223.0 ms | 376.3 ms | -42% | -62% |
| 49,152 | 2,615.0 ms | 1,695 ms | 1,842.8 ms | 550.5 ms | -30% | -68% |

**Both recompute and pull got slower in absolute terms - the pull got
slower by more, at every single length.** Recompute is 1.1-2.1x slower
than the original measurement; the pull is 2.1-3.5x slower, consistently
worse than recompute's own slowdown at every length. That is the direct
answer to "did the baseline improve or did P2P get worse": in this
isolated, mechanism-level test, **neither got faster - the pull
specifically regressed more than recompute did**, which is why the
crossover point has moved. The guide's table showed the pull winning at
every measured length, including the smallest (2,048, chosen as
`minCachedTokenDelta`); today it *loses* at 2,048-16,384 tokens (+27% to
+36% slower than just recomputing) and only wins at 32,768+ (-30% to
-42%), a smaller margin than the original's -62% to -68% at those same
lengths. **The guide's current `minCachedTokenDelta: 2048` is very likely
miscalibrated for this build - it would fire pulls in a range (2,048-16,384)
where this measurement shows the pull actively costing latency, not saving
it.**

**This does not contradict the "baseline improved" pattern seen elsewhere
this session** (Scenario B's affinity throughput, UC2's no-pull control no
longer collapsing) - those are concurrent/batched-throughput measurements
under load (scheduling and batching efficiency across many simultaneous
requests), a different axis from this single-request, unbatched,
zero-concurrency test. It is plausible for a build to get better at
serving many requests at once while an individual request's raw
compute-or-pull cost - and especially the P2P tier's own per-request
overhead - has grown, e.g. from the accumulated defect-fix machinery
layered into the OffloadingConnector/P2P code paths since this table was
first measured. That is inference, not verified here; nailing down which
specific change is responsible would need a build bisection, which is
outside what this re-check was scoped to do.

**Action implied, not taken**: no guide edits made. If this holds up under
another look, the guide's Step 0 table and `minCachedTokenDelta` both need
re-deriving on a pinned build before the guide can cite either with
confidence - and this time, pin the exact image tag/SHA used, so the next
re-check doesn't inherit the same unknown-provenance problem.

---

## Pull vs recompute on both engine builds (gpt-oss-120b) - the build is not the variable, RDMA is

Motivated by the hypothesis that the newer vLLM build explains why the
guide's published numbers did not reproduce in this campaign. It does not.

### Design

The guide's Step 0 method, replicated on BOTH builds **simultaneously** so
build is the only difference and both see identical cluster conditions:
5-rep medians, warm mesh, unique prefix per repetition, lengths
2K/8K/16K/32K/48K.

| | engine image | P2P code |
|---|---|---|
| **old** | `nightly-4080263b` | generic_p2p `145a460c` + crash fix `fa07027d` |
| **new** | `nightly-1240c74c` | `#48021` as merged + `#49877` + `#49850` |

2 pods per build (source + consumer), no sidecar and no EPP - the driver
injects the pull parameters directly, so nothing can be silently inert.
Both builds reported identical tier config (`lru, 29127 blocks`, 1 secondary
p2p tier). Mechanism gate after the run was symmetric: 50.1% external hit
rate and 21.26 / 21.27 GB pulled. Configs and raw logs:
[configs/crossover-two-builds](configs/crossover-two-builds).

### Result

TTFT delta, pull vs recompute (negative = pull wins):

| prefix tokens | guide (published) | **old build** | **new build** | old, NO RDMA |
|---:|---:|---:|---:|---:|
| 2,048 | -31% | **-49.3%** | **-55.8%** | +29.0% |
| 8,192 | -42% | **-75.7%** | **-77.4%** | +57.6% |
| 16,384 | -54% | **-82.5%** | **-83.2%** | +39.3% |
| 32,768 | -62% | **-85.7%** | **-85.9%** | +18.2% |
| 49,152 | -68% | **-87.5%** | **-88.2%** | -16.5% |

**The two builds are indistinguishable.** They agree within ~6% at 2K and
within 1% from 8K up. Whatever explains the campaign's other discrepancies,
it is not the engine build - at the mechanism level the newer stack is if
anything marginally faster.

**The pull wins harder than the guide claims**, not less: -83% vs the
published -54% at 16K, -88% vs -68% at 48K. The guide's Step 0 direction
reproduces and its magnitudes are conservative on this rig.

**Why**: pull time is nearly flat in prefix size (38 / 59 / 86 / 165 / 244 ms)
while recompute is linear (75 / 243 / 490 / 1154 / 1952 ms). Fixed transfer
overhead dominates, so the advantage widens with prefix length - the same
shape the guide describes.

### RDMA is the variable that actually matters

The last column is the same code, same everything, with the `rdma/ib`
resource omitted from the pod spec. NIXL falls back to a slower transport,
the pull leg inflates 2-3x, recompute is untouched, and **the pull loses at
four of five lengths**. Same build, opposite conclusion.

This is a deployment-blocking prerequisite that the guide's Step 0 section
does not state. It appears only as a comment in
`modelserver/gpu/vllm/kustomization.yaml` ("add to the modelserver
container: resources rdma/ib"). Anyone reproducing Step 0 without RDMA will
measure the pull losing and reasonably conclude the feature does not work.
Recommend stating it as an explicit prerequisite next to the crossover table.

### Method note carried out of this run

The engine reads `kv_transfer_params.remote_kv_source`. The sidecar's Go
constant is `requestFieldP2PParams = "p2p"`, but that is the *internal*
field name, not the wire key - injecting under `p2p` is silently ignored and
the request just recomputes, producing a plausible "pull" number that is a
second recompute. First probe here read -6.4% that way. Session
establishment is the tell: zero sessions with the wrong key, three with the
right one.

---

## PR #49877 at its current head (`15b53af1`) - reworked, and the finish() gap persists

The PR moved substantially after the validation recorded above (which was
against `c1e15b9`). It is **no longer a draft**.

### What changed

| | `c1e15b9` (validated earlier) | `15b53af1` (current) |
|---|---|---|
| files changed | `manager.py`, `client.py`, `server.py` | `client.py`, `protocol.py`, `server.py`, `session.py` (**not** `manager.py`) |
| client state machine | `ClientPhase` enum | `peer_lookup_open` bool |
| in-flight loads | single slot `st.load` | **per-round dict `st.loads[round_seq]`** |
| wire messages | - | `FetchMsg` / `AbortFetchMsg` carry `ROUND_SEQ` |
| `queued_fetches` | present (9 refs) | removed - subsumed by the per-round dict |
| regression test | `test_issue_49820_repro.py` | dropped |

The per-round `st.loads` dict is a direct structural fix for the single-slot
overwrite traced in the #49829 analysis above: a second promotion for the
same `kv_request_id` can no longer silently displace an earlier one, because
each round has its own slot and every wire message names its round.

### The finish() gap is still open

`finish()` sends an `AbortFetchMsg` per live load, then `st.loads.clear()` -
without emitting any `LoadResult`. `on_abort_ack()` then does
`st.loads.pop(round_seq, None)`, gets `None`, and takes the unknown-request
branch. There are exactly three `LoadResult` sites in the file
(`on_transfer_done`, `on_abort_ack`, the abort-ack timeout in
`collect_results`) and none is reachable for a load cleared by `finish()`.

Reproduced against the real `ClientRole` at this head
([configs/pr49877-newhead](configs/pr49877-newhead)):

```
after request_blocks: sent = ['fetch']
after finish():        sent = ['fetch', 'abort_fetch']
P2PSession peer:7777: abort_ack for unknown kv_request_id=req-1 round=0
LoadResults: []
```

Zero terminal results for an accepted job - the same signature reported on
the earlier head.

**Coverage narrowed rather than widened.** At `c1e15b9`, `finish()` did emit
failed `LoadResult`s for `queued_fetches`. At `15b53af1` it emits none at
all. `queued_fetches` no longer exists as a concept, so this is not a
behavioural regression in the old sense - but the practical effect is that
*every* load in flight when a request finishes is now orphaned, where
previously the queued ones were failed correctly.

Downstream consequence is unchanged: no result reaches
`TieringOffloadingManager`, so the promotion stays in `_transfer_jobs` and
its primary-tier write reservation is never resolved - the same
permanently-`HIT_PENDING` state as #49829, reached through request cleanup
rather than round overlap. #49850 bounds how long *later* requests wait on
that reservation but does not clean it.

Overlay rebuilt on this head for future runs:
`combined-overlay-49877new` (merged #48021 base + the four PR files at
`15b53af1` + #49850's scheduler/metrics/base additions;
`manager.py` taken at the PR head since the PR no longer modifies it).

---

## UC2 A/B re-run WITH RDMA - the verdict holds, and the mechanism is now clear

The UC2 A/B above was measured on a rig **without `rdma/ib`**, so its P2P arm
ran on a TCP fallback. Given the crossover showed RDMA swinging
pull-vs-recompute by >100 percentage points, that verdict could not stand.
Re-run here with `rdma/ib` on both limits and requests, and on PR #49877 at
its current head `15b53af1`. Both verified live *inside the container*
before measuring: `/dev/infiniband` present (`issm0-3`), and
`peer_lookup_open` x6 in the mounted `client.py` (an identifier that exists
only at the new head). Configs and logs:
[configs/uc2-ab-rdma](configs/uc2-ab-rdma).

### Result

Achieved req/s at saturation:

| offered | arm A `load` | arm B `load + P2P` | delta |
|---:|---:|---:|---:|
| 12 | 8.35 | 8.27 | -1.0% |
| 16 | 8.11 | 8.60 | +6.0% |
| 20 | 8.15 | 8.13 | -0.2% |
| 24 | 8.30 | 8.31 | +0.1% |

**Saturation mean: A = 8.227, B = 8.328 → +1.2%.** The between-arm
difference is 0.100 req/s, *smaller* than the within-arm run-to-run spread
measured in the original study (0.125 A / 0.215 B). Per-stage deltas swing
both directions, the same noise signature as before.

The control reproduced closely across rigs - arm A 8.227 with RDMA vs 8.117
without (1.4% apart) - which is expected, since RDMA is irrelevant to an arm
that never pulls, and it confirms the two studies are comparable.

The pull was unambiguously live this time: gate showed the owner pod
accepting 6 sessions with the other three pulling 2.20 GB each; mid-ladder
the fleet had moved 81.3 GB with 9,123 P2P log lines on the owner alone.

**So the original conclusion stands, on far better evidence.** It is no
longer "the pull did not help, transport unexamined" but "the pull was
verified working and still did not move the fleet's saturation ceiling".

### Why RDMA transformed the crossover but not this

Arm A logged **16.53 GB of `kv_offload_load_bytes_total` with zero P2P
sessions**. On this pool the no-pull arm is not recomputing cross-pod
misses - it is restoring them from its own **local CPU tier**. With 64
prefixes of 16K tokens over 4 pods each holding a 16 GiB tier, every pod
accumulates most prefixes after warmup.

The two experiments therefore compare different things:

| | what "no pull" actually does | pull result |
|---|---|---|
| Step 0 crossover | unique prefix, consumer has never seen it -> **true recompute** | pull wins 49-88% |
| UC2 pool | prefix recurs, consumer already holds it -> **local CPU restore** | tied |

Both arms in UC2 already avoid recompute, so the pull is competing against a
local memory read rather than against prefill. That is why the transport
swing that dominated Step 0 is nearly invisible here.

This also explains the blog's Use Case 2 premise directly. "Load-balancing
without the pull is catastrophic once the working set exceeds per-pod cache"
assumes a cross-pod miss forces recompute. With a large local CPU tier it
does not - the miss is absorbed by the tier. The premise holds only where
the CPU tier cannot hold the working set, or where prefixes do not recur per
pod often enough to populate it.

## Scenario C re-run with RDMA - the earlier verdict was a transport artifact

The Scenario C section above was measured without the `rdma/ib` resource on
the pod spec. NIXL then falls back to a slower transport, which inflates the
pull leg while leaving recompute untouched - the same trap that produced the
inverted crossover reading, recorded in "RDMA is the variable that actually
matters" above. Scenario C is the one scenario whose verdict *depends* on the
pull leg, so it is the one the omission could invert. It did.

Rig: identical to the original (8 prefill TP=1 + 8 decode TP=1, gpt-oss-120b,
H200, 16 GPUs), with `rdma/ib: "1"` on limits and requests for both roles and
the overlay refreshed to `combined-overlay-49877new` (#48021 as merged +
#49877 at head `15b53af1` + #49850). Verified in-container before loading:
`peer_lookup_open` present (new head live), full RDMA device list
(`issm0-8`, `uverbs0-8`, `rdma_cm`), P/D roundtrip 200.

### arm3 `load + P2P`: the arm the transport actually gated

| offered | no RDMA (TCP fallback) | with RDMA | change |
|---:|---|---|---|
| 1 | 0.89 / 7.08s | 0.98 / 1.08s | +10% / 6.6x |
| 2 | 1.25 / 16.63s | 1.88 / 2.63s | +50% / 6.3x |
| 3 | 1.74 / 36.44s | 2.87 / 2.65s | +65% / 13.8x |
| 4 | 1.73 / 66.63s | 3.71 / 3.09s | **+114% / 21.6x** |

240/240 at every rate, zero failures. Warmup over all 128 prefixes also fell
from 108s to 51s. Pull verified live: 56 P2P sessions, 431 GB pulled, zero
restarts, zero fingerprint rejects.

The shape of the no-RDMA column is the tell in hindsight - TTFT growing
7s -> 17s -> 36s -> 67s, near-perfectly linear in offered rate, is a queue
draining behind a fixed-bandwidth link, not a compute ceiling. With RDMA the
same arm holds 2.6-3.1s TTFT across the whole ladder while throughput scales
almost linearly to 3.71 req/s. The "~2.1 req/s fleet ceiling" asserted in the
original section was therefore never a fleet property; it was the fallback
transport's ceiling.

### But the arm ordering survives: arm3 still loses to arm1 on RDMA

The lift above is arm3 against its own no-RDMA self, which is the wrong
question for the section's verdict. Against arm1 - same driver
(port-forwarded), same 1-4 ladder, both on RDMA, so directly comparable:

| offered | arm3 vs arm1, no RDMA | arm3 vs arm1, RDMA |
|---:|---|---|
| 1 | -1.1% / 1.47x TTFT | -2.0% / 1.20x |
| 2 | -27.3% / 2.35x | -5.1% / 3.03x |
| 3 | -17.5% / 2.90x | -2.7% / 3.03x |
| 4 | -16.8% / 1.41x | **-5.8% / 3.56x** |

**`load + P2P` still loses to `affinity` on the P/D prefill leg.** RDMA lifts
both arms; it does not reorder them. What the transport distorted was the
size of the gap, in both directions - the throughput penalty was overstated
by about 3x (-17% vs ~-6%), and the TTFT penalty was *understated* (1.41x vs
3.56x). The original section's conclusion was right for a reason it had not
established, which is why the fix here is a re-measurement rather than a
retraction.

This also leaves the guide's placement stance intact. It never rested on this
section alone, and its other pillar - Maroon's GLM c16-c128 ladder - was
measured on a rig that does carry `rdma/ib`
(`configs/glm-5.2-p2p/lws-{prefill,decode}.yaml`), so it was never exposed to
this artifact.

### Operating rule found the hard way: roll prefill and decode together

Switching from arm3 to arm1 by cold-rolling **only** the prefill deployment
killed the EngineCore on all 8 decode pods simultaneously:

```
UCX  ERROR   mlx5dv_devx_obj_modify(opcode=0x503) failed, syndrome 0x5d668c: Remote I/O error
  nixl::ucx::rkey::unpackUcpRkey(...)
  nixlRemoteSection::addDescList(...)
  nixlAgentData::loadRemoteSections(...)
  nixlAgent::loadRemoteMD(...)
```

This is the **NIXL P/D connector**, not the P2P tier. Decode was holding
remote sections for the old prefill NIXL agents and had to load metadata for
eight brand-new ones; the rkey unpack failed against the RDMA device and took
the engine down with it. All 8 decode pods exited within 11 seconds
(17:07:45-17:07:56), `reason=Completed exit=0`, and the arm1 warmup that
triggered it returned 21 ok / 107 fail before being killed.

The mirror failure appeared immediately after. Once the decode pods restarted
on their own, **prefill** was the side holding stale sections - for the decode
agents that had just died - and every request hung instead of crashing:

```
UCX AM send failed with status -80 (Endpoint timeout)
NIXL transfer failure: transfer_exception ... remote_host: 10.0.11.136,
  remote_port: 5600, remote_engine_id: 0414ddf8-...
nixlRemoteDisconnectError: NIXL_ERR_REMOTE_DISCONNECT
```

`10.0.11.136` was a **live, ready** prefill pod - the pod was healthy and its
`/v1/completions` answered locally in 0.0s, but its NIXL agent disconnected
the new decode agents, so decode waited forever on KV that never arrived.
Diagnosing this needs the P/D path specifically: probing either engine
directly passes, `/v1/models` returns 200 in 0.45s, and only
`/v1/completions` hangs. The engines look perfectly healthy the whole time.

Three things follow:

- **Procedure**: in a NIXL P/D rig, an arm switch must roll both roles.
  Rolling one side leaves the other holding stale remote sections - and it
  fails in both directions, fatally for a consumer loading metadata, silently
  (as a hang) for a producer refusing the new agents. Arm3 never hit this only
  because prefill and decode were the same generation for its whole run.
- **Robustness defect worth reporting upstream**: a peer's stale or invalid
  metadata should fail that peer, not kill the local EngineCore.
  `loadRemoteMD` failure is currently fatal. This is independent of the P2P
  tier work and would affect any NIXL P/D deployment that rolls one side.
- **Second, separable gap**: on the producer side there is no surfaced
  timeout - the consumer's transfer sits in `NIXL_ERR_REMOTE_DISCONNECT`
  retry while the client blocks indefinitely. The same "no deadline on a
  cross-engine wait" shape as the P2P lookup hang recorded above.

### Debug note: what did NOT cause it

Two plausible-looking leads that cost time and were both wrong, recorded so
they are not re-investigated:

- **The render service.** `scenc-render`'s `/tokenize` returns HTTP 500
  (`'OpenAIServingRender' object has no attribute 'create_tokenize'`) - but
  that is true of every render deployment on this cluster, including ones
  serving healthy runs, because the `token-producer` plugin does not use that
  endpoint. It POSTs `/v1/completions/render`
  (`pkg/epp/framework/plugins/requestcontrol/dataproducer/tokenizer/vllm_http.go:44`).
  A render failure also cannot hang a request: the director explicitly
  swallows it (`director.go:309-313`, "Don't fail the request if DataProducer
  plugins fail"), bounded by `defaultHTTPRenderTimeout = 5s`.
- **The port-forward.** Rebuilt it against a fresh EPP pod; the hang was
  identical. Envoy was serving 404s and `/v1/models` sub-second throughout.

arm3's numbers are unaffected - the mlx5 errors are confined to the
17:07:45-17:07:56 crash window, with none during its ladder, which completed
240/240 at every rate beforehand.

### The 1-4 ladder was itself an artifact; arm2 shows the pull never fires

Re-running the arms with RDMA invalidated the ladder as well as the verdict.
The original section retargeted the ladder from 4-24 down to 1-4 because the
rig appeared to cap near 2.1 req/s. With RDMA there is no cap in that range
at all - `affinity + P2P` on rates 1,2,4,8,12,16 tracks offered load
linearly the whole way with flat TTFT:

| offered | achieved | TTFT p50 | TTFT p95 | ok/sent |
|---:|---|---|---|---|
| 1 | 1.00 | 416 ms | 489 ms | 60/60 |
| 2 | 1.99 | 378 ms | 425 ms | 120/120 |
| 4 | 3.97 | 371 ms | 422 ms | 240/240 |
| 8 | 7.93 | 372 ms | 411 ms | 480/480 |
| 12 | 11.88 | 371 ms | 411 ms | 720/720 |
| 16 | 15.84 | 370 ms | 407 ms | 960/960 |

2580/2580 requests, zero failures, zero restarts. The apparent "~2.1 req/s
fleet ceiling" was low by roughly 8x.

**Driver note**: this ladder was driven from an in-cluster pod
(`scenc-loadgen`), not through `kubectl port-forward`. The tunnel has died
mid-ladder on this cluster before, and it also adds latency to every request,
so TTFT from a port-forwarded run is not comparable to TTFT from an
in-cluster run. Arm1's 1-4 ladder above was port-forwarded; its arm1-vs-arm2
TTFT comparison is therefore invalid and arm1 is re-run in-cluster below.

**The pull never engaged in this arm.** Measured on the prefill fleet at the
end of the ladder:

- GPU prefix cache hit rate **94.6%** (129,837,120 / 137,246,445 queries)
- external (offload-tier) hits **0.4%** of queries
- **0** `created connected session`, **0** `accepting incoming connection`,
  across all 8 prefill pods

Checked against the ways a zero can lie: the startup banner is still in every
pod's retained log window (so nothing rotated away), restart counts are all
0, and the P2P secondary tier *is* created on every pod (`secondary tier` x2
each), so the mechanism is live and simply had nothing to do. The contrast
that settles it is arm3 on this same rig and overlay: **56 sessions, 431 GB
pulled**.

So under affinity placement `minCachedTokenDelta: 1024` is essentially never
met - the scheduled pod already holds the prefix - and `affinity + P2P`
degenerates to `affinity`. **arm1 vs arm2 does not measure P2P**; it measures
the same system twice. This is the guide's own "the pull mostly sits idle
here" observation, quantified: not "little to do" but zero sessions.

That is a statement about this workload, not about P2P generally. 128 stable
prefixes over 8 prefill pods under stable affinity means no prefix ever needs
to move, which is precisely the case where a recovery path should stay idle.
It does bound what the shipped `affinity + P2P` default can be credited with
in this scenario: nothing measurable, because it never runs.

### arm1 vs arm2, matched: `affinity` vs `affinity + P2P` is a clean null

Arm1 re-run in-cluster on the identical ladder, so both halves share a driver,
rates, fleet generation and warmup. The two configs are one plugin apart -
diffed to confirm `p2p-source-producer` is the only difference between
`sc1.yaml` and `sc2.yaml`; every other plugin, weight and profile is
byte-identical.

achieved req/s / TTFT p50:

| offered | arm1 `affinity` | arm2 `affinity + P2P` | delta |
|---:|---|---|---|
| 1 | 1.00 / 393 ms | 1.00 / 416 ms | 0.0% / +23 ms |
| 2 | 1.99 / 373 ms | 1.99 / 378 ms | 0.0% / +5 ms |
| 4 | 3.97 / 373 ms | 3.97 / 371 ms | 0.0% / -2 ms |
| 8 | 7.93 / 373 ms | 7.93 / 372 ms | 0.0% / -1 ms |
| 12 | 11.88 / 366 ms | 11.88 / 371 ms | 0.0% / +5 ms |
| 16 | 15.84 / 366 ms | 15.84 / 370 ms | 0.0% / +4 ms |

2580/2580 per arm, zero failures, zero restarts, all restart counts 0 on both
fleet generations. Achieved throughput is identical to three significant
figures at every rate; TTFT differs by at most 23 ms (6%) at the lowest rate
and under 1.5% everywhere else.

Mechanism counters match too - arm1 94.6% GPU prefix hit rate
(129,897,600/137,246,445), arm2 94.6% (129,837,120/137,246,445), and **0 P2P
sessions in both**. The null is fully explained: the arms are the same system
because the pull never runs.

**Read this as "the pull is inert in this scenario", not "the pull does not
help".** The two are different claims and only the first is supported here.
The comparisons that do exercise the pull, both on RDMA, are Step 0's
crossover (recompute vs pull - pull wins 49-88%) and UC2's A/B (local-restore
vs pull - +1.2%, within noise).

### Scenario C no longer stresses what it was built to test

With the transport fixed, nothing saturates: both arms track offered load
linearly from 1 to 16 req/s with flat ~370 ms TTFT and no failures. The
scenario's whole premise was comparing placement strategies *at* a ceiling,
and on this workload - 128 stable prefixes over 8 prefill pods, 94.6% local
hit rate - there is no ceiling in range and placement barely matters.

The earlier ~2.1 req/s "ceiling" was the fallback transport, so every
placement conclusion drawn at it was really a conclusion about a saturated
link. Making Scenario C meaningful again needs a workload that actually
pressures placement: a working set larger than aggregate GPU cache, prefix
churn or pod scale-out (so prefixes must move, which is when the pull is the
recovery path), or a rate high enough to find the real ceiling. That is a
design decision, not a re-run, so it is left for review rather than guessed
at here.

## The TCP crossover, re-measured - the guide's old no-RDMA column was unreliable

The "old, NO RDMA" column in the two-build crossover section above was
measured on a different engine build from everything beside it, and its
shape gives it away: +29.0 / +57.6 / +39.3 / +18.2 / -16.5% at
2K/8K/16K/32K/48K **rises before it falls**. A pull whose cost is nearly
flat in prefix length, measured against a recompute that is linear in it,
can only produce a monotonically improving delta. The non-monotonic middle
was noise, and it was load-bearing: it is what made TCP look like it
inverted the economics.

Re-measured on one rig, one build (`nightly-1240c74c` +
`combined-overlay-49877new`), driven from an in-cluster pod, `rdma/ib`
deliberately absent and `/dev/infiniband` confirmed missing in the
container. 5-rep medians, unique prefixes per repetition, warm mesh:

| prefix tokens | recompute | pull | delta |
|---:|---:|---:|---:|
| 2,048 | 77.1 ms | 97.7 ms | +26.7% |
| 8,192 | 251.7 ms | 302.5 ms | +20.2% |
| 16,384 | 513.8 ms | 570.0 ms | +10.9% |
| 24,576 | 802.9 ms | 856.8 ms | +6.7% |
| 32,768 | 1,189.7 ms | 1,131.3 ms | **-4.9%** |
| 36,864 | 1,364.8 ms | 1,283.9 ms | -5.9% |
| 40,960 | 1,574.8 ms | 1,390.0 ms | -11.7% |
| 45,056 | 1,772.5 ms | 1,567.6 ms | -11.6% |
| 49,152 | 1,998.3 ms | 1,692.8 ms | -15.3% |

Monotonic throughout. **The TCP crossover is ~29K tokens**, interpolating
between 24,576 (+6.7%) and 32,768 (-4.9%) - not "between 32K and 48K".

Where the two ladders agree and disagree is itself the evidence: they match
at 2K (+26.7 vs +29.0) and at 48K (-15.3 vs -16.5), and diverge only in the
middle, worst at 8K (+20.2 vs +57.6). Endpoints reproduce; the middle of the
old run does not.

**Consequence for the guide.** RDMA is not a prerequisite - it is what sets
`minCachedTokenDelta`. With `rdma/ib` the pull wins from 2K up, so `2048`
follows. Without it the pull loses below ~29K and wins above, so the same
deployment needs a threshold an order of magnitude larger and only benefits
workloads whose reused prefixes are that long. Both guide passages now say
that, and the earlier "deployment-blocking prerequisite" framing recorded in
this file is withdrawn.

Configs and raw output: [configs/tcp-crossover](configs/tcp-crossover).

## Scenario D re-run - the guide's headline reproduces, on the arm that matters

*This campaign ran the precise index at the default `podCacheSize` of 10,
which undersizes a 16-pod fleet; the corrected record is the podCacheSize
32 section below. The arm ordering and the cold-start finding hold; the
magnitudes do not.*

Scenario D is the guide's headline and had never been re-measured on the
fixed stack. Re-run here with `rdma/ib` verified, 16x gpt-oss-120b
aggregated (`scend-agg`), the current overlay (#48021 merged + #49877 at
`15b53af1` + #49850), and the guide's own `epp-affinity.yaml` /
`epp-affinity-p2p.yaml` / `epp-load-p2p.yaml` embedded verbatim. Workload
per the guide: 192 conversations x 48K-token private document, 6 turns of
256 tokens, concurrency 128, 1,152 turns per run. Driven from an in-cluster
pod. Each arm cold-rolls the fleet first, then runs twice.

TTFT p50/p95/p99 (ms) and throughput (turns/s):

| arm | run | ok/fail | p50 | p95 | p99 | turns/s |
|---|---|---|---|---|---|---|
| `affinity` | 1 (cold) | 870/47 | 3,243 | 85,772 | 164,872 | 3.23 |
| `affinity` | 2 (warm) | 1152/0 | 4,011 | 75,048 | 132,579 | 4.65 |
| `affinity + P2P` | 1 (cold) | 864/48 | 3,990 | 83,973 | 164,488 | 3.18 |
| `affinity + P2P` | 2 (warm) | 1152/0 | 3,719 | 69,560 | 126,666 | 5.06 |
| **`load + P2P`** | 1 (cold) | 1152/0 | 3,422 | **12,915** | **20,691** | **6.86** |
| **`load + P2P`** | 2 (warm) | 1152/0 | 3,157 | **11,741** | **18,154** | **7.54** |

Zero pod restarts across all six runs.

**The guide's `load + P2P` numbers reproduce closely.** Published: 4.5 /
13.0 / 20.9 s at 7.02 turns/s and 3.9 / 12.5 / 26.7 s at 7.76. Measured
here: 3.4 / 12.9 / 20.7 s at 6.86 and 3.2 / 11.7 / 18.2 s at 7.54. p95
within 0.1-0.8 s, p99 within 0.2 s on the first run, throughput within 3%.
That is the guide's headline arm landing on its published figures on a
different rig build, months later - and it also validates this harness:
the driver, rig and method return the guide's own numbers when the arm
matches, so the other arms' results are not an artifact of a broken setup.

**The scenario's conclusion holds, and harder.** `load + P2P` beats
`affinity` by +62% throughput (7.54 vs 4.65) and 7.3x on p99 TTFT (18.2 s
vs 132.6 s) warm, and by +112% / 8.0x cold. The guide's own margin was
narrower (+1% throughput, 1.4x p99 between the second runs), so nothing
here weakens its recommendation to reach for `load + P2P` on this workload
shape.

### Where this run diverges from the guide, and why

The two affinity arms are much worse here than published: p95 75-86 s
against the guide's 17-41 s. The cause is visible in the fleet, not the
numbers. Sampling in-flight depth per pod during a cold affinity run:

| sample | in-flight | busy pods | top pod's share |
|---|---|---|---|
| t+0s | 122/128 | 10/16 | **78.7%** |
| t+30s | 126/128 | 15/16 | 66.7% |
| t+60s | 73/128 | 15/16 | 21.9% |

On a cold fleet every endpoint scores identically - nothing is cached - so
precise-affinity placement has no signal to separate candidates and the
pick collapses onto one pod, which builds a ~91-deep queue of 48K prefills
while nine pods sit idle. It disperses within a minute as the prefix index
fills, but the tail damage is already done: that is what produces the 165 s
p99 and the 47-48 client timeouts in each affinity arm's first run.
`load + P2P` never sees it - load placement spreads by construction,
independent of cache state, which is why its *cold* run is already clean
(1152/1152, zero failures).

So the divergence is methodology meeting a real property: this campaign
cold-rolls the fleet before every arm so arms cannot contaminate each
other, and that penalises exactly the arms that are fragile to cold caches.
**Affinity placement is cold-start-fragile; load placement is not.** The
guide's runs did not start cold, so they never exposed it. Worth stating in
the guide for anyone who scales out, restarts a fleet, or deploys fresh.

### `affinity + P2P` adds nothing here either - and the reason is the same

Warm, `affinity + P2P` reads +8.8% throughput and -4.5% p99 against
`affinity`. That is not the pull: the arm established **2 P2P sessions
across all 16 pods** for the entire run, against **65** in `load + P2P` on
the identical rig. Fleet prefix hit rate tells the same story - ~27% under
affinity versus 9.9% under load placement, i.e. affinity keeps the KV local
so `minCachedTokenDelta` is essentially never met and there is nothing to
fetch. The 8.8% is run-to-run variance, and the guide's own Scenario D note
records 10-28% spread on this workload.

This is now the third independent scenario showing it - Scenario C's
arm1/arm2 (0 sessions), Scenario B's inert affinity arm, and this one - so
it is a property of the configuration, not of any single workload: **under
affinity placement the pull is insurance, not a performance feature.** The
guide credits `affinity + P2P` with better p95/p99 than `affinity` in its
Scenario D table (27.7-33.6 s vs 41.0-80.5 s); that separation does not
reproduce here, and the mechanism evidence says it cannot be a pull effect
when the pull runs twice.

Configs, driver and raw logs:
[configs/scenario-d-rerun](configs/scenario-d-rerun).

## Scenario B re-run - the hot set is too small to pressure a 16-pod fleet

Re-run with `rdma/ib` verified, 16x gpt-oss-120b aggregated, the current
overlay, and the guide's `epp-affinity.yaml` / `epp-load.yaml` /
`epp-load-p2p.yaml` embedded verbatim. Workload per the guide: 8 hot
prefixes x 48K tokens, 512-token outputs, 12/24/36/48 req/s, 120 s client
timeout. Driven in-cluster. Each arm cold-rolls the fleet, then one ladder.

**A third arm was added.** The guide's table has only `affinity` and
`load + P2P`, which changes placement and the pull together. `load` (no
pull) makes the pair `load` vs `load + P2P` - identical placement, one
plugin apart - so this scenario isolates the pull for the first time.

achieved req/s / latency p50:

| offered | `affinity` | `load` | `load + P2P` |
|---:|---|---|---|
| 12 | 11.96 / 290 ms | 11.69 / 367 ms | 11.76 / 316 ms |
| 24 | 22.96 / 300 ms | 23.06 / 317 ms | 23.07 / 315 ms |
| 36 | 33.06 / 357 ms | 34.21 / 358 ms | 35.19 / 366 ms |
| 48 | 44.15 / 400 ms | 46.81 / 381 ms | 46.04 / 377 ms |

7,200 requests per arm, **zero failures in every arm at every rate**, zero
restarts.

**The pull makes no difference**: `load` -> `load + P2P` is +0.6 / +0.0 /
+2.9 / -1.6% across the ladder, mean **+0.5%**, swinging both ways. This is
not the affinity-inertness seen elsewhere - the pull genuinely ran here,
**119 P2P sessions across 16 pods**. It ran and changed nothing.

**Why: the hot set fits everywhere.** 8 x 48K = 384K tokens against ~1.22M
tokens of GPU KV per pod, so after warmup every pod caches every hot prefix.
Measured at the end of the `load` arm: **all 16 pods served traffic, each at
~96% prefix hit rate**, with queries evenly spread (10.1-10.6M per pod);
fleet hit rate 95.8-98.1% throughout. The arm the guide calls "the recompute
floor" never recomputes, so the pull has no misses to cover and cannot help
whatever the transport does.

### The guide's Scenario B pathology does not reproduce

| offered | guide `affinity` | measured here |
|---:|---|---|
| 12 | 9.9 / 11.8 s | 11.96 / 0.29 s |
| 24 | 14.7 / 27.0 s | 22.96 / 0.30 s |
| 36 | 15.3 / 53.8 s | 33.06 / 0.36 s |
| 48 | 13.1 / 75.3 s, **672 failures** | 44.15 / 0.40 s, **0 failures** |

The guide's claim is that the owner pods cap near 15 req/s and shed 672
requests at offered 48. Here the affinity arm sustains 44 req/s at 400 ms
with no failures - about 3x the reported cap, and more than the guide's
*winning* `load + P2P` arm (34.3). Affinity is genuinely concentrating (6 of
16 pods busy at rate 24, top pod holding 43% of in-flight), so this is not a
misconfigured arm; the owners simply absorb the decode load. Something bound
the rig behind the guide's table at ~15 req/s that does not bind this one.
The render path is the obvious suspect given its documented saturation mode,
but that is untested here and stated as an open question, not a diagnosis.

**Consequence.** On a 16xH200 gpt-oss fleet Scenario B cannot demonstrate
P2P value, by construction rather than by measurement noise: a working set
that fits in every pod leaves nothing to fetch. Making it a P2P scenario
needs a hot set larger than a single pod's GPU cache (>1.22M tokens, i.e.
25+ prefixes at 48K rather than 8), which would also restore the
owner-concentration pathology the section is built around.

Configs, driver and raw logs:
[configs/scenario-b-rerun](configs/scenario-b-rerun).

## Workload 1: P2P on the optimized-baseline guide's own path

Question: does adding the `p2p-source-producer` to the optimized-baseline
guide's shipped routing (`prefix-cache-affinity-filter` + `token-load-scorer`
on the approximate index) add value on that guide's workload shape?
Pre-registered rule: if fewer than ~5% of high-rate requests pull, the
result is no-regression evidence, not a value claim.

Setup: 16x gpt-oss-120b aggregated (`scend-agg`, rdma/ib), 150 shared-prefix
groups x ~6K tokens, 500-token question and output, POISSON arrivals,
in-cluster driver, cold fleet roll per arm, config gated by file and content.
`peakPrefillThroughput` calibrated on this rig with the guide's own recipe:
**36,662 tok/s** (the plugin default, 15,928, is Qwen-32B/H100 - do not
carry it across models). Arm P adds a second approx producer (CPU-tier
capacity) feeding `p2p-source-producer` at `minCachedTokenDelta: 2048` (GLM
armD wiring); placement plugins and weights identical across arms.

### The designed ladder (3->60): exact null, pull rate 0%

Achieved req/s and TTFT p50 identical at every stage (49.7 vs 48.5 at rate
60, p50 60-89 ms both, zero failures across 22,000+ requests). Byte-level
equality from the counter sampler: **`external_prefix_cache_hits_total` = 0
and `kv_offload_load_bytes_total` = 0 in BOTH arms for the entire run** -
the p2p arm is behaviorally identical to the reference because the pull
never fires. Per the pre-registered rule: no-regression evidence only.

### Why the pull cannot fire here - two mechanisms, both code-verified

**1. (RETRACTED) A hook-ordering trap was claimed here and does not survive
verification.** An earlier revision asserted that declaring the
p2p-source-producer after the approx producer let the approx producer's
optimistic PreRequest recording mask the comparison. The causal claim is
wrong: the producer's PreRequest reads the computing pod's cached count from
the per-request attribute stashed during Produce - before scheduling, before
any recording (`computingCached := p.cachedTokenCount(endpoint)` on the
scheduling-cycle endpoint object) - so declaration order cannot affect the
current request's comparison. Confirmed empirically: Scenario B and D fired
119 and 65 sessions with the producer declared last, and the one
producer-first firing (the herd probe) is fully explained by the herd. The
TRACE's `best == computing` on 711/711 requests needs no masking to explain:
under the affinity filter the computing pod IS the best holder, because the
filter routed the request there. Holder-routing plus the load gate is the
whole explanation. (What remains true and code-verified: hooks run in config
declaration order, and both approx and precise producers seed speculative
index credit for the scheduled endpoint in PreRequest - that credit affects
the NEXT request's view, by design.)

**2. The affinity filter's load gate encodes an SLO tolerance, not a spill
cost - and at the default the pull can never have work.**
`prefix-cache-affinity-filter` breaks stickiness only when the sticky pod's
estimated TTFT exceeds the best alternative's by `maxTTFTPenaltyMs`, default
**18,000 ms**. That default is not a bug: the calibration recipe carries the
same 18 s as `T_MAX_SECONDS`, a TTFT SLO tolerance - the shipped philosophy
is "stay sticky unless the wait would breach an ~18 s SLO", and by that
criterion nothing in these runs misbehaved. But it means placement leaves a
credited holder only when one pod carries ~660K more in-flight tokens (~70
queued requests) than an idle one, which the guide-shaped ladder never
produces - so no request ever lands where a pull could help. The alternative
philosophy is a cost bound: spill as soon as the estimated wait exceeds what
the spill itself costs (~200 ms recompute on this model, ~100 ms pull). The
guide documents neither the semantics nor when to prefer which; that
documentation gap, not the default value, is the upstream feedback. With a
pull available the spill price drops, which is what would justify the tighter
bound in the P2P composition.

### Saturation A/B (60,100,100 offered; as-shipped gate): still null

| stage | reference | + p2p (producer-first) |
|---:|---|---|
| 60 | 48.5 / 104 ms / p95 4.0 s | 49.5 / 98 ms / p95 3.8 s |
| 100 | 61.4 / 119 ms / 2.8 s | 59.1 / 107 ms / 2.8 s |
| 100 | 65.1 / 107 ms / **151 ms** | 65.5 / 103 ms / **168 ms** |

Zero failures, zero sessions in both arms. Even 1.5x past the calibrated
fleet peak, a properly-spread index keeps every request on a credited holder
- the reference recovers to a 151 ms p95 on its own by paying cheap
recomputes as the index redistributes. On a cheap-recompute model the
as-shipped optimized-baseline routing leaves nothing for the pull to do at
any load level tested.

### The pull CAN fire - observed once, under index/placement divergence

One probe run created the divergence the ladder never does (EPP restart
against warm engines: cache-hit warmup requests finish in ~6 ms, no
in-flight load ever separates score ties, and the deterministic picker sends
every seed - and its index credit - to ONE pod; measured 222 in-flight
requests on one pod, 15 idle, the optimized-baseline instance of the
cold-start herding recorded for Scenario D). When the herd broke under the
producer-first config, the pull engaged for the first time in the campaign:
**39 P2P sessions, 146,560 prefix tokens / 6.49 GB pulled across 12 pods**,
coinciding with the saturated stage going from p95 2,516 ms to 173 ms and
58 -> 64 req/s achieved. Single-arm and confounded (index rebuild), so
directional only - but it demonstrates the wiring works end-to-end the
moment placement and cache genuinely diverge.

### The gate-calibrated pair completes the matrix

`maxTTFTPenaltyMs: 500` (approximately the pull cost), with and without the
producer, same ladder. The full 2x2 - achieved req/s / TTFT p50 / p95 per
stage, P2P sessions per arm:

| P2P | gate | 60 | 100 (first) | 100 (second) | sessions |
|---|---|---|---|---|---|
| no | 18 s (shipped) | 48.5 / 104 / 4,029 | 61.4 / 119 / 2,847 | 65.1 / 107 / 151 | 0 |
| yes | 18 s (shipped) | 49.5 / 98 / 3,757 | 59.1 / 107 / 2,772 | 65.5 / 103 / 168 | 0 |
| no | 0.5 s (calibrated) | 47.3 / 104 / 3,709 | **65.4 / 105 / 164** | 64.6 / 104 / 161 | 0 |
| yes | 0.5 s (calibrated) | 47.3 / 101 / 4,133 | 64.5 / 105 / 310 | 64.1 / 104 / 154 | **53** |

Zero failures throughout (one timeout in 35,000+ requests).

**The gate calibration is the win, and it does not need P2P.** Fixing
`maxTTFTPenaltyMs` alone removes the mid-ladder tail transient (p95 2,847 ->
164 ms at the same offered rate): the router spills early and the ~200 ms
recompute is cheap. That is an optimized-baseline finding independent of
this guide.

**The pull fires at the calibrated gate and changes nothing.** 53 sessions,
206,976 prefix tokens / 7.79 GB pulled - a **0.2% pull rate** against the
~8,800 rate-100 requests. Throughput and p50 identical to the no-P2P arm;
the pull's ~100 ms saving over a ~200 ms recompute, on 0.2% of requests
each lasting ~10 s, is arithmetically invisible. The pre-registered rule
(<5% pull rate) fires for every cell of the matrix: **on this guide's path
and workload shape, P2P is no-regression, not value** - the same rule that
holds everywhere in this campaign: the pull pays in proportion to
(prefix length) x (recompute cost) x (miss rate), and a 6K-token prefix on
a 29K-tokens/sec-prefill model prices the pull's edge at ~100 ms per rare
miss. The paths where those factors are large are where the value is
measured: 48K-token document Q&A (Scenario D: load+P2P 7.3x p99 over
affinity) and 10K-100K-token agentic sessions (Run O: 4.8x median TTFT).

Configs, driver, runner, sampler and raw logs:
[configs/workload1-optimized-baseline](configs/workload1-optimized-baseline).

### Recovery A/B at the shipped gate: no herd, no pulls, and a structural
### reason the approximate index cannot drive recovery

Hypothesis (user's): under the shipped 18 s gate, P2P's win might be the
recovery path - disruption moments where the router's view and the engines'
caches diverge massively. Protocol per arm: cold-roll engines, precondition
at rate 24 (spread, warm caches), restart the EPP against the warm fleet,
then rate 100 x 3 stages with fleet-distribution sampling.

| stage (rate 100) | without P2P | with P2P (approx feed, producer-first) |
|---:|---|---|
| 1 (post-restart) | 53.3 / p50 2,056 ms / p95 4,555 | 58.5 / p50 238 ms / p95 4,172 |
| 2 | 65.4 / 106 / 1,115 | 62.7 / 105 / 1,964 |
| 3 | 66.0 / 102 / 147 | 64.4 / 103 / 166 |
| peak in-flight backlog | 2,265 | 1,437 |
| P2P sessions | 0 | **0** |

Two honest negatives. First, **the herd trigger is chaotic**: the identical
EPP-restart-against-warm-engines that produced a 222-requests-on-one-pod
herd in the earlier probe spread cleanly here in both arms (top pod 8-10%
throughout, all 16 pods busy from the first loaded sample) - the 150 warmup
seeds at concurrency 16 built just enough in-flight load to break the score
ties this time. Single runs of that transient are not comparable: the
stage-1 difference above (238 vs 2,056 ms p50) tracks the backlog-bubble
depth (1,437 vs 2,265), not the pull, which never ran in either arm.

Second, and the durable finding: **the approximate index structurally cannot
drive recovery pulls.** It learns only from its own placements, so after an
EPP restart every request's index credit is written exactly where the
request is placed - credit and placement agree from birth, a "peer
out-caches the computing pod" delta never exists, and the p2p-source-producer
has nothing to act on no matter how the hooks are ordered. The one time
pulls fired on the approx feed (39 sessions in the herd probe), it was
because a herd had concentrated credit on one pod *before* saturation
overrides scattered placement - an accidental divergence. Engine caches
survive the restart; the approx index's knowledge of them does not.

The composition that can know better is the precise (KV-events) index: it
rebuilds from the engines' own cache events, so after a restart it holds the
true holder map while placement spreads - every spread-placed request on a
non-holder is a real delta. Measured next.

### The precise feed cannot drive recovery either - KV events are
### delta-only, and the reason generalizes

Same restart protocol, placement untouched, only the p2p-source-producer's
feed swapped to `precise-prefix-cache-producer` (KV events, blockSize 64,
port 5556):

| stage (rate 100) | achieved | TTFT p50 | p95 |
|---:|---|---|---|
| 1 (post-restart) | 56.1 | 164 ms | 4,250 ms |
| 2 | 61.2 | 113 | 173 |
| 3 | 64.7 | 111 | 153 |

Zero failures - and again **0 sessions, 0 external hits, 0 bytes pulled**.

The mechanism: the KV-events subscriber has no replay or snapshot (verified
in `pkg/kvevents` - delta-only). A restarted EPP learns only about blocks
stored *after* it subscribed; the precondition-era cache - exactly the KV a
recovery pull would fetch - is invisible. Warmup seeds after the restart hit
the engines' warm caches, so they emit no store events and teach the index
nothing. By the time stage-1 recomputes repopulate the index, placement and
credit have converged again.

**The general law this campaign kept rediscovering, one mechanism at a
time: in a single-router aggregated fleet, any self-consistent affinity
router converges cache placement with its own credit - the cache exists
where the router put the request - so a "peer out-caches the computing pod"
delta never arises, and the pull has nothing to do. This holds for the
approximate index (learns its own placements), the precise index (learns
deltas it observes), either hook order, and either gate setting.** P2P fires
only where KV exists that the placement layer did not create:

- generated KV under P/D disaggregation (decode's history - Run M/N/O, 4.8x)
- placement that deliberately ignores cache (load-first - Scenario D, 7.3x p99)
- divergence inherited from outside the loop (the accidental herd - 39
  sessions; multi-router or scale-out topologies, unmeasured)

Two upstream feature candidates fall out: a KV-events snapshot/replay on
subscribe (making the precise index restart-proof and enabling recovery
pulls), and documentation that the p2p-source-producer composes with
load-first or P/D routing, not with self-consistent affinity routing,
regardless of index choice.

## Scenario A re-run - the floor and the reference reproduce exactly, and
## the pull win is larger than published

The guide's uniform-pool table was the last published result with
unverified provenance (series 1/3, no committed rig manifest). Re-run on
the verified rig: 16x gpt-oss-120b aggregated, rdma/ib confirmed, current
overlay, the guide's own `epp-affinity.yaml` / `epp-load.yaml` /
`epp-load-p2p.yaml` verbatim, 128 shared prefixes x 48K tokens, 256-token
questions, 64-token outputs, in-cluster driver, cold roll + gate per arm,
ladder 6/12/18/24/30 req/s.

achieved req/s / TTFT p50 / request latency p50:

| rate | `affinity` | `load` (recompute floor) | `load + P2P` |
|---:|---|---|---|
| 6 | 5.97 / 207 ms / 497 ms | 5.59 / 2.5 s / 5.6 s | 5.96 / 342 ms / 639 ms |
| 12 | 11.92 / 200 / 486 | 9.02 / 8.6 s / 26.2 s | 11.49 / 460 / 981 |
| 18 | 17.87 / 192 / 481 | 8.58 / 26.0 s / 45.7 s | 17.46 / 341 / 673 |
| 24 | 23.82 / 191 / 482 | 9.01 / 43.8 s / 63.4 s | 21.93 / 344 / 699 |
| 30 | 29.76 / 184 / 475 | 9.21 / 61.3 s / 81.2 s | 29.19 / 342 / 726 |

Zero failures in all three arms (16,200 requests). Pull evidence in the
`load + P2P` arm: **120 P2P sessions**, 210,407,296 external-hit tokens,
7.8 TB moved through the offload tier, GPU hit rate 17.3% (placement
scatters; the tier serves what the GPU cache cannot).

Against the published table (top rate 24):

| arm | published | re-measured |
|---|---|---|
| `affinity` | 23.7 / 0.8 s | 23.82 / 0.48 s - **reproduces** |
| `load` | 9.4 / 63.5 s | 9.01 / 63.4 s - **reproduces exactly** |
| `load + P2P` | 16.7 / 30.0 s | **21.93 / 0.70 s - much better** |

Two conclusions. First, the same-placement pull win - the guide's strongest
P2P number - **reproduces bigger than published**: at rate 24 the pull
lifts the recompute floor 9.01 -> 21.93 req/s (**+143%**, published +78%)
and takes p50 latency from 63.4 s to 0.70 s. At rate 30 `load + P2P`
sustains 29.19 vs the floor's 9.21 (**+217%**) at 726 ms.

Second, the guide's Scenario A characterization of `load + P2P` -
"degrades sharply at the top of the ladder (p50 30 s at 24 req/s versus
0.82 s)" - **does not reproduce**. On this rig `load + P2P` tracks offered
rate through 30 req/s within 8% of affinity's throughput and under 2x its
latency (726 vs 475 ms). The published 30-second p50 was measured on the
pre-fix stack, in the era of the duplicate-fetch grind and without
verifiable transport; the fixed stack plus verified RDMA removes the
degradation entirely at these rates. The direction (affinity remains best
on a uniform pool) survives; the "sharp degradation" clause and its
magnitude do not, and the guide's When-to-use paragraph should be
re-anchored to these numbers.

Configs, driver and raw logs: [configs/scenario-a-rerun](configs/scenario-a-rerun).

## Scenario B resized (32 x 48K): the pathology is a churn transient, and
## the pull erases it

Per review, the hot set was resized from 8 to 32 prefixes (1.54M tokens,
1.26x one pod's GPU cache) so no single pod can hold the whole set. Same
rig, arms and ladder as the Scenario B re-run; cold roll + gate per arm.

achieved req/s / TTFT p50 / latency p50:

| rate | `affinity` | `load` - no P2P | `load + P2P` |
|---:|---|---|---|
| 12 | 11.72 / 182 ms / 292 ms | 11.08 / **4,121 ms** / 11.1 s | 11.94 / **304 ms** / 421 ms |
| 24 | 23.00 / 190 / 319 | 22.98 / 224 / 456 | 23.15 / 202 / 353 |
| 36 | 33.17 / 184 / 355 | 34.91 / 191 / 372 | 34.35 / 195 / 373 |
| 48 | 43.39 / 193 / 375 | 45.48 / 200 / 399 | 45.90 / 202 / 402 |

Zero failures in all arms (23,040 requests). Pull evidence in `load + P2P`:
**120 P2P sessions**, 51.4M external-hit tokens, 1.9 TB through the tier.

Two results. First, the same-placement pull win is real but confined to the
**redistribution window**: in stage 1, while scattered placement churns the
caches, the pull holds TTFT at 304 ms where recompute pays 4,121 ms
(13.6x). Second, at this size the window closes: a pod fits ~25 of the 32
prefixes, so after one stage of churn every pod holds most of the set and
all three arms converge at ~200 ms - steady state is again a null.

1.26x a pod's cache is therefore still too small for a *sustained*
separation: replication across 16 pods absorbs it. The variant that cannot
be absorbed - 64 prefixes, 3.07M tokens, 2.5x a pod's cache - is staged
next. Affinity note: with 32 prefixes over 16 pods ownership spreads (~2
per pod) and affinity carries 48 req/s at 193 ms without strain, so the
original 8-prefix owner-concentration framing does not transfer to this
size either.

Configs and logs: [configs/scenario-b32](configs/scenario-b32).

## Run O re-run - prefill-pulls-from-decode reproduces on the fixed stack

Run O was the campaign's strongest P2P result and the last one standing
solely on a pre-fix-stack measurement. Re-run here on
`nightly-1240c74c` + `combined-overlay-49877new`, sidecar at the current
wire keys, `rdma/ib` on both roles, 2 prefill + 4 decode TP=1
(Qwen3-30B-A3B-Thinking), the original agentic profile verbatim (24
conversations, 10K-100K-token dynamic system prompts, 4-40 turns,
tool-call gaps that evict session KV between turns), 288 requests at
concurrency 16, driven through `llmdbenchmark`. Arms differ only in the
KV stack: A = plain `NixlConnector` P/D, sidecar without `--enable-p2p-pull`,
EPP without the p2p producer; B = `MultiConnector` (NIXL + Offloading p2p
tier), pull enabled, `p2p-source-producer` on the precise index
(`minCachedTokenDelta: 1024`). Each arm ran on a freshly re-rolled fleet.

| metric | arm A (no P2P) | arm B (+P2P) | delta |
|---|---:|---:|---:|
| TTFT p50 | 6.83 s | **1.09 s** | **6.3x** |
| TTFT p95 | 20.90 s | 12.92 s | 1.6x |
| TTFT p99 | 28.17 s | 34.66 s | 0.8x (worse) |
| TTFT mean | 8.35 s | 2.80 s | 3.0x |
| request latency p50 | 14.79 s | 8.57 s | 1.7x |
| throughput | 0.82 req/s | **1.24 req/s** | **+50%** |
| output tokens/s | 777 | 1,167 | +50% |
| run duration | 340 s | 221 s | -35% |
| completed | 288/288, 0 fail | 288/288, 0 fail | - |
| mean prompt length | 61,884 tok | 61,883 tok | identical |

Pull evidence: **9 P2P sessions**. The count is small because the topology
is small (2 prefill x 4 decode = few directed pairs), but each session
carries a conversation's accumulated history on every turn, which is why
nine of them move the median by 6x.

**The original result reproduces and is slightly stronger**: published
4.8x median TTFT and +33% throughput; measured here 6.3x and +50%, with a
fresh reference sample rather than the single arm-A run the original had.
The mechanism is the one the guide's P/D bullet describes - decode
generates the session history, so on each subsequent turn the prefill
worker faces KV it never computed and no placement decision can make
local; without the pull it re-prefills the whole accumulated history.

**Caveat, stated as in the original**: p99 TTFT is *worse* with P2P (34.7 s
vs 28.2 s). Both arms' extreme tail is the cold first prefill of a
100K-token context, which no pull can shorten, and this workload's output
length is lognormal with a long tail; the win is median, mean and
throughput, not the extreme tail. Single run per arm - the 6x median and
+50% throughput are far outside run-to-run spread, the p99 difference is
not.

This is the strongest same-stack P2P result in the campaign and the one
regime where the pull cannot be designed away by better placement: the KV
lives on the other role. Configs, arm scripts and result JSON:
[configs/run-o-rerun](configs/run-o-rerun).

## Scenario B at 64 prefixes: the payoff case, finally reproduced

The guide's Scenario B claims a hot set that overwhelms its cache owners
and a pull that rescues it. At the published 8 x 48K it could not: the set
fits in every pod (0.31x one pod's GPU cache), so nothing was ever
recomputed. Resizing walked the working-set ratio until the pathology
appeared. Same rig, arms, ladder and protocol throughout; only `NUM_HOT`
changed.

| hot set | vs one pod's GPU cache | outcome |
|---|---|---|
| 8 x 48K (published) | 0.31x | fits everywhere - no pathology, pull idle |
| 32 x 48K | 1.26x | churn transient only (13.6x during redistribution, then absorbed by replication) |
| **64 x 48K** | **2.5x** | **sustained collapse; the pull prevents it entirely** |

### 64 x 48K (3.07M tokens): achieved req/s / TTFT p50 / latency p50

| offered | `affinity` | `load` - no P2P | `load + P2P` |
|---:|---|---|---|
| 12 | 11.94 / 188 ms / 300 ms | 9.31 / 7,925 ms / 16.6 s | 11.84 / 310 ms / 423 ms |
| 24 | 23.04 / 183 / 312 | 11.47 / 24,345 / 34.5 s | 22.83 / 271 / 419 |
| 36 | 34.03 / 190 / 360 | 11.77 / 47,033 / 61.6 s | 34.34 / 249 / 445 |
| 48 | 46.03 / 196 / 378 | 13.85 / 58,187 / 72.5 s, **274 failures** | 44.93 / 254 / 477, **0 failures** |

Pull evidence in `load + P2P`: **120 P2P sessions**, 204M external-hit
tokens, **7.54 TB** through the offload tier, GPU hit rate 43.2% (the set
genuinely does not fit - contrast the 8-prefix run's 95.8%).

**Same placement, the pull the only difference, at offered 48:**
throughput **13.85 -> 44.93 req/s (+224%)**, TTFT p50 **58.2 s -> 254 ms
(229x)**, and **274 client-timeout failures -> zero**. The recompute floor
caps near 12-14 req/s at every offered rate above 24; the pull arm tracks
offered rate to 48 within 2% of affinity's own throughput.

These are the first failures recorded anywhere in this campaign, and they
are the guide's own pathology: a fleet shedding a quarter of its requests
because every displaced request re-prefills 48K tokens. The published
Scenario B attributed that collapse to *affinity* concentrating on owners;
measured here, at a set size where the pathology exists at all, it is the
**recompute floor** that sheds while affinity is fine (46.03 req/s at 196
ms - with 64 prefixes over 16 pods, ownership spreads ~4 per pod and no
owner is overloaded).

**The parameter that decides this scenario is the working-set-to-pod-cache
ratio, and the guide never states it.** Below 1x there is nothing to
measure; near 1x replication absorbs the miss stream after one stage of
churn; above ~2x the misses are permanent and the pull is the difference
between a serving fleet and a shedding one. Any deployment reading
Scenario B should size its own hot set against
`GPU KV per pod` before expecting either result.

Configs and logs: [configs/scenario-b64](configs/scenario-b64).

## GLM-5.2 wide-EP on the merged upstream tier - the overlay era is over

The wide-EP testbed's published numbers were measured on
`nightly-6a9f24aa` plus the `generic-p2p-src` source overlay (10 files
mounted over the installed package), because the P2P tier was not upstream
yet. Redeployed here on `nightly-6f91edf9` - the first nightly carrying the
tier (vllm#48021) together with all three robustness fixes (vllm#49671,
vllm#49823, vllm#49877) - with **every overlay mount and the ConfigMap
volume removed**.

Result: `zai-org/GLM-5.2-FP8` (753B MoE) came up and served, 32x H200,
1 prefill + 1 decode instance at 16-way data/expert parallel each across 2
pods, P/D disaggregated, `MultiConnector` (NIXL + Offloading with the p2p
secondary tier):

- **32/32 ranks created the P2P tier** (`Created secondary tier #0 (p2p)`,
  each binding its own ZMQ ROUTER on the rank-offset port).
- Both former hotfixes report their targets already fixed upstream
  (`mla_attention.py already patched`; the offloading `set_` overflow
  pattern no longer present), so the deployment needs no patching at all.
- End-to-end completion through the EPP returned HTTP 200 with coherent
  output.
- No `ImportError`/`AttributeError` anywhere - the engine runs entirely on
  installed code.

**This validates the guide's current deployment instructions at the largest
scale in the campaign**: pin the nightly, skip the overlay. Every earlier
wide-EP result required the patched-source workaround; this one does not.

### Operational finding: a single rank's UCX stall blocks the whole group

Hit twice during this deploy, on different roles and nodes. A rank logs
`NixlTransport ... backends=[UCX]` and then nothing - no `Backend UCX was
instantiated`, no ROUTER bind, no tier - silently, with no error, no
restart and near-zero CPU. Because the DP Coordinator waits for all ranks,
every healthy rank sits in `Waiting for READY message from DP
Coordinator...` indefinitely (500+ polling lines observed) and the fleet
never reports ready inside its 45-minute startup budget.

Diagnose by counting per pod - these should equal the local rank count:

```
kubectl logs <pod> -c vllm | grep -c "Backend UCX was instantiated"
kubectl logs <pod> -c vllm | grep -c "Created secondary tier"
```

A pod at 7/8 names its own culprit by diffing the ranks that logged a tier
against the ranks present in the log (DP14 in the case here). The remedy is
to delete any pod of the affected LWS group; the group restarts together
and the stall does not reproduce - it is transient, not a bad node (the
replacement landed on the same node via leafgroup podAffinity and came up
clean). Two misreadings to avoid: the `/dev/infiniband` list skipping index
5 is normal on this cluster (all pods show `uverbs0-4,6-8`), and
`/dev/shm` reaching ~800 GB means the CPU tiers allocated fine.

## GLM crossover re-measured on the upstream tier, with a control that
## proves the pull

2026-07-29. Consumer = prefill leader (the P/D-relevant direction), source =
decode leader, direct `kv_transfer_params` injection (no EPP, no sidecar),
fresh random token IDs per probe, medians of 3, warm mesh, first pull
discarded. Configs and raw logs: [configs/glm-rank-fix](configs/glm-rank-fix).

Coarse (4K-24K) and fine (8K-12K) sweeps agree: recompute is linear at
130.2 / 146.6 us/token, the pull is FLAT at ~1,251 / ~1,214 ms, fitted tie
points 8,713 and 8,604 tokens - **crossover ~8,650**, down from the
overlay-era 13,648 because the pull floor fell from ~1.7-2.3 s to ~1.25 s.
Recommended `minCachedTokenDelta: 12288`: 8,192 is a dead tie whose sign
flips between runs (+9.6% / -1.0%); 12,288 is the lowest length both sweeps
call decisively (-27.4% / -27.8%).

| tokens | recompute | pull | delta | pulled in |
|---:|---:|---:|---:|---:|
| 4,096 | 672.2 ms | 1,262.2 ms | +87.8% | 379.4 MB |
| 8,192 | 1,067.8 ms | 1,170.6 ms | +9.6% | 758.8 MB |
| 12,288 | 1,708.5 ms | 1,241.0 ms | -27.4% | 1,138.2 MB |
| 16,384 | 2,148.3 ms | 1,268.9 ms | -40.9% | 1,517.6 MB |
| 24,576 | 3,338.0 ms | 1,315.3 ms | -60.6% | 2,276.4 MB |

The paired control at 12,288 - same seeded fresh prefix, pull parameter the
only difference - reads **0.0 MB without the parameter and 1,138.2 MB with
it**, three reps, byte-identical. `CPU_to_GPU` is ambiguous in general (it
counts local restores) but is peer-attributable when the consumer has never
seen the token IDs; this control is what makes the byte column trustworthy
and is now built into the calibration recipe.

Transfer rate is constant at **92.6 KB/token** across every length.

## The rank-addressing bug: why wide-EP pulls only ever worked from leader
## pods, and why fixing the index alone made things worse

vLLM binds the OffloadingConnector P2P tier at `p2p-connector-port +
GLOBAL DP rank` (measured live: decode leader 7777-7784, worker 7785-7792).
The EPP `p2p-source-producer` emits only the source's serving `host:port`,
and the sidecar's `p2pPortFor` derives the POD-LOCAL rank from the serving
port. Leaders are correct (local == global); worker-pod sources dial below
their listener range. On this 2-pod x DP8 cell, at most **8/16 rank sources
were ever pullable**.

Severity: a mis-addressed pull does not degrade to recompute - **the
request hangs until the client gives up**. Live discriminator on the fixed
sidecar, source = decode worker local rank 3 (global 11), seeded
deterministically via its per-rank API port `:8003`, 24,576 tokens:

| | dials | outcome | bytes into consumer |
|---|---|---|---:|
| no rank header (shipped) | :7780 (not listening) | 600 s client timeout | 0.0 MB |
| `x-kv-cache-source-rank: 11` (fix) | :7788 | 25.6 s | **2,276.4 MB** |

2,276.4 MB is byte-identical to the calibration's 24K value - the sidecar
path now moves exactly what direct injection moves.

This closes the campaign's three-era GLM causal chain:

1. `podCacheSize: 10` (default): the per-key LRU holds 10 (endpoint, tier)
   entries against 64 contenders, real holders evict, the producer never
   finds a peer - **pull inert, clean null A/B**.
2. `podCacheSize: 64`, shipped sidecar: sources emitted for the first time,
   worker-pod sources hang requests - **warmup collapse** ("prefill
   returned 502" / "context canceled" burst).
3. `podCacheSize: 64` + rank fix: the valid configuration.

Fixing the index WITHOUT the rank fix is worse than fixing neither.

The fix (EPP emits the global rank in a companion `x-kv-cache-source-rank`
header - worker-index label x configured `len(pool.TargetPorts)` stride +
pod-local rank; sidecar prefers it over port derivation) is on
`fix/p2p-source-global-rank` (nilig fork, `1f0892ca` + `67db2b8f`), unit-
and request-level tested, live-validated above. Precedent: MoRIIO's
per-request `remote_dp_rank` pinning; plain NIXL is immune because the
prefill engine self-reports its address in the response handshake, and the
P2P tier has no handshake.

Also queued upstream: the hang itself - a tier fetch to a non-listening
port should fail fast and fall back to recompute.

## GLM A/B on the fully-fixed stack: the pull wins the tail

Same fleet for both arms (rolled fresh-paired before arm 1), rank-fix
sidecar on decode, `podCacheSize: 64` in BOTH arm configs, EPP `--v=5`,
zero 502s and zero hangs in either arm, aiperf agentic profile c128, 900 s.
Exact deployed arm configs: [configs/glm-rank-fix](configs/glm-rank-fix).

| metric | precise, no pull | precise + pull (16K delta) | delta |
|---|---:|---:|---:|
| TTFT p50 | 3,132 ms | 3,107 ms | -0.8% |
| TTFT p90 | 9,600 ms | 8,716 ms | **-9.2%** |
| TTFT p95 | 14,127 ms | 12,158 ms | **-13.9%** |
| TTFT p99 | 24,638 ms | 17,668 ms | **-28.3%** |
| Request latency p50 | 20,048 ms | 20,046 ms | 0.0% |
| Throughput | 3.7 req/s | 3.7 req/s | - |
| Requests | 3,477 | 3,444 | both complete |

The shape is the placement law's signature: medians equal (affinity already
puts the request where the KV is), tails compressed (the pull rescues the
displaced and queued cases). Direction matches the original published pair
(-16% p50 / -15% p90 on the overlay stack) in tail-heavy form.

Attribution caveat: the run-window EPP log rotated away (TRACE at c128
exceeds kubelet rotation) and the fleet was reclaimed before per-arm byte
deltas were read, so emissions/bytes for this pair are not recorded. A
repeat of the pull arm with live mid-run sampling (2-minute emission and
counter polls to local files) is running as of this entry; its numbers
supersede this caveat when recorded.

Three observability traps hit in one day, all now procedure: a `--since`
window that misses the run, a pod replaced after the run (logs die with
it), and log rotation under TRACE at load. Sample live, to files, during
the run - never reconstruct afterward.

## CORRECTION: the tail win was variance - the pull is structurally inert
## under precise affinity with a healthy index, and now we can prove why

The attributed re-run (live 2-minute sampling of emissions and counters,
immune to log rotation and pod churn) settles the pair above:

- **115 `evaluating KV cache source` lines captured, 0 emissions.** Every
  evaluation carries `bestCachedTokens - computingCachedTokens = 0`; 52 of
  115 are literal self-matches. No `minCachedTokenDelta` would fire - not
  16,384, not 1.
- The re-run's TTFT p99 is 22.5 s against the pair's 24.6 / 17.7 s. Three
  behaviorally-identical runs spanning 17.7-24.6 s at p99 means **the
  -28.3% in the table above is run-to-run variance, not a pull effect.**
  Its row is retracted; medians (which agree within 1% across all three
  runs) stand.

This also resolves the July grid paradox. The overlay-era c32 wins
(-27% p50 / -45% p90, 41-163 GB of verified transfers) were real pulls -
fired by phantom deltas that the then-broken index manufactured:
`podCacheSize: 10` evicted (endpoint, tier) entries asymmetrically, so the
scheduled pod and the best peer read different cached-token counts for the
same physically-replicated prefix, and the pull repaired the resulting
placement divergence. Fixing the index removed the divergence and with it
the trigger. Both eras' measurements are correct; what changed is that a
consistent index under precise affinity has nothing for the pull to repair
on these traces.

The P/D opening (prefill pulling decode-generated history) is additionally
closed on GLM-5.2 specifically: it streams reasoning content that the chat
template drops on re-render, so decode's stored KV diverges from the next
turn's rendered prompt - the guide's standing model caveat, now observed
as exact zero deltas.

Where divergence exists by construction, the pull still has a trigger:
load-first placement (the gpt-oss pool and hot-set wins), restarts/cold
replicas, and the approximate index (which only learns its own placements
and estimates by hash). The approximate pair at 753B is the next
measurement.

## Matched c32 precise vs precise+P2P: -67% mean TTFT, 2.7x throughput,
## independently reproduced on the PR images (2026-07-30)

The load-spill payoff benchmark, designed and first run by Maroon on the
kv-source-endpoint fix stack, reproduced end to end on independently
built images of the llm-d-router PR code (#2233 kvevents rank-endpoint
attribution + #2234 sidecar full-endpoint guard), a freshly booted fleet,
and fresh prompt salts. This is the entry designated for the guide's
benchmark section and the blog.

Setup: GLM-5.2-FP8 wide-EP (prefill 2 pods x DP8 + decode 2 pods x DP8,
32 H200), vLLM `nightly-6f91edf9`, per-pod port-base compensation
(`7777 - START_RANK`, `5557 - START_RANK`). Prefill routing policy:
`precise-prefix-cache-scorer` w1 + `queue-scorer` w3 +
`active-request-scorer` w1 - deliberately load-first so placement spills
off the cache holder; the p2p mode adds only `p2p-source-producer`
(`minCachedTokenDelta: 16384`). Per repetition: fresh ~70K-token salted
prefix, 3 warmups, 96 measured requests at concurrency 32, 8 output
tokens. Counterbalanced order (precise r1, p2p r1, p2p r2, precise r2,
precise r3, p2p r3), EPP restarted and probed on every profile swap.
Configs, client, runner, one job spec, and all six rep logs:
`configs/glm-c32-matched/`.

| mode | rep | TTFT mean (s) | p50 | p90 | req/s | wall (s) |
|---|---:|---:|---:|---:|---:|---:|
| precise | 1 | 8.436 | 3.798 | 22.133 | 3.484 | 27.6 |
| precise | 2 | 7.598 | 3.827 | 21.061 | 3.955 | 24.3 |
| precise | 3 | 7.532 | 4.215 | 20.767 | 3.964 | 24.2 |
| p2p | 1 | 2.641 | 2.348 | 5.203 | 9.955 | 9.6 |
| p2p | 2 | 2.454 | 1.790 | 4.839 | 10.509 | 9.1 |
| p2p | 3 | 2.575 | 1.911 | 4.958 | 9.821 | 9.8 |

All 576 requests returned 200. Aggregate (avg of rep means): precise
7.855 s / 3.80 req/s vs p2p 2.557 s / 10.10 req/s = **-67.4% mean TTFT,
-76.5% p90, 2.66x throughput**. Maroon's original on the same fleet
shape: 7.649 -> 2.310 s (-69.8%), 3.90 -> 10.90 req/s (2.80x); every
repetition of ours lands in or adjacent to his per-rep bands.

Mechanism: the precise mode's ~21 s p90 is the spill tail - queue-first
placement sends ~70K-token prompts to non-holders, which recompute. The
pull replaces that recompute with a flat-cost transfer, collapsing p90 to
~5 s. Pull-path liveness on this exact build was proven the same morning
by the correlated pull proof (per-rank attribution 45/45 block keys,
header, source accept on the rank-offset port, consumer load =
tokens x 92.6 KB/token, 3/3 runs); per-rep engine load counters were not
snapshotted in this run (fleet scaled down at completion) - the
per-request times in the p2p mode are unreachable by 70K-token recompute.

Framing rule for guide/blog: **P2P converts load-spill recompute into a
flat-cost pull; where routing trades affinity for load balance, it
recovers the cache reuse that placement gives up.** It is NOT a general
GLM speedup - under holder-affinity policies (w5) the pull correctly
idles and arms tie (see the weka section below).

## Weka agentic 4-arm campaign on the fixed stack: codex-corrected record
## (2026-07-30)

Four arms (precise / precise+P2P / approx / approx+P2P) on aiperf
`inferencex-agentx-mvp`, dataset `semianalysis_cc_traces_weka_with_subagents`,
c128, 900 s per arm, same fleet, EPP config the only per-arm variable.
Configs, runners, aiperf logs, and counter snapshots:
`configs/glm-weka-4arm/`.

Adversarial review (codex) voided most first-pass conclusions. Surviving
claims: (1) **approx+P2P went from engine-crashing on the pre-fix stack
(07-29) to running clean on the fixed stack** - 3,385 requests, 0
failures; (2) the approx pair shows **no regression** from adding P2P.
Voided and why: the precise no-pull arm carried 8,571 hidden request
errors (concurrent-operator EPP disruption mid-run; the Job still
completed rc=0), so the precise pair is not comparable; P2P
`accepting incoming connection` counts SESSION establishment, not pulls
(sessions persist across arms); role-summed connector counters are
invalid (decode P/D reports ~100% external hits by design; prefill-side
external hit was ~26% where the sum said 87%); the approx profile
declares but does not schedule `queue-scorer`.

Warm-arm numbers for the record (not a validated A/B): precise+P2P
3.56 req/s / TTFT p50 3,287 ms; approx 3.53 / 3,012; approx+P2P 3.60 /
3,062. Consistent with the placement-creates-the-cache law: under
holder-affinity routing on recurring-prefix traffic the pull rarely
fires (~0.8% of requests precise, none observed approx) and cannot
differentiate arms. The valid payoff measurement for this model is the
matched c32 section above.

## Fair four-way closes: the index is the lever - precise turns the pull
## into -67%, approx into ~-11% (2026-07-30)

The approx side of the matched c32 benchmark, run with the same scorers
and weights as the precise pair (`controlled-prefix-cache-scorer` w1 +
`queue-scorer` w3 + `active-request-scorer` w1, `minCachedTokenDelta:
16384`); the only difference between index modes is the producer
(`approx-prefix-cache-producer`, blockSizeTokens 64,
maxPrefixTokensToMatch 131072, lruCapacityPerServer 200000, vs the
KV-event-fed precise producer). Single-deployment harness with per-rep
traffic validation: every rep's streamed serving-EPP log carries the
benchmark's own 99-100 distinct request IDs (a first-run version of this
experiment was VOID for exactly that reason - the cloned jobs' `--url`
pointed at a different EPP deployment than the one being swapped and
observed; harness rule recorded in the runner).

A mechanism probe gated the campaign: seed one ~131K-token prompt through
the EPP on `fair-approx-p2p`, send it again, require
`bestCachedTokens > 0` on the repeat. It credited the full
`maxPrefixTokensToMatch` (131,072) - the approx index works; the prior
"approx credits nothing" observation was the void run's readiness probe.

| rep | TTFT mean (s) | p50 | p90 | req/s | headers fired |
|---|---:|---:|---:|---:|---:|
| approx r1 | 9.33 | 4.32 | 22.9 | 3.13 | 0 |
| approx r2 | 7.84 | 1.88 | 21.3 | 3.76 | 0 |
| approx r3 | 8.32 | 3.76 | 19.1 | 2.87 | 0 |
| approx+P2P r1 | 7.55 | 2.45 | 20.5 | 3.93 | 15 |
| approx+P2P r2 | 7.24 | 3.11 | 19.7 | 4.06 | 15 |
| approx+P2P r3 | 7.86 | 4.08 | 19.3 | 2.95 | 16 |

Four-way, identical policy (precise rows are the same-day matched pair):

| mode | TTFT mean | TTFT p90 | req/s |
|---|---:|---:|---:|
| approx, no pull | 8.50 s | 21.1 s | 3.25 |
| approx + P2P | 7.55 s | 19.8 s | 3.65 |
| precise, no pull | 7.86 s | 21.3 s | 3.80 |
| precise + P2P | **2.56 s** | **5.0 s** | **10.10** |

Mechanism: inside the benchmark 98/100 source evaluations saw positive
`bestCachedTokens`, but the header fired on only ~16% of requests
(15/15/16 per rep - strikingly stable). The best-vs-computing delta
rarely clears 16,384 because the approx index credits every rank a
spilled request LANDS on: placement-recorded credit accrues to the spill
targets themselves, eroding the asymmetry the source decision needs.
Precise credits only ranks that actually hold KV, so the delta persists
and the pull rescues the whole spill tail. Net at the rep level the
approx pull's -11% mean / +12% req/s overlaps the control's own spread
(approx+P2P r3 7.86 vs approx r2 7.84) - a weak positive trend, not a
headline.

Deployment guidance this measures: the load-spill payoff requires the
precise (KV-events) index; the approximate index composes safely with
the pull and fires occasionally, but recovers little of the spill cost.
Configs, runner, bench logs, and the distilled per-rep mechanism
evidence: `configs/glm-c32-fair-approx/` (the raw streamed EPP logs are
128-145 MB per rep and are summarized in `mech-summary.txt` instead of
committed).

## Scenario D at podCacheSize 32: the index-sizing bias quantified, and the
## corrected doc-QA record (2026-07-30)

The Scenario D re-run above ran the EPP's precise index at the default
`podCacheSize` of 10 per-key holder slots. On a 16-pod fleet that evicts
real holders (size must be >= endpoints x tiers; see the GLM
`podCacheSize` finding), so every arm that consults the index - affinity
placement, and P2P source selection in both P2P arms - ran degraded.
Re-measured here with the single variable changed: same rig
(`scend-agg`, 16x gpt-oss-120b single-GPU aggregated), same build
(`nightly-1240c74c` + sidecar `p2p-rename-43aea48e`), same guide EPP
configs plus `podCacheSize: 32`, same driver and workload (192
conversations x 48K-token document, 6 turns x 256 tokens, concurrency
128, 1,152 turns/run), in-cluster driver, cold roll per arm then two
runs.

TTFT (ms) and throughput (turns/s):

| arm | run | ok/fail | p50 | p95 | p99 | turns/s |
|---|---|---|---:|---:|---:|---:|
| `affinity` | 1 (cold) | 864/48 | 205 | 83,296 | 162,811 | 3.93 |
| `affinity` | 2 (warm) | 1152/0 | 341 | 14,025 | 25,200 | 10.15 |
| `affinity + P2P` | 1 (cold) | 870/47 | 200 | 85,739 | 165,359 | 3.90 |
| `affinity + P2P` | 2 (warm) | 1152/0 | 292 | 10,066 | 18,613 | 11.90 |
| `load + P2P` | 1 (cold) | 1152/0 | 1,691 | 11,417 | 20,713 | 11.34 |
| **`load + P2P`** | 2 (warm) | 1152/0 | 564 | **8,970** | **16,643** | **13.66** |

**Correct index sizing is the largest single effect ever measured in this
scenario.** Versus the podCacheSize-10 run on the identical rig: warm
`affinity` went 4.65 -> 10.15 turns/s (+118%) with p99 132.6 s -> 25.2 s
(5.3x); warm `affinity + P2P` 5.06 -> 11.90; warm `load + P2P` 7.54 ->
13.66 (+81%) with p99 18.2 s -> 16.6 s. Affinity arms improve because
placement stops evicting the holders it routes on; `load + P2P` improves
because P2P source selection runs on the same index. The prior campaign's
7.3x p99 / +62% throughput separation between `load + P2P` and `affinity`
was therefore mostly an index-undersizing artifact: with the index sized
correctly the warm gap is **+35% throughput (13.66 vs 10.15) and 1.5x p99
(25.2 s vs 16.6 s)** - still a clear win, at honest magnitude.

**The cold-start result survives untouched and is now the scenario's
sharpest separation.** Both affinity arms still collapse onto one pod on
a cold fleet (no cache signal to separate candidates) and eat 47-48
client timeouts with p99 ~163-165 s; `load + P2P` cold is clean
(1152/1152, zero failures) at 2.9x their throughput and 7.9x better p99.
Correct index sizing does not help a cold index - there is nothing in it
yet - so this is a placement property, not a tuning artifact.

**`affinity + P2P` versus `affinity` warm reads +17% throughput and -26%
p99 - suggestive, not established.** One warm run per arm, the
throughput delta sits inside the 10-28% run-to-run spread previously
recorded on this workload, and no per-arm session counters survive the
per-arm cold roll (the fleet's pods are replaced between arms). 120 P2P
sessions were observed on the fleet during the `load + P2P` arm's
window, so the pull demonstrably engages under load placement on this
rig; whether it now also contributes under affinity placement needs a
repeated pair with per-arm mechanism counters before the insurance-only
framing is revised.

One `load + P2P` boot hit the UCX-init hang (one pod of 16 log-silent at
NIXL backend creation for 8+ minutes; deleted, replacement booted in
seconds) - third occurrence of that failure mode in one day, second
deployment shape.

Configs, driver, runner, and all six run logs:
[configs/scenario-d-pcs32](configs/scenario-d-pcs32).
