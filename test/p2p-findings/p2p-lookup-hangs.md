# Two request-hang bugs in the symmetric-P2P lookup path

Scope: `vllm/v1/kv_offload/tiering/p2p` (generic_p2p branch, with the
send-late-hashes client fix applied). Both bugs make a consumer request sit in
the scheduler waiting queue with `reason="deferred"` until the HTTP client
gives up (aiohttp default: 300s), with zero bytes returned. Under a staged
benchmark each hang also stalls the stage barrier for the full client timeout,
which is what made the aggregate numbers look 4x slower - engines are idle and
fast the whole time (mean E2E 1.28s while the "grind" was observed).

## Repro

`repro_lookup_hangs.py` - deterministic, in-process, no GPU work, no HTTP, no
second pod. Drives the real `ClientRole` / `ServerRole` / `P2PSession`
classes with in-memory connections and stub transport/tiering, and asserts
the buggy behavior (or, with `EXPECT=fixed`, the fixed behavior):

    python3 repro_lookup_hangs.py             # asserts both bugs fire
    EXPECT=fixed python3 repro_lookup_hangs.py  # asserts both fixes hold

Output on the unmodified branch:

    scenario1: BUG confirmed (MISS forgotten on read; re-registered +
               LookupMsg re-sent -> livelock seed)
    ERROR ... P2PSession consumer:7777: protocol error: malformed 'fetch':
               duplicate fetch for kv_request_id=req-dupfetch - disconnecting
    scenario2: duplicate fetch -> session disconnected (protocol error)
    scenario2: BUG confirmed (dropped lookup stays in-flight forever ->
               request deferred until client timeout)

The scripted sequence is exactly the one caught live: two FetchMsgs for one
id while the first's transfers are open -> the real protocol-error disconnect
-> a LookupMsg flushed into the dead connection -> `register_lookup` reports
it in-flight forever.

System-level note: on live pods the trigger needs a request whose pull
demand splits across two hit-waves while the first fetch's transfers are
still queued. That straddling is common under sustained multi-pod load with
CPU-tier eviction churn (2 hits per ~330 p2p requests at 6 rps in our rig)
but rare on an idle 1-producer/1-consumer pair - which is why the
deterministic in-process repro is the reliable one. `repro_lookup_hangs_2pod.py` (2
pods, direct `kv_transfer_params.p2p` injection, no router/EPP/sidecar) is
included for the system-level setup; it verifies the pull path end-to-end
and hunts the race probabilistically.

## Bug 1: duplicate FetchMsg tears down the session and strands in-flight lookups

Chain, each link observed in logs on a caught instance:

1. Per-chunk pulls send more than one `FetchMsg` per `kv_request_id` (one per
   prefill chunk with HITs; observed `blocks=76`, then `11`, then `145` for a
   single request). `ServerRole.on_fetch` treats a second fetch while
   `_OutboundRequestState.demand_received` is still set as a protocol
   violation: `malformed 'fetch': duplicate fetch for kv_request_id=... -
   disconnecting`. The whole shared session is torn down, not just the
   offending request.
2. Messages sent during teardown are silently dropped: `P2PSession._do_send`
   returns when `_conn is None` and swallows send exceptions with no requeue.
   Observed: consumer logged 6 `LookupMsg` sends, producer received 2, zero
   "failed to send" warnings. The post-reconnect flush only covers messages
   queued after `_send_ready` flipped false.
3. The dropped lookups are never re-sent: their `_lookups` entries stay `None`
   ("in-flight") and `register_lookup` de-dups against them on every
   subsequent call. The lookup phase has no consumer-side deadline (by design:
   "There is no timeout"), so the request defers forever. Any other request
   with in-flight lookups on the same session hangs the same way (collateral).

The `assert req_id not in self._flushed_req_ids` that the send-late-hashes fix
removed was the client-side face of the same contract violation; removing it
moved the failure to the server-side disconnect.

## Bug 2: pop-on-read MISS livelock

`register_lookup` pops a resolved entry when it is read. A MISS consumed
during a scheduler pass that does not admit the chunk is forgotten; the next
pass re-registers the same hash, which makes it in-flight (RETRY) again. When
responses arrive fragmented (busy source: the server batches per step and
holds stragglers up to `_LOOKUP_PENDING_TIMEOUT_S`), the request's hashes
never all read "resolved" within one pass, and the request livelocks:
observed 6,600-20,500 `LookupMsg` round trips for a single request
(~85/second, virtually all resolving MISS) until the client timeout. Present
with and without Bug 1's fix; frequency scales with source busyness, which is
why higher request rates showed more hangs.

## Fix (validated): `defect34_fix_lookup-deadline-sticky-miss.diff`, one file (`session/client.py`), ~30 lines

1. Consumer-side lookup deadline (8s = server's 5s straggler deadline plus
   margin): an in-flight entry past its deadline resolves to MISS, so any
   lost message degrades to a local recompute instead of an infinite hang.
2. Sticky MISS: a resolved MISS keeps answering MISS until `cancel_lookups`
   clears the request (HIT keeps pop-on-read - consuming a HIT triggers the
   one-time pull). This removes the livelock and, as a side effect, collapses
   lookup traffic to one `LookupMsg` per request in the common case.
   Expired entries become sticky MISS for the same reason. A late
   `LookupRespMsg` can still upgrade a sticky MISS to HIT before the next
   read.

Validation (same rig, rate 6 x 120s, 90s client timeout, three consecutive
configurations):

| build            | sent | hangs | max lookup msgs per request | p2p activity |
|------------------|------|-------|-----------------------------|--------------|
| unfixed          | 720  | 3     | 20,541                      | engaged      |
| deadline only    | 720  | 11*   | 15,781                      | engaged      |
| deadline+sticky  | 720  | 0     | 1                           | 317 injections, 251 pulls, 79% HIT |

*The deadline alone rescues Bug 1 (the one session teardown in that run
produced one expiry-to-MISS and no loss hang) but cannot rescue Bug 2, whose
entries each resolve well inside the deadline - that run's hangs were all
livelocks (run-to-run variance in livelock count is high).

Not addressed here: the duplicate-fetch protocol violation itself. Options are
accumulating fetch demand server-side (multi-fetch per id) or aggregating
fetches client-side; either way, disconnecting the shared session on a
per-request protocol error is the amplification step worth removing -
`_do_send` also needs to fail or re-send in-flight messages on teardown
rather than dropping them silently. With the client-side fixes above, the
worst case of a duplicate-fetch teardown is bounded at one 8s deferral
followed by recompute.

Diagnostics that made this visible, for future use:
`vllm:num_requests_waiting_by_reason{reason="deferred"}` is the live hang
indicator (note: client-disconnect reaping of a deferred request does not
increment any abort counter). The server logs `RECV LookupMsg` /
`SEND LookupRespMsg` per id at DEBUG; counting `RECV` per `kv_request_id`
exposes the livelock without any instrumentation.
