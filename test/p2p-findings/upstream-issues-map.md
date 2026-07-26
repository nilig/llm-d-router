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
| [#49820](https://github.com/vllm-project/vllm/issues/49820) | symmetric producer accepts a fetch it cannot serve, never sends `TransferDone(success=False)` -> consumer deferred full `_LOAD_TIMEOUT_S=30s` | P2P session (`tiering/p2p/session/*`) | stall | new (post-Liran residual) | none |
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
| #49820 symmetric-fetch 30s stall | #49820 fix (TBD) | no, once written |
| lookup-hangs Defect 1 (duplicate-fetch teardown) | Liran's one-fetch contract in #48021 (`dupfetch=0` on a version-matched engine) | no |
| lookup-hangs Defect 2 (pop-on-read MISS livelock) | Liran's `register_lookup` retains resolved HIT+MISS until fetch/finish (no pop-on-read) = the sticky-MISS. VERIFIED in `client.py` @145a460c | no (`defect12` Part 2 redundant) |
| lookup-hangs Defect 3 = #49829 (`HIT_PENDING` write-in-flight, no deadline in `tiering/manager.py`) | #49850 (open, draft, validated at unit level, 2 open correctness findings) | no, once #49850's findings are addressed and it merges -- `defect3_fix_pending-wait-deadline.diff` validated the direction, but #49850's scheduler-level design supersedes it |

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
APPROVED, not yet merged). One stall has an open draft fix PR with 2 unresolved
correctness findings (#49829 -> #49850). One stall has no PR at all: #49820
(P2P session, symmetric fetch). Until #49850's findings are addressed and it
un-drafts, and until #49820 gets a fix PR, these two are the current
load-readiness blockers.

VERIFIED 2026-07-25 against `main`@70009fb9: `TieringManager.lookup()` still
returns `LookupResult.HIT_PENDING` bare, with no deadline. Upstream added only
observability around it (`secondary_lookup_start_time`, `sync_lookup_delay`
accumulation) -- no bound, no downgrade-to-MISS. So Defect 3 was LIVE in main;
filed as **#49829** (Codex-reviewed, ASCII-only, cc @orozery @ronensc).
`defect3_fix_pending-wait-deadline.diff` is still required until it lands.
