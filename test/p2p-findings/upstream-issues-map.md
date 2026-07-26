# Upstream vLLM P2P issues: map + coverage

Maps the four filed upstream issues to the two internal defect catalogs
(`p2p-pd-defects.md`, `p2p-lookup-hangs.md`) and states what remains after
each upstream fix lands. Status checked 2026-07-26: #49635 CLOSED
(#49671 MERGED); #49809, #49820, #49829 OPEN. Both #49809 and #49829 now
have draft/open fix PRs (#49823, #49850) that we validated and reviewed
directly on GitHub.

## The four issues (distinct bugs, distinct layers)

| issue | what it is | layer / file | crash or stall | catalog | fix PR |
|---|---|---|---|---|---|
| [#49635](https://github.com/vllm-project/vllm/issues/49635) | late KV-offload store after request finalization -> `KeyError` (`_req_state` deleted at `tiering/manager.py:721`, indexed unguarded at `:542` via `scheduler.py:1045 _build_store_jobs`) | OffloadingConnector store path -- NOT P2P-specific | crash | neither catalog | [#49671](https://github.com/vllm-project/vllm/pull/49671) **MERGED** 2026-07-25 |
| [#49809](https://github.com/vllm-project/vllm/issues/49809) | reconnect to a reaped peer trips `AssertionError: ZmqConnection already exists`; dead conn never released | P2P control transport (`tiering/p2p/control/zmq.py`) | crash | pd-defects Defect 2 | [#49823](https://github.com/vllm-project/vllm/pull/49823) open, validated (5 fail stock / 16 pass patched), our review comment posted on the PR directly |
| [#49820](https://github.com/vllm-project/vllm/issues/49820) | symmetric producer accepts a fetch it cannot serve, never sends `TransferDone(success=False)` -> consumer deferred full `_LOAD_TIMEOUT_S=30s`. ROOT CAUSE FOUND 2026-07-26 -- see below | P2P session (`tiering/p2p/session/*`) | stall | new (post-Liran residual) | [#49877](https://github.com/vllm-project/vllm/pull/49877) open, VALIDATED at 3 levels incl. our own GPU repro -- works end-to-end, 1 narrower gap remains -- see below |
| [#49829](https://github.com/vllm-project/vllm/issues/49829) | `TieringOffloadingManager.lookup()` returns `HIT_PENDING` unconditionally, no deadline, no downgrade-to-MISS | shared tiering manager (`tiering/manager.py`) -- NOT P2P-specific | stall | lookup-hangs Defect 3 | [#49850](https://github.com/vllm-project/vllm/pull/49850) DRAFT (author flags end-to-end/scale validation as pending); we validated unit-level and posted 2 confirmed review findings -- see below |
| -- | the generic/symmetric P2P secondary tier itself (peer lookup + serving via `ParentManager`) -- the tier all four bugs above exercise | P2P tier, foundational | -- | -- | [#48021](https://github.com/vllm-project/vllm/pull/48021) open, APPROVED by orozery 2026-07-22, not yet merged (contains the one-fetch contract fixing lookup-hangs Defect 1+2) |

Distinguishing axis: #49635 and #49829 are OffloadingConnector-general (fire
even aggregated / no P2P, different files from each other); #49809 and #49820
are P2P-tier-specific but different sub-layers (control transport vs session).

## Coverage: are those four enough?

Yes, this is now the complete known set. #49635 is already resolved (#49671
merged); after #49809 (->#49823), #49820 (->future fix), #49829 (->future
fix), and Liran's #48021 also land:

| defect | covered by | patch still needed? |
|---|---|---|
| #49635 finalization crash | #49671 MERGED | no -- resolved |
| #49809 reconnect crash | #49823 (open, validated) | no, once merged |
| #49820 symmetric-fetch 30s stall | root cause found (`_OutboundRequestState` shared across rounds), no fix PR yet | no, once written |
| lookup-hangs Defect 1 (duplicate-fetch teardown) | Liran's one-fetch contract in #48021 (`dupfetch=0` on a version-matched engine) | no |
| lookup-hangs Defect 2 (pop-on-read MISS livelock) | Liran's `register_lookup` retains resolved HIT+MISS until fetch/finish (no pop-on-read) = the sticky-MISS. VERIFIED in `client.py` @145a460c | no (`defect12` Part 2 redundant) |
| lookup-hangs Defect 3 = #49829 (`HIT_PENDING` write-in-flight, no deadline in `tiering/manager.py`) | #49850 (open, draft, validated at unit level, 2 open correctness findings) | no, once #49850's findings are addressed and it merges -- `defect3_fix_pending-wait-deadline.diff` validated the direction, but #49850's scheduler-level design supersedes it |

## Root causes resolved 2026-07-26: #49820 and #49829's P2P trigger are the same design gap

Found via a repro run testing whether #49820 survives the best-case combined
stack (`nightly-1240c74c` + Liran's current `#48021` head + `#49823`
overlaid -- verified the current `#48021` head's `manager.py`/`session/*` are
still byte-identical to the `145a460c` pin this repo's analysis is based on).
Result: 0 crashes on that stack (confirms #49635/#49809's signatures are
gone), but #49820 fired 612 times and #49829's P2P trigger (below) fired 13
times in the same run. Full DEBUG logs at `scratchpad/dbg49820/`.

**The unifying design gap:** neither the P2P server's outbound-state tracking
nor the client's load tracking has first-class support for more than one
promotion round in flight per `kv_request_id`. Streaming/growing prefixes
routinely issue 2-3+ sequential lookup-to-fetch rounds under one id (common,
not an edge case) -- and both sides keep exactly ONE mutable slot per id, so
a later round silently clobbers an earlier round's still-live state.

**#49820 (server side):** `ServerRole._requests[kv_request_id].outbound` is
one object per id, not per round. A later round's lookup resolves and calls
`add_stored_blocks()`, which reuses the live object (no check on
`demand_received` or round identity) and appends into its `available` dict.
When the earlier round's transfer completes, `collect_results()` decrements
that same object's `remaining`, hits 0, and `_finalize_outbound()`
unconditionally nulls `st.outbound` -- discarding the later round's
already-pinned `available` entries before its fetch even arrives. The later
`on_fetch()` then creates a fresh empty state; nothing matches; no write is
ever submitted. Posted: https://github.com/vllm-project/vllm/issues/49820#issuecomment-5082854891

**#49829 P2P trigger (client side):** `ClientRole.request_blocks()`
unconditionally overwrites `st.load` -- zero guard for an existing in-flight
load. If promotion job A (many blocks) gets parked by the #49820 bug above,
and before its 30s timeout fires the scheduler starts promotion job B for
the SAME `kv_request_id` (the same multi-round pattern), job B's
`request_blocks()` silently overwrites job A's tracking. The producer's
duplicate-fetch guard then disconnects the session on job B's fetch.
`ClientRole.close()` only ever reports the CURRENT `st.load` (job B) as
failed -- job A is unreachable by any code path. `TieringOffloadingManager`
never gets job A's `JobResult`, never calls `complete_write()` for its keys
-> those primary-tier blocks stay `HIT_PENDING` forever (a genuine, unbounded
instance -- the P2P path orozery asked about). Two leaks confirmed: the
primary-tier block AND the `_transfer_jobs` dict entry itself (only popped
when `get_finished_jobs()` yields that job_id, which never happens here).
Posted: https://github.com/vllm-project/vllm/issues/49829#issuecomment-5083283225

Trace evidence: `kv_request_id=a0169db5-...` (3 rounds, 250/71/179 blocks,
#49820) and `kv_request_id=cb8f34bd-...` (job 253 = 245 blocks parked, job
264 = 1 block same id 1s later, duplicate-fetch disconnect, #49829's
trigger) -- both in `scratchpad/dbg49820/`. 13 duplicate-fetch disconnects
total in the run (grep-counted, matches exactly).

Both comments Codex-reviewed to final; the #49820 comment required two
correction passes (my first draft wrongly credited `add_fetch_demand()`'s
`remaining` overwrite as load-bearing -- the actual mechanism is
`add_stored_blocks()` reusing the live object, verified directly in code);
the #49829 comment was confirmed accurate as posted, no edits needed.

Superseded by PR #49877 below, which independently implements a round-scoped
fix and its own regression test covering this exact scenario.

## PR #49877 (Etelis's fix for #49820): validated at 3 levels, works end-to-end

`https://github.com/vllm-project/vllm/pull/49877`, "Scope serve state to
fetch rounds", opened by `Etelis` (who claimed #49820) hours after the root
cause above was posted. FIX #49820 explicitly: server keeps the current
fetch round and not-yet-fetched supply separate (fixes the shared
`_OutboundRequestState` mechanism); client allows only one `FetchMsg` in
flight per id, queuing extras instead of overwriting `st.load` (fixes the
completion-misattribution mechanism); manager adds a per-request wire-id
suffix for symmetric consumers. Author's own testing: 209 tests passed (10
new), plus a 2xH100 DeepSeek-V2-Lite run (191/192 requests finish vs ~20/192
on main).

**Validated at 3 levels, not just trusted from the PR description:**

1. **Their own test suite, run by us.** Baseline = our `combined_overlay`
   (exactly #48021's current head + #49823, i.e. #49877's actual base --
   NOT stock nightly, which is missing #48021's `LookupMsg`/`LookupRespMsg`
   protocol additions entirely). `test_issue_49820_repro.py`: 8/8 FAIL on
   baseline. Full `tests/v1/kv_offload/tiering/p2p/` with #49877's
   manager.py/client.py/server.py swapped in: **209/209 PASS**, exact match
   to the claimed count.

2. **A new, narrower regression we wrote and ran** (`scratchpad/
   repro_49877_finish_gap.py`), surfacing one remaining gap: `ClientRole.
   finish()` correctly fails every queued fetch, but for the ACTIVE
   `st.load` it sends `AbortFetchMsg`, clears `st.load`, and produces no
   `LoadResult`. The later `AbortAckMsg` then finds nothing to complete.
   `P2PSecondaryTierManager.on_request_finished()` has no alternate
   completion path. Result against #49877's own patched code: zero
   `LoadResult`s produced -- empirically confirmed, not just traced.
   Fix direction (grounded in an existing pattern in the same file): don't
   clear `st.load` immediately in `finish()`; arm `aborted_at` and let the
   same abort-ack/timeout mechanism used elsewhere resolve it. Posted as a
   review comment on the PR.

3. **End-to-end GPU validation, our own workload** (not Etelis's harness).
   Redeployed the same uc2-llama 4-pod rig, same nightly, same hi-rate
   profile as the #49820 repro above, with #49877's patched manager/client/
   server. Result: harness completed both load stages in 4m36s (was 9+ min,
   manually stopped, before); 0 restarts; 0 crash signatures; **0** `#49820`
   stall signatures (was 612); **0** duplicate-fetch disconnects (was 13);
   pull mechanism genuinely engaged (1193 fetch RECEIVED, 262 write_blocks,
   131 transfer_done); **0** collapse snapshots (was frequent); max
   concurrent deferred **12** (was up to 143). Logs: `scratchpad/dbg49877/`.

**Net:** the fix genuinely works, independently verified at three levels.
One narrower, empirically-confirmed gap remains (`finish()` on an active
load), well-scoped with a sound fix direction.

## PR #49850 (fix for #49829): architecture + open findings

Not a manager-level patch like `defect3_fix_pending-wait-deadline.diff` --
scheduler-level (`offloading/scheduler.py`, not `tiering/manager.py`), a
per-request sticky arm/disarm/expire state machine, default 60s (not our 8s),
deliberately sized to clear the P2P session's own
`_LOAD_TIMEOUT_S(30)+_ABORT_ACK_TIMEOUT_S(10)=40s` transfer ceiling with
margin -- our naive 8s could have downgraded a real in-flight P2P pull early.
Configurable (`hit_pending_deadline_s`), new metric
`vllm:kv_offload_hit_pending_deadline_expired`. Validated unit-level on
`nightly-0ba2aa35a`: `test_spec_config.py`'s 10 tests fail stock / pass
patched; a targeted repro (`scratchpad/repro_49850.py`) drives the real
`_update_hit_pending_deadline()` + `_maximal_prefix_lookup()` directly and
confirms arm/expire/disable all work. PR is DRAFT -- author's own
"Verification status" section lists GPU-only stub fixes, end-to-end serving
validation, and a 60s-default-at-scale pool run as still pending (the
5,040/5,040 clean result in the original #49829 report used 8s, not 60s).

Two P2 findings posted as a review comment, both independently verified
against the code (not just taken on faith):
1. **`hit_pending_start_time` is request-wide, not per-key.**
   `_maximal_prefix_lookup` does not `break` on `HIT_PENDING` when not
   downgrading, so one scan can pass through several pending keys; the timer
   resets only when NO key anywhere is pending that pass. If key A (pending
   59s) resolves right as key B becomes newly pending, B inherits A's
   near-expired clock and can wrongly expire ~1s later. Breaks the PR's own
   40s-margin safety argument -- a real correctness bug, not a doc gap.
2. **The 60s default's safety argument is P2P-specific but the config is
   not.** `hit_pending_deadline_s` lives in the shared `OffloadingSpec`
   base, inherited by `CPUOffloadingSpec`/`TieringOffloadingSpec` alike --
   filesystem/object-store writes get the same 60s bound with no equivalent
   40s transfer ceiling backing it. The metric doc's "a non-zero value means
   offload writes are leaking" overclaims for those backends.

Softer gap: `defect12` Part 1 (lookup-phase deadline) is NOT in Liran's branch
-- only `_LOAD_TIMEOUT_S=30` on the fetch phase, no deadline on a stranded
lookup probe. Defense-in-depth: bites only if the one-fetch contract is
violated and a session tears down, stranding a lookup that hangs the full
300s. Latent on a version-matched engine where the contract holds.

## Numbering caveat

Two catalogs both start at "Defect 1", causing collisions:
- `p2p-pd-defects.md`: Defect 1 = cross-TP block identity (upstream
  `file_mapper.py`, vllm#48414); Defect 2 = reconnect crash (= #49809).
- `p2p-lookup-hangs.md`: Defect 1 = duplicate-fetch teardown; Defect 2 = MISS
  livelock; Defect 3 = `HIT_PENDING` no-deadline.

## Net

One crash resolved (#49635, via merged #49671); one crash has an open,
validated fix PR pending merge (#49809 -> #49823, our review comment posted
directly on the PR); lookup-hangs Defect 1+2 covered by #48021 (open,
APPROVED, not yet merged). Both remaining stalls trace to the same design
gap -- no round/generation identifier for multi-round P2P promotions under
one `kv_request_id` (see "Root causes resolved" above). #49820 now has an
open fix PR (#49877) VALIDATED at 3 levels including our own independent GPU
repro -- works end-to-end, one narrower gap remains (see "PR #49877" above).
#49829 has an open draft fix PR with 2 unresolved correctness findings
(#49850). Until #49877 and #49850 both merge (with #49877's finish()-gap
addressed and #49850's findings addressed), these remain the current
load-readiness blockers -- though the core mechanism is now proven fixable
and the fix proven to work under load, which is a materially stronger
position than "root cause known, no fix."

VERIFIED 2026-07-25 against `main`@70009fb9: `TieringManager.lookup()` still
returns `LookupResult.HIT_PENDING` bare, with no deadline. Upstream added only
observability around it (`secondary_lookup_start_time`, `sync_lookup_delay`
accumulation) -- no bound, no downgrade-to-MISS. So Defect 3 was LIVE in main;
filed as **#49829** (Codex-reviewed, ASCII-only, cc @orozery @ronensc).
`defect3_fix_pending-wait-deadline.diff` is still required until it lands.
