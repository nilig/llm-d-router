# P2P findings — evidence bundle

Companion to `p2p-findings.md` (and `presentation.html`, a slide version). Two defects
under load, each reproducible independently. All runs were on unmodified branch code on the
current nightly — 8 of 9 mounted files are byte-identical to the branch; only
`session_client.py` had a local workaround, reverted for these runs. Verified against
`vllm-project/vllm` main, the two have **different owners**: Defect 2 is in the
`generic_p2p` branch; Defect 1 is in upstream vLLM.

## Defect 2 — EngineCore crash (the blocker) · generic_p2p branch

The symmetric-P2P lookup phase (`flush_pending_lookups` + its assert) is a branch addition
— upstream main's `client.py` has no lookup phase or assert. It asserts one `LookupMsg` per
request; chunked prefill / reschedule violates it and the assert kills EngineCore.

- **Reproduce:** deploy unmodified `generic_p2p` branch code, warm one pod with ~300 distinct ~4k-token
  prefixes, pull concurrently from the other 3 (`CONC=80`, ~90s). Pods crash with
  `AssertionError: LookupMsg already sent` at `client.py:237`. Script: `p2p_hang_repro.py`
  (stdlib; drives the concurrent pulls).
- **Fix:** `defect2_fix_send-late-hashes.diff` — remove the assert, allow >1 `LookupMsg`
  per request (send the late hashes). The server queues inbound lookups per-message, so it
  accepts a second `LookupMsg` for the same request. Validated: no crash, p2p still fires.

## Defect 1 — throughput (coordination on the scheduler thread) · upstream vLLM

Once the crash is worked around, p2p is ~2x slower than recompute with the GPU idle
(`Running <= 5`, `KV <= 4%`). The cost is the p2p coordination running synchronously on
the scheduler thread (`manager._poll_once` dispatch + serve + transport poll, plus HIT
deferral) — the async NIXL transfer itself is not the blocker. These pieces
(`_poll_once`, the `_initiate_promotion` deferral in the base `TieringManager`, the
fetch/transfer path) are in **upstream `vllm-project/vllm` main** under
`vllm/v1/kv_offload/tiering`, not introduced by the branch — so the fix is upstream.

Ablation ladder (bench-ws400, rate 16, weighted-random routing):

| build | tok/s |
|-------|-------|
| recompute (off) | 1346 |
| header + inject only (`.p2p`->MISS) | 1358 |
| + lookup round-trip (HIT->MISS) | 1291 |
| + transfer (normal p2p) | 690 |

Adding the lookup costs ~nothing; adding the **pull/promotion** halves throughput.

- **Reproduce:** apply `ablationA_p2p-to-miss.diff` or `ablationB_hit-to-miss.diff` over
  `manager.py`, re-run bench-ws400 p2p-on, compare tok/s and watch `Running`/`KV usage`.
- **Fix direction:** move the p2p data-plane coordination off the scheduler thread onto a
  background thread. Not implemented — architectural, and upstream vLLM (not the branch).

## Files

- `p2p-findings.md` — the written report.
- `presentation.html` — slide version for the team.
- `defect2_fix_send-late-hashes.diff` — the crash fix.
- `ablationA_p2p-to-miss.diff`, `ablationB_hit-to-miss.diff` — the throughput localization.
- `p2p_hang_repro.py` — concurrent-pull driver (triggers the crash on unmodified branch code).
