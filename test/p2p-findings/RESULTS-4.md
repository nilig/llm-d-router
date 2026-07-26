# P2P benchmarks, series 4: UC2 lookup-hang resolved; UC3/UC4 re-validation

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
2. **Prefill pods were missing their own routing-proxy sidecar.** Built
   prefill as a bare engine on port 8200 (matching the ad-hoc
   `llama-pd.yaml` reference rig, which is curl-driven with no EPP). But the
   *decode* sidecar's NIXL P/D handler always dials the prefill peer on port
   8000, expecting every model-server pod — prefill included — to run its
   own routing-proxy in front of the engine, uniformly. Without it: `dial
   tcp <prefill-ip>:8000: connect: connection refused`, every request 502.
   Fixed by adding the same `routing-proxy` init-container pattern to
   prefill (port 8000 → engine 8200, no `--enable-p2p-pull` needed there —
   only the leg that *initiates* a pull needs that flag).

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
UC3 lessons preemptively (routing-proxy sidecar on both roles; shm sized
above `cpu_bytes_to_use`) — this rig came up clean on the first deploy,
no repeat of UC3's two bugs. Manifests:
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
