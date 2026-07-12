# generic_p2p: rare unbounded pull hang (standalone repro)

## Finding

The connector is not systematically slow and does not drop transfers. In a
matched bare-vLLM A/B (4 pods, 60 concurrent consumers, no router/EPP/sidecar,
`kv_transfer_params.p2p` injected directly), a p2p pull has the same body
latency as a local recompute, and every transfer the source starts completes:

| arm             | reqs | fail | p50   | p90   | p99   | max      | serve completion         |
|-----------------|------|------|-------|-------|-------|----------|--------------------------|
| OFF (recompute) | 1351 | 0    | 3.48s | 3.79s | 4.19s | 4.39s    | -                        |
| ON (p2p-pull)   | 1853 | 2    | 3.04s | 3.67s | 4.42s | 120.10s  | write_blocks 96 -> done 96 (100%) |

The one difference is the tail: a small fraction of pulls hang far longer than
any recompute. The magnitude is stochastic run to run - the ON `max` lands
anywhere from ~20s to the full 120s client timeout (the timeouts show up as the
`fail` count), while the OFF `max` never exceeds ~4.5s. Across runs the ON tail
is consistently 5-30x the OFF tail even though the body latencies (p50/p90/p99)
match. So a small fraction of pulls hang unbounded; recompute never does.

## Mechanism

`session_client.py` states "Lookups have no timeout" - `_LOAD_TIMEOUT_S=30`
bounds the load phase, but the lookup phase is unbounded. So a lookup that never
resolves (lost probe, a peer-busy race) hangs the request until the client gives
up. That matches the tail exactly: the hangs sit at the client timeout, not at
any connector-internal bound.

## Why it collapses a benchmark but not a burst

In a burst, 0.15% hangs is 2-3 slow requests and nothing cascades. Under a
sustained benchmark (fixed arrival rate, through the sidecar, head-of-line in
the engine step), a hung pull holds its slot and blocks the requests queued
behind it, so the tail compounds into a throughput collapse. In our full-path
run the same config went from ~1345 tok/s / 0 fail (p2p off) to ~400 tok/s /
26% fail (p2p on). The rare hang is the seed; head-of-line under load is the
amplifier.

## Fix direction

Bound the lookup wait with a recompute fallback on the load-completion side, so
a stuck pull degrades to a recompute (~4s) instead of a 120s hang - that caps
the tail without disabling p2p.

One caution from trying this: a naive `return MISS` taken before the lookup is
registered breaks p2p entirely - it short-circuits `register_lookup` before the
probe/session machinery has a chance to pump, so nothing ever pulls (hit=0 cold
and warm). The timeout has to fire after the lookup is registered and pumped,
then fall back, rather than pre-empting the lookup.

Separately, and independent of the hang: on H200 with cheap 2K-4K-token
prefixes the pull body is about break-even with recompute, so p2p's win shows up
where recompute is expensive - much longer prefixes, slower or prefill-saturated
GPUs, or cross-node reuse where local recompute is not an option.

## Reproducer

`p2p_hang_repro.py` - stdlib only, no router/EPP/sidecar. Warms one source pod
past its GPU cache (blocks offload to the servable CPU tier), then hammers it
with concurrent consumers in both arms and prints the tail delta.

```
URLS=http://POD0:8200,http://POD1:8200,http://POD2:8200,http://POD3:8200 \
MODEL=meta-llama/Llama-3.1-8B-Instruct \
KPER=300 CONC=60 DUR=75 python3 p2p_hang_repro.py
```

Pod0 is the source; the rest are consumers pulling from it on `remote_port=7777`.
It prints `REPRODUCED` when the ON arm tail dwarfs the OFF arm tail with matched
body latency.

The script is stdlib only, so the simplest path is to run it directly against
the pods - from inside the cluster, or via `kubectl port-forward` to each pod.
No kubectl-run wrapper needed.

`run-repro.sh` is an optional in-cluster wrapper: it resolves pod IPs and runs
the script in a `python:3.11-slim` pod (fed on stdin via `python -`, so it does
not base64-encode or `exec()` anything - that pattern trips EDR signatures).
Override `CTX`, `NS`, `DEPLOY`, `MODEL` for your cluster:

```
CTX=my-ctx NS=my-ns DEPLOY=my-vllm-deploy ./run-repro.sh
```
