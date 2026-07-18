# P2P under P/D disaggregation: cross-TP KV sharing is blocked

This file records the P/D-disaggregation P2P experiment, separate from the
aggregated results in [RESULTS.md](RESULTS.md) and
[RESULTS-2.md](RESULTS-2.md). The headline is a mechanism finding, not a
performance number: **KV block identity is tensor-parallel-degree-dependent
in the vLLM `OffloadingConnector`, so cross-TP KV sharing is refused by both
secondary tiers (P2P and filesystem).** Under the P/D guide topology (TP=1
prefill, TP=4 decode) this means a prefiller cannot pull a cached prefix from
the decode tier - the exact mechanism the P/D P2P story depends on. Source
pull works only between same-TP peers.

## Goal

Answer whether adding P2P to the P/D disaggregation guide is "only better,
never worse": guide verbatim (arm A) vs guide + P2P (arm B), where arm B adds
the pull with placement and scorers unchanged. The intended win is turn N+1's
prefill pulling the session's history from the decode tier instead of
recomputing it.

## Hardware and software

Same rig family as the aggregated results (see [RESULTS.md](RESULTS.md)):
16x H200 (kermit), `openai/gpt-oss-120b` MXFP4, vLLM nightly + the
`generic_p2p` `OffloadingConnector` branch mounted, `block-size` 64 and
`PYTHONHASHSEED` pinned fleet-wide. P/D topology from the pd-disaggregation
guide: `always-disagg-pd-decider`, prefill profile prefix 3 / queue 2 / kv 2,
decode profile active-request 2 / prefix 3. Workload: the document-Q&A profile
(192 docs x 48K tokens, 6 turns, 256-token answers, 128 concurrent). The
isolation test below used `meta-llama/Llama-3.1-8B-Instruct` for fast
iteration - the connector behavior is model-independent.

## Arm A (guide verbatim): baseline

Plain `NixlConnector` for the P/D transfer, no offloading tier, EPP as the
guide ships it. Two topologies measured.

| topology | TTFT p50 / p95 / p99 (s) | throughput | failures |
|---|---|---|---|
| 8 prefill (TP=1) + 2 decode (TP=4) | 0.92 / 73.8 / 158.6 | 3.22 turns/s | 16 |
| 8 prefill (TP=1) + 8 decode (TP=1) | 24.7 / 33.7 / 65.7 | 4.34 turns/s | 0 |

The 8x-decode-TP1 variant has a tighter tail (p99 65.7 vs 158.6 s) because
eight decode engines absorb the 128-concurrent load where two TP=4 engines
queue. Both are clean baselines; arm B never completed a paired run (below),
so these stand alone rather than as an A/B.

Note on pull-evidence metrics under P/D: `vllm:external_prefix_cache_hits_total`
is **not** a P2P-pull signal here - the decode leg receiving the prefill's KV
over NIXL registers as an external prefix-cache hit, so that counter is
dominated by the normal PD transfer. P2P-pull evidence must come from the EPP
`set KV cache source header` count and the offloading connector's
`kv_offload_load_bytes` (CPU->GPU), not from ext-hits.

## Arm B (guide + P2P): crashes on cross-TP peer connect

Engines run `MultiConnector(NixlConnector + OffloadingConnector)` with a P2P
secondary tier, the routing sidecar runs `--kv-connector=nixlv2
--enable-p2p-pull`, and the EPP adds the precise index + `p2p-source-producer`
(`prefillProfileName: prefill`). Placement scorers unchanged from arm A.

Under load, 7 of 8 prefill engines crash. Root cause chain from the engine log:

```
session.py:443  P2PSession: rejecting peer connect: config fingerprint mismatch from <peer>:7777
  -> repeated reject / reconnect / "peer down" churn (manager.py:656)
  -> zmq.py:131  AssertionError: ZmqConnection to <peer>:7777 already exists
  -> EngineCore fatal error -> prefill pod restarts
```

Every prefill (TP=1) pod rejects **exactly the two decode (TP=4) IPs** on
config fingerprint mismatch, and no prefill-to-prefill rejects. So same-TP
peers connect; cross-TP peers do not.

## Isolation 1: uniform `cpu_bytes` still fails -> not a config-size issue

To rule out my per-role CPU-tier sizing as the cause, I set both roles to an
identical `cpu_bytes_to_use` (128 GiB) and did a clean scale-to-zero-then-up
re-roll so every pod carried identical config. The fingerprint mismatch
persisted, still only prefill(TP=1) <-> decode(TP=4). So the mismatch is not
`cpu_bytes` - it tracks the TP difference.

## Isolation 2: the filesystem tier is TP-locked too -> general, not P2P-specific

The decisive test, stripped to the KV layer: two plain aggregated
`Llama-3.1-8B` pods, **TP=1 and TP=2**, identical config except the TP degree,
both running `OffloadingConnector` with a **filesystem** secondary tier
(`type: fs`) on a shared RWX PVC - no P2P, no NIXL, no router. Warm an 8K-token
prefix on the TP=2 pod (it offloads blocks to the shared fs), then read the
same prefix on the TP=1 pod.

Result: **zero fs load on the cross-TP read** (`kv_offload_load_bytes` delta
0). The on-disk layout shows why - the fs tier suffixes its `root_dir` with a
config hash, and the two pods (differing only in TP) wrote their blocks into
**separate directories**:

```
meta-llama_Llama-3.1-8B-Instruct_00c6847f171a_r0   123 block files
meta-llama_Llama-3.1-8B-Instruct_a37a3f237f7f_r0   123 block files
```

Both wrote 123 blocks; a TP=1 pod reads its own hash directory and never sees
the TP=2 pod's blocks. The filesystem tier - the other cross-pod KV-sharing
mechanism - refuses cross-TP sharing by the same root cause as the P2P
fingerprint, via a different implementation.

## Conclusion

KV block identity/layout is **tensor-parallel-degree-dependent** in the
`OffloadingConnector`. Both secondary tiers enforce it:

- **P2P tier**: peer connect rejected on `config fingerprint mismatch`.
- **Filesystem tier**: blocks namespaced into a TP-dependent config-hash
  directory, so cross-TP reads never find them.

Practical consequence for llm-d P/D + P2P: **source pull works only between
same-TP peers** (prefill <-> prefill), never prefill <-> decode when their TP
differs - which the guide topology (8x TP=1 prefill + 2x TP=4 decode) always
does. The "prefiller pulls session history from the decode tier" mechanism is
unavailable on this build.

## Open items for the connector

1. **Is TP-invariant cross-TP KV reuse a goal?** If so it needs a TP-invariant
   block representation (or a re-layout on read), a larger change than relaxing
   the P2P fingerprint.
2. **Robustness bug, worth fixing regardless**: the reject -> reconnect churn
   trips `zmq.py:131 AssertionError: ZmqConnection already exists`, which kills
   EngineCore rather than degrading to a local recompute. `connect()` should
   reuse/replace an existing connection (or lock per-peer) so a flapping peer
   never takes the engine down.

## Still open on the value question

The P/D P2P value question is narrowed, not answered: only **same-TP** P/D
(prefill <-> prefill pulls) can run today. That measures whether a fresh
prefill pulling a prefix another prefill already computed beats recomputing it
- a real but narrower claim than prefill-from-decode. Not yet run.

Reproduction scripts (scratchpad): `pd-gptoss.yaml`, `pd-armswitch.sh`,
`pd-run.sh`, `epp-pd-{a,b}-*.yaml` (the A/B), `llama-fs-crosstp.yaml` +
`llama-fs-test.sh` (the fs isolation).
