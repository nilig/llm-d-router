# P2P defects found bringing up source-pull under P/D disaggregation

Defects surfaced standing up the P2P source pull under prefill/decode
disaggregation (gpt-oss-120b, `always-disagg`, TP=1 prefill + TP=4 decode,
`MultiConnector(NixlConnector + OffloadingConnector[p2p tier])`, sidecar
`--enable-p2p-pull`). Defect 1 is a block-identity property shared by the p2p
and fs secondary tiers; defect 2 is in the p2p control transport
(`tiering/p2p/control/zmq.py`); defect 3 is a consumer-side session-lifecycle
race. Separate from the pull-path request hangs in
[p2p-lookup-hangs.md](p2p-lookup-hangs.md).

Context for all three: the pull mechanism itself is proven working between
same-TP roles. A standalone test (`pd-direct-pull-test.sh` - no EPP, no
sidecar, no benchmark harness: warm one decode engine with an 8K input prompt,
send the same prompt to a prefill engine with hand-injected
`kv_transfer_params.p2p = {kv_request_id, remote_host, remote_port}`, the
exact shape `pkg/sidecar/proxy/connector_p2p.go` injects) pulls the full 8,000
tokens (285 MB) from the decode tier in 0.1 s against a 3.3 s local-compute
reference - once the peer session is established. The defects below are what
break it around the edges.

## Defect 1: KV block identity is TP-dependent, so cross-TP sharing is refused by both secondary tiers

Symptom: under the P/D topology above, every prefill engine repeatedly logs
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
goal, the connector should at least fail the pull cleanly (see Defect 2) and
the router should avoid emitting a cross-TP source header, since the pull can
never succeed.

Repro: `llama-fs-crosstp.yaml` (the two TP pods) + `llama-fs-test.sh` (warm,
cross-read, on-disk hash-dir dump).

## Defect 2: a rejected/flapping peer connection trips a reconnect assert that kills EngineCore

The Defect 1 fingerprint rejection is not merely a missed pull - under load it
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
whether from a cross-TP fingerprint reject (Defect 1) or ordinary transport
churn - degrades to "no pull, local recompute" instead of taking the whole
EngineCore down. This is worth fixing independently of the cross-TP question:
today any peer-connect instability is a fleet-wide crash rather than a graceful
fallback.

## Defect 3: cold-session race - the first request to a new peer always misses

The first pull request naming a never-contacted peer establishes the P2P
session and runs its block lookup concurrently. The lookup finds the session
not yet ready, the consumer logs `manager.py:656 P2P ...: peer <peer>:7777
down`, and the request silently recomputes - while the source side logs a
clean `accepting incoming connection` / `created connected session` for the
same instant. Any subsequent pull over the now-established session works
perfectly (the 0.1 s / 8,000-token result above was request number two; request
number one against the same warm source recomputed at full cost).

Consequence: with lazily-formed sessions, every (consumer, source) pair pays
one full recompute on first contact. A fleet of P prefills and D decodes under
a scatter-heavy router burns P x D warmup misses, and any peer restart (pod
churn, reclaim) resets its pairs. Fix direction: the lookup path should wait
briefly (bounded, e.g. the session-connect timeout) for a session in
CONNECTING state instead of classifying it down - or the manager should
pre-establish sessions to discovered peers rather than on first use.

Related robustness note, reconfirmed while testing: a pull naming a dead peer
(pod deleted between header emission and arrival) hangs the request for 40+ s
rather than degrading to recompute - the missing consumer-side lookup deadline
already filed as defects 1-2 in [p2p-lookup-hangs.md](p2p-lookup-hangs.md).
