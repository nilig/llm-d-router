# P2P findings — lookup-path request hangs (Defects 3 & 4)

Two request-hang defects in the symmetric-P2P lookup path
(`vllm/v1/kv_offload/tiering/p2p`, `generic_p2p` branch with the
send-late-hashes client fix in the baseline). Full write-up:
`p2p-lookup-hangs.md`.

A rate-dependent fraction of p2p-consumer requests (0.3-4%, grows with load)
hangs in the vLLM waiting queue with `reason="deferred"` until the HTTP
client's timeout, returning zero bytes. Under a staged benchmark each hang
also stalls the stage barrier for the full client timeout, making aggregate
wall time ~4x the offered window while the engines are idle and fast
(mean E2E 1.28s). `vllm:num_requests_waiting_by_reason{reason="deferred"}`
is the live indicator; client-disconnect reaping of a deferred request does
not increment any abort counter.

## Defect 3 — duplicate-fetch session teardown strands in-flight lookups

Per-chunk pulls send more than one `FetchMsg` per `kv_request_id`; the
server treats a second fetch while the first's outbound state is open as a
protocol violation (`malformed 'fetch': duplicate fetch ... - disconnecting`)
and tears down the whole shared session. `P2PSession._do_send` silently
drops messages sent during teardown (returns when `_conn is None`, swallows
send exceptions, no requeue). The dropped lookups stay in-flight forever:
`register_lookup` de-dups against them and the lookup phase has no
consumer-side deadline — the request defers until client timeout. Collateral
damage: any request with in-flight lookups on the torn-down session.

## Defect 4 — pop-on-read MISS livelock

`register_lookup` pops a resolved entry when it is read. A MISS consumed in
a scheduler pass that does not admit the chunk is forgotten and
re-registered as in-flight on the next pass; under fragmented responses
(busy source) the request's hashes never all read resolved within one pass.
Observed live: 6,600-20,500 `LookupMsg` round trips (~85/s) for a single
request, virtually all resolving MISS, until client timeout.

## Reproduce

    python3 repro_lookup_hangs.py             # asserts both defects fire
    EXPECT=fixed python3 repro_lookup_hangs.py  # asserts both fixes hold

Deterministic and in-process: drives the real `ClientRole` / `ServerRole` /
`P2PSession` classes over in-memory connections with stub transport/tiering
(no GPU work, no HTTP, no second process). The scripted sequence is the one
caught live, including the real protocol-error disconnect. Captured runs:
`repro_lookup_hangs_output_unfixed.txt`, `repro_lookup_hangs_output_fixed.txt`.

System-level 2-pod variant (direct `kv_transfer_params.p2p` injection into
`/v1/completions`, no router/EPP/sidecar): `repro_lookup_hangs_2pod.py`.
It verifies the pull path end-to-end; the duplicate-fetch race itself needs
a request whose pull demand splits across two hit-waves while the first
fetch's transfers are queued — common under sustained multi-pod load with
CPU-tier eviction churn, rare on an idle pair, hence the deterministic
in-process repro.

## Fix

`defect34_fix_lookup-deadline-sticky-miss.diff` — one file
(`session/client.py`):

1. Consumer-side lookup deadline (8s = the server's 5s straggler deadline
   plus margin): an in-flight entry past its deadline resolves to MISS, so
   any lost message degrades to a local recompute instead of an infinite
   hang.
2. Sticky MISS until `cancel_lookups` clears the request (HIT stays
   pop-on-read to keep pull-once semantics). Removes the livelock and
   collapses lookup traffic to one `LookupMsg` per request in the common
   case.

Validated end-to-end (rate 6 x 120s, 90s client timeout): unfixed
3 hangs/720 requests, fixed 0/720 with p2p fully engaged (251 pulls, 79%
lookup HIT rate). Not addressed: the duplicate-fetch protocol violation
itself (accumulate fetch demand server-side or aggregate client-side;
disconnecting the shared session on a per-request error is the
amplification step worth removing).

## Files

- `p2p-lookup-hangs.md` — the written report.
- `defect34_fix_lookup-deadline-sticky-miss.diff` — the fix.
- `repro_lookup_hangs.py` — deterministic in-process repro (+ `EXPECT=fixed` mode).
- `repro_lookup_hangs_2pod.py` — 2-pod system-level variant.
- `repro_lookup_hangs_output_unfixed.txt`, `repro_lookup_hangs_output_fixed.txt` — captured runs.
