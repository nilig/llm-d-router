# Upstream vLLM P2P issues: map + coverage

Maps the four filed upstream issues to the two internal defect catalogs
(`p2p-pd-defects.md`, `p2p-lookup-hangs.md`) and states what remains after
each upstream fix lands. All four issues are OPEN as of 2026-07-25.

## The four issues (distinct bugs, distinct layers)

| issue | what it is | layer / file | crash or stall | catalog | fix PR |
|---|---|---|---|---|---|
| #49635 | late KV-offload store after request finalization -> `KeyError` (`_req_state` deleted at `tiering/manager.py:721`, indexed unguarded at `:542` via `scheduler.py:1045 _build_store_jobs`) | OffloadingConnector store path -- NOT P2P-specific | crash | neither catalog | #49671 (open) |
| #49809 | reconnect to a reaped peer trips `AssertionError: ZmqConnection already exists`; dead conn never released | P2P control transport (`tiering/p2p/control/zmq.py`) | crash | pd-defects Defect 2 | #49823 (open) |
| #49820 | symmetric producer accepts a fetch it cannot serve, never sends `TransferDone(success=False)` -> consumer deferred full `_LOAD_TIMEOUT_S=30s` | P2P session (`tiering/p2p/session/*`) | stall | new (post-Liran residual) | none |
| #49829 | `TieringOffloadingManager.lookup()` returns `HIT_PENDING` unconditionally, no deadline, no downgrade-to-MISS | shared tiering manager (`tiering/manager.py`) -- NOT P2P-specific | stall | lookup-hangs Defect 3 | none |

Distinguishing axis: #49635 and #49829 are OffloadingConnector-general (fire
even aggregated / no P2P, different files from each other); #49809 and #49820
are P2P-tier-specific but different sub-layers (control transport vs session).

## Coverage: are those four enough?

Yes, this is now the complete known set. After #49635 (->#49671), #49809
(->#49823), #49820 (->future fix), #49829 (->future fix), and Liran's #48021
all land:

| defect | covered by | patch still needed? |
|---|---|---|
| #49635 finalization crash | #49671 | no |
| #49809 reconnect crash | #49823 | no |
| #49820 symmetric-fetch 30s stall | #49820 fix (TBD) | no, once written |
| lookup-hangs Defect 1 (duplicate-fetch teardown) | Liran's one-fetch contract in #48021 (`dupfetch=0` on a version-matched engine) | no |
| lookup-hangs Defect 2 (pop-on-read MISS livelock) | Liran's `register_lookup` retains resolved HIT+MISS until fetch/finish (no pop-on-read) = the sticky-MISS. VERIFIED in `client.py` @145a460c | no (`defect12` Part 2 redundant) |
| lookup-hangs Defect 3 = #49829 (`HIT_PENDING` write-in-flight, no deadline in `tiering/manager.py`) | #49829 fix (TBD) | no, once written -- `defect3_fix_pending-wait-deadline.diff` validates the direction (deterministic repro: `repro_defect3.py`) |

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

Two crashes fixed (#49635 -> #49671, #49809 -> #49823), and lookup-hangs
Defect 1+2 covered by #48021. Two stalls remain unfixed: #49820 (P2P session,
symmetric fetch) and #49829 (shared tiering manager, `HIT_PENDING`
write-in-flight -- lookup-hangs Defect 3). Both have a documented mechanism, a
deterministic repro, and a validated local patch; neither has an upstream fix
yet.

VERIFIED 2026-07-25 against `main`@70009fb9: `TieringManager.lookup()` still
returns `LookupResult.HIT_PENDING` bare, with no deadline. Upstream added only
observability around it (`secondary_lookup_start_time`, `sync_lookup_delay`
accumulation) -- no bound, no downgrade-to-MISS. So Defect 3 was LIVE in main;
filed as **#49829** (Codex-reviewed, ASCII-only, cc @orozery @ronensc).
`defect3_fix_pending-wait-deadline.diff` is still required until it lands.
