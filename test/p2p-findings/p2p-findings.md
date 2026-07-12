# generic_p2p under load: two connector defects, evidence, and fixes

Two distinct defects surface when the p2p connector runs under real load. Both are
**connector-side** — the router (EPP producer + sidecar) is exonerated by ablation.

- **Defect 1 — throughput:** with p2p on, throughput is ~2x lower than recompute and
  the GPU sits idle. The cost is the p2p data-plane **coordination on the scheduler
  thread**, not the (async) NIXL transfer. This is what makes p2p lose the benchmark.
- **Defect 2 — a rare unbounded lookup hang:** a small fraction of pulls never
  complete and hang to the client's 120s timeout, from the double-flush guard
  dropping late-registered lookup hashes.

They are independent; fixing one does not fix the other.

## Test setup

- 4 vLLM pods, generic_p2p branch: `OffloadingConnector` + p2p secondary tier on
  `:7777`, 32 GiB CPU tier, Llama-3.1-8B, `--block-size=64`, 1 GPU (H200) each.
- Benchmark: inference-perf `bench-ws400` — shared-prefix, 400 groups x 16 prompts,
  2048-token system prefix + 256 question + 64 output, constant **rate 16 req/s**,
  200s (3200 requests). Routed through weighted-random load-spread so requests land
  on non-owner pods and p2p fires. p2p **on** vs **off** = one plugin
  (`p2p-source-producer`) — everything else identical.

---

## Defect 1 — throughput: p2p coordination on the scheduler thread

### Symptom

| arm | tok/s | fail | req-lat p99 | note |
|-----|-------|------|-------------|------|
| p2p **off** (recompute) | 1346 | 0 | 0.70s | baseline |
| p2p **on** | ~690 (down to ~400) | 2 to 824 | up to 53s | ~2x lower; severity varies with p2p intensity |

Throughout the p2p-on run the GPU is **idle**: `Running <= 5 reqs`, `GPU KV cache
usage <= 4%`. It is not compute-bound and not KV-cache-bound — requests are not
being admitted to the GPU.

### What it is NOT (all ruled out by experiment)

- **Not the 30s load abort** (`_LOAD_TIMEOUT_S`): 0 aborts fired.
- **Not the stuck-lookup stall duration:** sweeping `_LOOKUP_TIMEOUT_S` 10s -> 1s moved
  the TTFT tail 10.07s -> 1.07s but left throughput flat (683 -> 692). The stall is a
  tail-latency issue, not a throughput one.
- **Not GPU compute:** GPU idle throughout.
- **Not the EPP producer or the sidecar:** ablation below.

### Localization — the ablation ladder

Each row keeps more of the p2p path. `mgr_abl.py` forces `.p2p` -> immediate `MISS`
(skip lookup+pull). `mgr_ablB.py` runs the full lookup but downgrades a HIT to `MISS`
(skip only the pull/promotion).

| build | EPP header + sidecar inject | lookup round-trip | pull / promotion | tok/s |
|-------|------|------|------|-------|
| recompute (off) | - | - | - | 1346 |
| Ablation A (`.p2p`->MISS) | yes | - | - | 1358 |
| Ablation B (lookup, HIT->MISS) | yes | yes (1050 lookups ran) | - | 1291 |
| p2p normal | yes | yes | yes | 690 |

- A vs off: the EPP header + sidecar injection cost **nothing** (1358 ~= 1346).
- B vs A: adding the full lookup round-trip costs **~nothing** (1291, with 1050
  lookups actually resolving, `submit_load=0`).
- ON vs B: adding the **pull/promotion** halves throughput (1291 -> 690).

So the ~2x cap is entirely the **HIT -> promotion -> load -> serve** path.

### Root cause (code)

The NIXL data movement is async — `NixlTransport.write_blocks` submits
(`agent.transfer(handle)`) and returns; `poll()` only checks state. So the transfer
does not block the thread. The cost is the **coordination**, which is synchronous on
the scheduler thread:

1. **Per-step orchestration.** `manager._poll_once` ("Runs on the scheduler thread")
   is driven every engine step by `has_pending_work()` returning `True`. Each step it
   iterates **every session** and calls `session.poll()`, which synchronously:
   `recv()`s + dispatches all wire messages — including handling every inbound
   `FetchMsg` by submitting a NIXL write (`write_blocks`) to **serve** a peer — then
   polls the transport for completions and runs the client-side timeout/lookup sweep.
   All on the scheduling critical path, for every session, every step. It scales with
   how much the mesh is pulling/serving.

2. **Request deferral.** A HIT calls `_initiate_promotion` -> the request returns
   `RETRY` and is held out of `Running` until the batched `submit_load` round-trip
   (`FetchMsg` -> peer serves -> NIXL -> completion, spread over several steps)
   finishes. Every HIT is a multi-step wait before the request can schedule — versus a
   fast local recompute on H200.

Together: when the mesh is actively pulling and serving, every pod's scheduler thread
spends per-step time on p2p coordination and defers HIT requests, so the scheduling
loop cannot keep the GPU fed -> GPU idle -> throughput halves.

Not isolated: which of the two sub-costs dominates (per-step orchestration vs
request deferral) — that needs engine step-time instrumentation.

### Fix

Move the p2p data-plane coordination — the `recv`/dispatch, the serve/`write_blocks`,
the transport polling — **off the scheduler thread onto a dedicated background
thread**, leaving only a minimal non-blocking handoff on the scheduler path (enqueue
load intent, check a done-flag). This is how vLLM's other KV connectors run their
data plane. Not yet implemented — this is the target.

---

## Defect 2 — rare unbounded lookup hang (double-flush guard)

### Symptom

Under concurrent pulls a small fraction of requests (~0.1-0.2% at 60-way, several per
run at 80-way) hang to the 120s client timeout. The producer serves 100% of what it
is asked (`write_blocks == transfer_done`), and recompute at the same concurrency
never exceeds ~4.4s. So it is specific to the pull path.

### Root cause (code)

The `PATCH(nili)` double-flush guard in `flush_pending_lookups`. When a request
registers block hashes across more than one scheduler step (chunked prefill or a
reschedule), the later batch finds `req_id` already in `_flushed_req_ids`, the guard
skips sending its `LookupMsg`, and the trailing `self._unsent_lookups_by_req.clear()`
discards those hashes. Those probes stay `None` forever, so `register_lookup` keeps
returning `RETRY` and the request never schedules. The lookup phase has no timeout
(only the load phase does, `_LOAD_TIMEOUT_S=30`), so nothing rescues it -> 120s hang.

The lookup design itself is fine — non-blocking, returns `RETRY`, never blocks the
scheduler. This is an unbounded retry from a dropped probe, not a 30s block.

### Evidence

Logged `kv_request_id` on both the guard-drop and the hang and cross-referenced:
**5 of 6 hangs were guard-dropped requests.** The drops concentrate on a few requests
that re-register a lot (one run: 81 drops across just 2 req_ids), and those are the
ones that hang. The remaining ~1/6 is either a second rarer race or a logging gap.

### Fix

- **Root fix:** send those late hashes (allow >1 `LookupMsg` per request) instead of
  dropping them. Needs care — the guard was added to stop an `EngineCore` crash under
  concurrent double-flush, so the fix must not reintroduce that.
- **Safety net (validated, available):** bound the lookup wait and degrade a stuck
  probe to a local recompute. Validated: 120s -> ~13s tail, 0 failures, p2p stays
  fully alive, timeout fires only on genuinely-stuck probes. Fixes the hang, **not**
  the throughput. Patch: `lookup_timeout.patch`.

---

## Priorities

1. **Throughput (Defect 1)** — the p2p coordination off the scheduler thread. This is
   what makes p2p competitive at rate 16.
2. **Robustness (Defect 2)** — the guard-drop hang. Real but rare; the safety-net
   patch bounds it today.

## Reproduce

- **Throughput / ablation:** `bench-ws400` through weighted-random routing, p2p on vs
  off; watch `Running` / `GPU KV cache usage` in the engine log — the GPU idles under
  p2p. The ablation ladder is reproduced with `mgr_abl.py` / `mgr_ablB.py` mounted
  over `manager.py` (`.p2p`->MISS and HIT->MISS respectively) + `run-abl.sh` /
  `run-ablB.sh`.
- **Hang:** bare vLLM, 4 pods, warm one with ~300 distinct ~4k-token prefixes (offload
  to its CPU tier), pull concurrently from the other 3 (60-80 workers, ~90-150s). A
  few hang to 120s; a no-p2p control never exceeds ~4.4s. Enable debug logging and grep
  the guard-drop line + the stuck req_ids for the correlation. Script:
  `p2p_hang_repro.py` (stdlib only, OFF/recompute vs ON/p2p arms, prints the tail
  delta).
