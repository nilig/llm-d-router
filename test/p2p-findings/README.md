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

## Defects 3 & 4 — request hangs in the lookup path · generic_p2p branch

With the Defect-2 fix applied, a rate-dependent fraction of p2p-consumer requests
(0.3-4%, grows with load) hangs in the vLLM waiting queue with `reason="deferred"` until
the HTTP client's timeout, returning zero bytes. Under a staged benchmark each hang also
stalls the stage barrier for the full client timeout, making aggregate wall time ~4x the
offered window while the engines are idle (mean E2E 1.28s). Full write-up:
`p2p-lookup-hangs.md`.

- **Defect 3 — duplicate-fetch session teardown.** Per-chunk pulls send >1 `FetchMsg` per
  `kv_request_id`; the server treats the second as a protocol violation and disconnects
  the whole session; `_do_send` silently drops messages sent during teardown; the dropped
  lookups stay in-flight forever (no consumer-side deadline) — the request defers until
  client timeout. Collateral: any request with in-flight lookups on that session.
- **Defect 4 — pop-on-read MISS livelock.** A resolved MISS is consumed on read and
  re-registered as in-flight on the next scheduler pass; under fragmented responses the
  request's hashes never all read resolved in one pass. Observed live: 6,600-20,500
  `LookupMsg` round trips (~85/s) for a single request until client timeout.
- **Reproduce:** `python3 repro_lookup_hangs.py` — deterministic, in-process (real
  `ClientRole`/`ServerRole`/`P2PSession` over in-memory connections, no GPU work); asserts
  both bugs on unmodified branch code and both fixes with `EXPECT=fixed`. Outputs:
  `repro_lookup_hangs_output_{unfixed,fixed}.txt`. System-level 2-pod variant (direct
  `kv_transfer_params.p2p` injection, no router/EPP/sidecar): `repro_lookup_hangs_2pod.py`.
- **Fix:** `defect34_fix_lookup-deadline-sticky-miss.diff` — one file (`session/client.py`):
  8s consumer-side lookup deadline resolving to MISS (bounds any message loss to a
  recompute) + sticky MISS until `cancel_lookups` (removes the livelock; HIT stays
  pop-on-read to keep pull-once semantics). Validated end-to-end at rate 6 x 120s:
  unfixed 3 hangs/720, fixed 0/720 with p2p fully engaged (251 pulls, 79% lookup HIT
  rate) and lookup traffic collapsed to one `LookupMsg` per request.

## Files

- `p2p-findings.md` — the written report.
- `presentation.html` — slide version for the team.
- `defect2_fix_send-late-hashes.diff` — the crash fix.
- `ablationA_p2p-to-miss.diff`, `ablationB_hit-to-miss.diff` — the throughput localization.
- `p2p_hang_repro.py` — concurrent-pull driver (triggers the crash on unmodified branch code).
- `p2p-lookup-hangs.md` — Defects 3 & 4 write-up (hang mechanics, evidence, validation).
- `defect34_fix_lookup-deadline-sticky-miss.diff` — the hang fix (lookup deadline + sticky MISS).
- `repro_lookup_hangs.py` — deterministic in-process repro for Defects 3 & 4 (+ fix assertion mode).
- `repro_lookup_hangs_2pod.py` — 2-pod system-level variant, direct p2p injection.
- `repro_lookup_hangs_output_unfixed.txt`, `repro_lookup_hangs_output_fixed.txt` — captured runs.
