# P2P defects found bringing up source-pull under P/D disaggregation

Defects surfaced standing up the P2P source pull under prefill/decode
disaggregation (gpt-oss-120b, `always-disagg`, TP=1 prefill + TP=4 decode,
`MultiConnector(NixlConnector + OffloadingConnector[p2p tier])`, sidecar
`--enable-p2p-pull`). Defect 1 is a block-identity property shared by the p2p
and fs secondary tiers; defect 2 is in the p2p control transport
(`tiering/p2p/control/zmq.py`). Separate from the pull-path request hangs in
[p2p-lookup-hangs.md](p2p-lookup-hangs.md).

Context for both: the pull mechanism itself is proven working between
same-TP roles. A standalone test (`pd-direct-pull-test.sh` - no EPP, no
sidecar, no benchmark harness: warm one decode engine with an 8K input prompt,
send the same prompt to a prefill engine with hand-injected
`kv_transfer_params.p2p = {kv_request_id, remote_host, remote_port}`, the
exact shape `pkg/sidecar/proxy/connector_p2p.go` injects) pulls the full 8,000
tokens (285 MB) from the decode tier in 0.1 s against a 3.3 s local-compute
reference. This holds from the very first contact between a cold pair:
`pd-direct-pull-output-cold.txt` captures a verified-cold pair (decode
with zero accepted connections, prefill `ext_hits=0`) pulling the full prompt
on request one, the session created mid-request - the session client parks
the lookup as a pending entry and sends it once the handshake completes
(`session/client.py` + `flush_pending_lookups`). The defects below are what
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
config-hash directory namespace.

Resolution of the root cause (upstream `file_mapper.py`,
`FileMapper.from_offloading_spec`): cross-TP sharing is implemented, not
impossible - the fingerprint is built `parallel_agnostic=True` (tp/pp/rank
collapse out) - but the mode is demoted to TP-locked when any of three
conditions holds: the V2 model runner is in use (its KV layout is not known
to be parallelism-invariant), the KV cache config has more than a single
full-attention group, or the model uses MLA. Both models in the tests above
happened to be excluded, one per clause: gpt-oss-120b interleaves
sliding-window and full attention (multiple KV groups) and so is TP-locked
even on the V1 runner it uses, and Llama-3.1-8B runs the V2 model runner on
this build (`gpu_worker: Using V2 Model Runner`). Upstream confirms the support statement: hetero-TP is supported for
non-hybrid models on the V1 model runner only, and models that default to
the V2 runner must be forced back with `VLLM_USE_V2_MODEL_RUNNER=0`.
Runner selection verified by probe on this build: gpt-oss-120b and
Qwen3-30B-A3B initialize on the V1 runner, Llama-3.1-8B on V2. The matrix
here: gpt-oss never (hybrid attention); Llama-3.1-8B eligible if forced
to MRV1; Qwen3-30B-A3B eligible as-is. Untested validations: rerun the
fs isolation on Llama with `VLLM_USE_V2_MODEL_RUNNER=0`, or a Qwen
cross-TP pair as-is.

Consequence for llm-d P/D + P2P: "a prefiller pulls session history from the
decode tier" is unavailable whenever prefill and decode run different TP, which
the P/D guide topology (8x TP=1 prefill + 2x TP=4 decode) always does.

Open items: extending the parallel-agnostic mode to the V2 model runner and
to multi-group attention layouts (the two exclusions that bit here), and -
wherever a deployment falls in an excluded configuration - failing the pull
cleanly (see Defect 2) and having the router avoid emitting a cross-TP
source header, since the pull cannot succeed there. On the first item,
[vllm#48414](https://github.com/vllm-project/vllm/pull/48414) (stacked on
#48408) is in flight: it stores offloaded KV in a canonical
parallelism-free layout - one copy per block, no parallelism inputs in the
transfer path - and fails uncertifiable configs at startup instead of
silently demoting.

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

Related robustness note, reconfirmed while testing: a pull naming a dead peer
(pod deleted between header emission and arrival) hangs the request for 40+ s
rather than degrading to recompute - the missing consumer-side lookup deadline
already filed as defects 1-2 in [p2p-lookup-hangs.md](p2p-lookup-hangs.md).
