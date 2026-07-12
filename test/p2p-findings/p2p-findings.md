# generic_p2p under load: two connector defects, evidence, and fixes

Two defects surface when the p2p connector runs under concurrent load. Both were
reproduced against **unmodified `generic_p2p` branch code** on the current nightly — 8 of
the 9 mounted files (including `manager.py`) are byte-identical to the branch; only my
local `session_client.py` carried a workaround, which I reverted for these runs.

The router (EPP producer + sidecar) is exonerated by ablation. Within the connector the two
defects have **different owners**, verified against `vllm-project/vllm` main:

- **Defect 2 — `EngineCore` crash. In the `generic_p2p` branch.** The symmetric-P2P lookup
  phase (`flush_pending_lookups` and its assert) is a branch addition — upstream main's
  `client.py` is 210 lines with no lookup phase and no assert; the branch's is 378. It
  asserts one `LookupMsg` per request; chunked prefill / reschedule violates that, and the
  assert takes down `EngineCore`. The first blocker — p2p can't run under load without it.
- **Defect 1 — throughput. In upstream vLLM.** Once the crash is worked around, p2p is ~2x
  slower than recompute with the GPU idle. The cost is the data-plane **coordination on the
  scheduler thread** (`_poll_once`, the `_initiate_promotion` deferral in the base
  `TieringManager`, the fetch/transfer path) — all in upstream `vllm/v1/kv_offload/tiering`,
  present in main. The branch runs within this architecture; it does not introduce it. So
  the fix is an upstream concern affecting anyone using the KV-offload p2p tier.

## Test setup

- 4 vLLM pods, `generic_p2p` branch on nightly `vllm/vllm-openai:nightly-2afa3f7e...`:
  `OffloadingConnector` + p2p secondary tier on `:7777`, 32 GiB CPU tier, Llama-3.1-8B,
  `--block-size=64`, 1 GPU (H200) each.
- Concurrent-pull hammer (bare vLLM, no router): warm one pod past its GPU cache
  (offload to the servable CPU tier), then 60-80 workers pull from it, 90-150s.
- Benchmark (for Defect 1): inference-perf `bench-ws400` — shared-prefix, 400 groups
  x 16 prompts, 2048-token prefix, rate 16 req/s, 200s, weighted-random routing so
  requests land on non-owner pods and p2p fires.

---

## Defect 2 — `EngineCore` crash on concurrent double-flush

### The assert

`session/client.py`, `flush_pending_lookups`:

```python
assert req_id not in self._flushed_req_ids, (
    f"LookupMsg already sent for kv_request_id={req_id}"
)
```

It encodes the documented invariant *"at most one `LookupMsg` per kv_request_id …
no new unsent entries can accumulate for a req_id after its first flush."* That
invariant does **not** hold under load: with **chunked prefill** (a request's blocks
get registered across several scheduler steps) or a **reschedule/preemption**, a
`req_id` comes back in `_unsent_lookups_by_req` after its first flush. The assert then
fires and kills `EngineCore`.

### Reproduced (unmodified branch code, concurrent hammer)

`CONC=80` hammer, 4 pods on unmodified `generic_p2p` branch code. **2 of 4 pods crashed
and restarted**, each with:

```
File ".../p2p/session/session.py", line 218, in flush_pending_lookups
    self._client.flush_pending_lookups()
File ".../p2p/session/client.py", line 237, in flush_pending_lookups
AssertionError: LookupMsg already sent for kv_request_id=hp-28315-530649165
```

### Fix (validated)

Handle the second flush instead of asserting: **send the late hashes** — allow more
than one `LookupMsg` per request. The change is 3 lines — remove the assert
(`defect2_fix_send-late-hashes.diff`). The server already queues inbound lookups
per-message (`_pending_inbound_lookups` is a list, each gets its own `lookup_id`), so it
accepts the second `LookupMsg` for the same `kv_request_id`.

Validated on the fix build under the same 80-way hammer: **0 crashes** (vs 2 of 4 pods
on unmodified branch code), no new errors/tracebacks, and p2p still fires and serves (152 hits, 142
transfers, 52 loads, 0 failures). Worth a second look on your side that accumulating a
second `LookupMsg` per request has no downstream assumption I missed, but it holds
empirically.

---

## Defect 1 — throughput: p2p coordination on the scheduler thread

### Symptom

With p2p on, throughput is ~2x lower than recompute and the GPU is **idle** the whole
run (`Running <= 5 reqs`, `GPU KV cache usage <= 4%`). Not compute-bound, not
KV-bound — requests are not being admitted to the GPU.

### Localization — ablation ladder

Each row keeps more of the p2p path (patches to `manager.py`'s `lookup`).

| build | EPP header + sidecar inject | lookup round-trip | pull / promotion | tok/s |
|-------|------|------|------|-------|
| recompute (off) | - | - | - | 1346 |
| Ablation A (`.p2p`->MISS) | yes | - | - | 1358 |
| Ablation B (lookup, HIT->MISS) | yes | yes (1050 lookups ran) | - | 1291 |
| p2p normal | yes | yes | yes | 690 |

The EPP header + sidecar cost nothing (A ~= off). The full lookup round-trip costs ~
nothing (B, with 1050 lookups resolving). The **pull/promotion** halves throughput
(B -> normal). Also ruled out: `_LOAD_TIMEOUT_S` aborts = 0; GPU compute (idle).

### Root cause (code)

The NIXL data movement is async — `NixlTransport.write_blocks` submits and returns;
`poll()` only checks state. The cost is the **coordination**, synchronous on the
scheduler thread:

1. `manager._poll_once` ("Runs on the scheduler thread"), driven every engine step by
   `has_pending_work()`, iterates every session and calls `session.poll()`, which
   `recv()`s + dispatches all wire messages (including serving every inbound
   `FetchMsg` via `write_blocks`) and polls the transport. All on the scheduling
   critical path, every step, scaling with pull/serve activity.
2. A HIT calls `_initiate_promotion` -> the request returns `RETRY` and is held out of
   `Running` until the batched `submit_load` round-trip completes.

So when the mesh is actively pulling/serving, every pod's scheduler thread burns
per-step time on p2p coordination and defers HIT requests -> the scheduling loop can't
keep the GPU fed -> throughput halves. (Which of the two sub-costs dominates would
need engine step-time instrumentation.)

### Upstream vLLM, not the branch

`_poll_once`, the `_initiate_promotion` deferral (base `TieringManager`), and the
fetch/transfer path all live in **upstream `vllm-project/vllm` main** under
`vllm/v1/kv_offload/tiering` — `_poll_once` is in upstream main's p2p manager,
`_initiate_promotion` in the upstream base `TieringManager` (never mounted; runs from the
nightly), and `request_blocks`/`collect_results` in upstream main's `client.py`. The
`generic_p2p` branch modifies the p2p manager (+232 lines) and adds the lookup phase, but
the design that starves the GPU — data-plane coordination + synchronous promotion on the
scheduler thread — is upstream. So this is an upstream issue, and the fix affects anyone
using the KV-offload p2p tier, not just this branch.

### Fix

Move the p2p data-plane coordination — `recv`/dispatch, serve/`write_blocks`,
transport polling — off the scheduler thread onto a dedicated background thread,
leaving only a minimal non-blocking handoff on the scheduler path. This is upstream work.

### Confirmed on the crash-fixed build

The ablation ladder above was measured on a crash-survivable build (Defect 2 worked
around by skipping the second flush). Re-measured on the **proper Defect-2 fix** (send
the late hashes, no drops, so *more* pulls actually fire): **0 crashes** under the full
benchmark, and p2p-ON = **567 tok/s vs 1346 off**, GPU still idle (`Running <= 6`),
`submit_load=172`. So the two defects are independent: fixing the crash lets p2p run
correctly, and the ~2x throughput cap remains — it is the transfer/coordination, not
the crash.

---

## Priorities

1. **Defect 2** — the crash gates everything; p2p can't run under load until it's
   fixed (send the late hashes).
2. **Defect 1** — the throughput cap; the coordination off the scheduler thread.

## Reproduce

- **Defect 2 (crash):** deploy unmodified `generic_p2p` branch code, warm one pod with ~300 distinct
  ~4k-token prefixes, pull concurrently from the other 3 (`CONC=80`, ~90s). Pods crash
  with `AssertionError: LookupMsg already sent` at `client.py:237`. Script:
  `p2p_hang_repro.py` (stdlib; drives the concurrent pulls).
- **Defect 1 (throughput):** `bench-ws400` through weighted-random routing, p2p on vs
  off; watch `Running` / `GPU KV cache usage` — GPU idles under p2p. Ablation ladder
  via `ablationA_p2p-to-miss.diff` / `ablationB_hit-to-miss.diff` over `manager.py`.
