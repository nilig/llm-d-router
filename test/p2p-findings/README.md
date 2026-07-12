# p2p findings — reproducible evidence bundle

Companion to `p2p-findings.md`. Each defect has a way to reproduce it independently.

## Defect 1 — throughput (ablation ladder)

Run `bench-ws400` (rate 16, shared-prefix 400x16, 2048-token prefix) through
weighted-random routing with p2p on, then re-run with each ablation applied to
`manager.py`. Watch the engine log's `Running` / `GPU KV cache usage` — the GPU idles
under normal p2p and fills under the ablations.

- `ablationA_p2p-to-miss.diff` — `.p2p` returns `MISS` immediately (no lookup, no
  pull). Keeps the EPP header + sidecar inject. Expected: throughput ~= off.
- `ablationB_hit-to-miss.diff` — full lookup round-trip runs, but a HIT is downgraded
  to `MISS` (no pull/promotion/transfer). Expected: throughput ~= off, with lookups
  actually resolving (`RESOLVED_hit > 0`, `submit_load = 0`).

Apply either over the mounted `manager.py` and re-run the same benchmark. Result ladder:

| build | tok/s |
|-------|-------|
| p2p off (recompute) | 1346 |
| ablation A | 1358 |
| ablation B | 1291 |
| p2p normal | 690 |

A->B->normal shows the lookup costs ~nothing and the **pull/promotion** is the ~2x cap.

Also observed and ruled out during these runs: `_LOAD_TIMEOUT` aborts = 0; sweeping
`_LOOKUP_TIMEOUT_S` 10s->1s moved the TTFT tail 10s->1s but left throughput flat
(683->692) — so the stall duration is not the throughput bottleneck.

## Defect 2 — the lookup hang

`p2p_hang_repro.py` — stdlib only, no router/EPP/sidecar. Warms one pod past its GPU
cache (offload to the servable CPU tier), then hammers it with concurrent pulls from
the other pods in two arms (OFF/recompute vs ON/p2p) and prints the tail delta.

```
URLS=http://POD0:8200,http://POD1:8200,http://POD2:8200,http://POD3:8200 \
MODEL=meta-llama/Llama-3.1-8B-Instruct KPER=300 CONC=80 DUR=120 \
python3 p2p_hang_repro.py
```

Pod0 is the source; the rest pull from it on `remote_port=7777`. Expected: OFF max
~4s; ON has a rare tail to the client timeout (~120s unfixed). Enable debug logging
and grep `double-flush guard dropping` (the dropped hashes) and correlate the
`kv_request_id`s with the hung requests — in our runs 5/6 hangs were guard-dropped.

## Fix (Defect 2 safety net)

`lookup_timeout.patch` — one file (`session_client.py`), ~66 lines. Bounds the lookup
wait with `_LOOKUP_TIMEOUT_S` and degrades a probe still pending past its flush to
`MISS` (local recompute) in the `collect_results` poll. Deadline keyed off flush time
so it never pre-empts a live probe. Validated: 120s -> ~13s tail, 0 failures, p2p
stays fully alive (100% serve completion), timeout fires only on genuinely-stuck
probes. Fixes the hang, not the throughput.
