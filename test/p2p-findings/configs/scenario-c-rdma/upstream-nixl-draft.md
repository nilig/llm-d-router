# Two NIXL P/D issue drafts - NOT POSTED

Both reproduce by rolling one role of a P/D pair while the other keeps
running. Shared environment:

- `vllm/vllm-openai:nightly-1240c74c0a47473449cf0c3a9c2d87a1e159f73b`
  (`v0.23.1rc1.dev1502+g1240c74c0`), `nixl_cu13`
- 8 prefill + 8 decode, `openai/gpt-oss-120b`, TP=1 both roles, H200
- `NixlConnector`, `kv_role=kv_both`, `kv_buffer_device=cuda`
- `rdma/ib: 1` on both roles, UCX over `mlx5`

Relevant because a maintainer will ask: `kv_load_failure_policy` is
`Literal["recompute", "fail"]`, default `"fail"`, documented as "immediately
fail the request with an error finish reason". Both options are scoped to a
single request. Neither behavior below is either of them.

---

## Issue 1

**Title**: `NixlConnector: loadRemoteMD failure on a replaced peer kills EngineCore`

A peer's stale remote metadata terminates the local `EngineCore` instead of
failing that peer. Cold-rolling only the prefill Deployment took down all 8
decode engines within 11 seconds:

```
UCX  ERROR   mlx5dv_devx_obj_modify(opcode=0x503) failed, syndrome 0x5d668c: Remote I/O error
  nixl::ucx::rkey::unpackUcpRkey(nixlUcxEp const&, void const*)
  nixl::ucx::rkey::rkey(nixlUcxEp const&, void const*)
  nixlUcxEngine::internalMDHelper(...)
  nixlRemoteSection::addDescList(nixlDescList<nixlBlobDesc> const&, nixlBackendEngine*)
  nixlAgentData::loadRemoteSections(std::string const&, nixlSerDes&)
  nixlAgent::loadRemoteMD(std::string const&, std::string&)
```

Every subsequent request then returns `EngineDeadError`, and the process
exits (`reason=Completed exit=0`), so Kubernetes restarts all 8 pods at once.

Decode was holding remote sections for the prefill agents that had just been
replaced, and loading metadata for the new agents failed at the rkey unpack.
Replacing pods is routine - a rolling update, an eviction, a scale event - so
I think a metadata load failure should mark that peer unusable and leave the
engine serving, rather than propagating out of `loadRemoteMD` and killing the
process. As it stands, rolling one half of a P/D deployment reliably takes
down the other half.

`kv_load_failure_policy` does not cover this: it governs per-request block
loads, and neither `"fail"` nor `"recompute"` describes terminating the
engine.

**Repro**

1. Stand up N prefill + M decode with `NixlConnector`, RDMA available.
2. Serve enough traffic for decode to load remote MD from the prefill agents.
3. `kubectl delete pod -l role=prefill` (or roll the prefill Deployment) and
   leave decode running.
4. Decode engines die as the new prefill agents come up.

---

## Issue 2

**Title**: `NixlConnector: transfer to a disconnected peer hangs the request instead of failing it`

The mirror of Issue 1, on the producer side, and it hangs rather than
crashes. After the decode pods restarted, prefill held stale sections for the
decode agents that had just died and began refusing the new ones:

```
E ucx_utils.cpp:204] UCX AM send failed with status -80 (Endpoint timeout)
ERROR [base_worker.py:2110] NIXL transfer failure: transfer_exception. Marking blocks as invalid
  | Context: {'failure_type': 'transfer_exception', 'request_id': 'cmpl-...',
     'engine_id': '1159ac5c-...', 'remote_engine_id': '0414ddf8-...',
     'remote_host': '10.0.11.136', 'remote_port': 5600,
     'num_local_blocks': 2, 'num_remote_blocks': 2}
  File ".../nixl/base_worker.py", line 2092, in _pop_done_transfers
    xfer_state = self.nixl_wrapper.check_xfer_state(handle)
nixl_cu13._bindings.nixlRemoteDisconnectError: NIXL_ERR_REMOTE_DISCONNECT
```

`10.0.11.136` was a live, Ready prefill pod throughout - its own
`/v1/completions` answered in 0.0s. Nothing crashed and nothing recovered:
every disaggregated request simply blocked until the client timed out.

With `kv_load_failure_policy="fail"` (the default) I would expect these
requests to finish with an error rather than hang, so I think
`NIXL_ERR_REMOTE_DISCONNECT` is not reaching that path. A bounded deadline on
the transfer, surfaced as a request failure, would make this recoverable and
diagnosable.

What makes it expensive to diagnose is that every health signal stays green:
both fleets report Ready, engines answer their own endpoints immediately,
`/v1/models` returns 200 in 0.45s, and only `/v1/completions` hangs. There is
no log line saying the pair is unusable - just the retry above, repeating.

**Repro**: same as Issue 1, then let the crashed role restart while the other
keeps its old agent state. Requests hang indefinitely.

---

## Open questions before I send

- I have not reproduced on vllm main - this rig runs a pinned nightly plus a
  P2P-tier overlay. The two failures are in `NixlConnector` and the NIXL
  bindings, which the overlay does not touch, but worth stating.
- Both roles use the deprecated `kv_role="kv_both"`; the deprecation warning
  fires on this build. Should confirm the same behavior with
  `kv_producer`/`kv_consumer` before filing, since it will be asked.
- The `kv_load_failure_policy` values were read from `v0.23.0`
  (`vllm/config/kv_transfer.py:70`), not from the exact nightly.
