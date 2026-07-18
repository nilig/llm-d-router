# Defects in the KV-offload pull path

Defects 1-3 are request hangs in the pull path; defects 4-5 are cross-TP
sharing limits and a peer-connect crash found bringing P2P up under P/D
disaggregation.

Scope: defects 1 and 2 are in `vllm/v1/kv_offload/tiering/p2p` (generic_p2p
branch, with the send-late-hashes client fix applied); defect 3 is in the
upstream tiering manager (`vllm/v1/kv_offload/tiering/manager.py`); defect 4 is
a block-identity property shared by the p2p and fs secondary tiers; defect 5 is
in the p2p control transport (`tiering/p2p/control/zmq.py`). Both bugs make a consumer request sit in
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

## Defect 1: duplicate FetchMsg tears down the session and strands in-flight lookups

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

## Defect 2: pop-on-read MISS livelock

`register_lookup` pops a resolved entry when it is read. A MISS consumed
during a scheduler pass that does not admit the chunk is forgotten; the next
pass re-registers the same hash, which makes it in-flight (RETRY) again. When
responses arrive fragmented (busy source: the server batches per step and
holds stragglers up to `_LOOKUP_PENDING_TIMEOUT_S`), the request's hashes
never all read "resolved" within one pass, and the request livelocks:
observed 6,600-20,500 `LookupMsg` round trips for a single request
(~85/second, virtually all resolving MISS) until the client timeout. Present
with and without Defect 1's fix; frequency scales with source busyness, which is
why higher request rates showed more hangs.


## Defect 3: unbounded wait on write-in-flight primary-tier blocks

With the defect 1/2 fixes in place a residual ~0.2% of requests still hung to
the client timeout, with no p2p-path trace of their own: no unresolved
lookup, no expiry, no session event. Their engine-side signature was a spin -
the scheduler re-calling the connector's lookup at ~200 calls/s for the whole
wait (worst observed: 1,270,000 calls from one request; at 10 req/s, 551 of
1,800 requests spun past 2,000 calls).

Instrumenting the upstream tiering manager's `lookup()` showed every spinning
request wedged on a key whose primary-tier state is `HIT_PENDING`: a CPU-tier
block whose write - a GPU-to-CPU save or a secondary-tier promotion - is
still in flight. `lookup()` short-circuits `HIT_PENDING` with no deadline,
and the scheduler re-polls pending blocks in a hot loop. When the owner job
is slow (busy tier) the waiter burns scheduler-thread time until it resolves;
when the owner job is leaked (session-teardown corners), the slot never
resolves and every request touching that key hangs until its HTTP client
gives up. The victim and the leak are separated in time - the wedged key
belongs to an earlier request's write - which is why these hangs carry no
trace of their own.

Fix (`defect3_fix_pending-wait-deadline.diff`, upstream
`tiering/manager.py`): an 8s deadline per (request, key) on the pending wait;
past it the block is treated as MISS for that request, so it recomputes, and
secondary tiers are not consulted for the downgraded key (the block is
mid-write locally; pulling it again would collide). Validated: the 64x16K
shared-prefix pool at 4-24 req/s completes cleanly for the first time -
5,040/5,040 requests, zero failures, zero restarts - where every previous
attempt lost requests to this hang. A production version should also clear
the deadline map on request finish, and the hot re-poll loop deserves an
upstream backoff independent of the deadline.

## Fix for defects 1 and 2 (validated): `defect12_fix_lookup-deadline-sticky-miss.diff`, one file (`session/client.py`), ~30 lines

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

*The deadline alone rescues Defect 1 (the one session teardown in that run
produced one expiry-to-MISS and no loss hang) but cannot rescue Defect 2, whose
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

---

## Defect 4: KV block identity is TP-dependent, so cross-TP sharing is refused by both secondary tiers

Symptom: under P/D with `always-disagg`, TP=1 prefill + TP=4 decode,
`MultiConnector(NixlConnector + OffloadingConnector[p2p tier])` and the sidecar
`--enable-p2p-pull`, every prefill engine repeatedly logs
`session.py:443 P2PSession: rejecting peer connect: config fingerprint
mismatch from <peer>:7777` against - and only against - the decode pods. No
prefill-to-prefill rejects. So a prefiller can never pull the session's history
from the decode tier; the P2P source pull only ever forms between same-TP
peers.

This is not a P2P-session quirk - it is a property of the block identity.
Isolation, stripped to the KV layer (no P2P, no NIXL, no router): two plain
aggregated `Llama-3.1-8B` pods, **TP=1 and TP=2**, identical config except the
TP degree, both running `OffloadingConnector` with a **filesystem** secondary
tier (`type: fs`) on a shared RWX PVC. Warm an 8K-token prefix on the TP=2 pod
(it offloads to the shared fs), then read the same prefix on the TP=1 pod:

- Cross-TP read loads **0 bytes** (`vllm:kv_offload_load_bytes` delta 0).
- On-disk, the fs tier suffixes its `root_dir` with a config hash, and the two
  pods (differing only in TP) wrote their blocks into separate directories:
  `..._00c6847f171a_r0` and `..._a37a3f237f7f_r0`, 123 blocks each. A TP=1 pod
  reads its own hash directory and never sees the TP=2 pod's blocks.

So both secondary tiers enforce the same TP boundary via different mechanisms -
the P2P tier through the session config fingerprint, the fs tier through the
config-hash directory namespace. The root cause is that the offloaded block's
layout/identity depends on the tensor-parallel degree (KV heads are sharded per
TP), so a block written under one TP is not the same block under another.

Consequence for llm-d P/D + P2P: "a prefiller pulls session history from the
decode tier" is unavailable whenever prefill and decode run different TP, which
the P/D guide topology (8x TP=1 prefill + 2x TP=4 decode) always does.

Open question, not a fix: is TP-invariant cross-TP KV reuse a goal? It would
need a TP-invariant block representation, or a re-layout on read/write across
the TP boundary - a larger change than the fingerprint check. If it is not a
goal, the connector should at least fail the pull cleanly (see Defect 5) and
the router should avoid emitting a cross-TP source header, since the pull can
never succeed.

Repro: `llama-fs-crosstp.yaml` (the two TP pods) + `llama-fs-test.sh` (warm,
cross-read, on-disk hash-dir dump).

## Defect 5: a rejected/flapping peer connection trips a reconnect assert that kills EngineCore

The Defect 4 fingerprint rejection is not merely a missed pull - under load it
crashes the engine. The reject -> reconnect -> `manager.py:656 peer down` churn
against the same peer eventually races the connection map:

```
zmq.py:131  AssertionError: ZmqConnection to <peer>:7777 already exists
  -> EngineCore encountered a fatal error -> EngineDeadError -> pod restart
```

Observed: 7 of 8 prefill pods dead, 916 of 1152 requests failed in a single
run. `connect()` asserts `peer_id not in self._connections`, but a reconnect
after a rejected/dropped peer races an existing (half-open) entry and trips it.

Fix direction: `connect()` should reuse or replace an existing `ZmqConnection`
(or take a per-peer lock) rather than asserting, so a peer that keeps flapping -
whether from a cross-TP fingerprint reject (Defect 4) or ordinary transport
churn - degrades to "no pull, local recompute" instead of taking the whole
EngineCore down. This is worth fixing independently of the cross-TP question:
today any peer-connect instability is a fleet-wide crash rather than a graceful
fallback.
