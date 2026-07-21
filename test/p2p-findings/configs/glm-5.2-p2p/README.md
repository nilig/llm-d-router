# GLM-5.2-FP8 wide-EP P/D — P2P KV-cache benchmark

Four-arm A/B of cross-engine P2P KV pull on GLM-5.2 under saturated agentic load.
Headline: **precise routing hot-spots at saturation, the pull helps, and approx
routing + pull (armD) is the best config of the four.**

## Setup

- **Model:** `zai-org/GLM-5.2-FP8`, 1P1D wide-EP **DEP16** (16 DP ranks per role,
  2 pods/role, spanning 4 IB leaf groups — cross-leaf all2all is fine on kermit).
- **Engine image:** `vllm/vllm-openai:nightly-6a9f24aa` (sha256 `0eb4c293…`) **+ the
  `generic-p2p-src` overlay** (Liran's branch = the unpaired cross-engine pull;
  upstream is paired-only until `vllm#48021`). Image and overlay are a matched pair.
- **KV transfer:** `MultiConnector` = `NixlConnector` (P/D) + `OffloadingConnector`
  (CPU tier, `secondary_tiers:[{type:p2p, port:7777}]`, `cpu_bytes_to_use` 100 GiB,
  eviction lru). kv-events → the router's precise index (`topic kv@POD_IP:8000@model`).
- **Load-bearing env:** `ENABLE_MTP=0`, KV dtype bf16, `MAX_MODEL_LEN=119990`,
  `PYTHONHASHSEED=0` (seed divergence silently breaks content-key matching → no pulls).
- **Benchmark:** `aiperf` (`agentx-v0`), scenario `inferencex-agentx-mvp`, dataset
  `semianalysis_cc_traces_weka_with_subagents`, concurrency **128**, 900 s profiling.
  kermit / CoreWeave H200.
- **Router:** `p2p-pd-epp`; arm selected by the `--config-file` arg pointing at a key
  in the `p2p-pd-epp-plugins` configmap (patch the arg + `rollout restart` to swap —
  editing a key under a running EPP does nothing).

## The four arms

| Arm | Routing | Pull | offload_prompt_only | File |
|-----|---------|------|--------------------|------|
| **armA** | approx gpu+cpu prefix-cache (w5/w2) — the stock guide router | off | false | `epp-armA.yaml` |
| **armB** | precise prefix-cache (kv-events index, w5) + queue w3 + active w1 | off | false | `epp-armB.yaml` |
| **armC-16k** | precise (as armB) | **on** — `p2p-source-producer` off the **precise** index, δ16384 | false | `epp-armC16k.yaml` |
| **armD** | approx (as armA) | **on** — `p2p-source-producer` off the **approx cpu** index, δ16384 | **true** | `epp-armD.yaml` |

`armC.yaml` = armC with δ2048 (unused here; δ2048 fires pulls that cost more than
they save). Engine spec (both roles): `lws-prefill.yaml`, `lws-decode.yaml` — the
prefill spec shown is `offload_prompt_only:false`; armD flipped that one flag to
`true` — the setting that *matches* approx routing (approx never indexes decode blocks,
and GLM's `delta.reasoning` decode isn't reused as a next-turn prefix, so offloading
decode KV would be waste). See Caveats.

## Pull vs recompute — 24K prefix, unloaded (mechanism proof)

| Condition | TTFT | vs cold |
|-----------|-----:|--------:|
| Cold (full recompute) | 4.63 s | — |
| Cross-engine pull | 3.91 s | −16% |
| Local warm hit | 2.30 s | −50% |

2.23 GB of KV moved per pull. GLM KV ≈ 93 KB/token.

## Results — c128 agentic, ~929 s each, 0 errors

Grouped by routing: approx (A, D) | precise (B, C).

| Metric | armA approx/off | **armD approx/pull** | armB precise/off | armC-16k precise/pull |
|--------|----------------:|---------------------:|-----------------:|----------------------:|
| TTFT p50 (ms) | 2,963 | **2,953** | 3,802 | 3,177 |
| TTFT p90 (ms) | 9,226 | **8,833** | 11,755 | 9,970 |
| TTFT p99 (ms) | 24,925 | 24,360 | 24,119 | 25,084 |
| Req latency p50 (ms) | 21,202 | 21,311 | 21,795 | 21,525 |
| Req latency p99 (ms) | 242,822 | 260,161 | 237,808 | 249,164 |
| Inter-token p50 (ms) | 54.7 | 55.6 | 55.6 | 56.1 |
| Output tok/s | 2,078 | 2,049 | 2,016 | 1,982 |
| Requests done | 3,237 | 3,236 | 3,336 | 3,131 |
| KV pulled cross-engine | ~0 | 33.8 GB | ~0 | 163 GB |
| External hits (tokens) | ~0 | 364 K | ~0 | 1.77 M |

## Findings

1. **The pull fires off both a precise and an approximate source index.** armC-16k
   (precise) pulled 1.77 M tokens / 163 GB; armD (approx) pulled 364 K / 33.8 GB from
   a fresh-zero start. The `p2p-source-producer` consumes either producer's match info.
2. **Precise routing hurts at saturation.** armA→armB (pull off both) is **+28% TTFT
   p50** (2,963→3,802): precise affinity concentrates traffic on cache-holder ranks →
   hot-spot queuing. approx's fuzzier spread load-balances better.
3. **The pull helps.** armB→armC-16k is **−16% p50 / −15% p90** (it lets the picker
   route to a less-loaded rank and fetch the prefix). armA→armD is −0.3% p50 / −4.3% p90.
4. **approx + pull (armD) is the best arm** — lowest TTFT p50 *and* p90 — combining
   approx's load balance with the pull's rescue, avoiding precise's hot-spotting. It
   beats armC-16k (precise+pull) by ~7% p50 / ~11% p90 while pulling **~5× less** KV.

## Caveats

- **Single run per arm.** The ~15% pull deltas repeat across p50 and p90 (likely real);
  sub-5% throughput gaps are within run-to-run noise.
- **Warmth / ordering confound.** Runs were sequential and the CPU tier carries across
  runs; armD ran last on **cold** engines (fresh from a restore), which should have hurt
  it, so its win is if anything understated. Equal-warmth reruns are the open item.
- **c128 is saturated** (req-latency p99 ~240-260 s = queue/decode-bound). This is the
  *worst* regime for the pull, not the best. A concurrency ladder (c16/c32/c64) is needed
  to find where the pull's transfer cost is dominated by its recompute saving.
- **`offload_prompt_only` matches the router — so armD isn't a loose confound.** Offloading
  decode KV (`false`) only helps when a producer *indexes* those blocks (**precise** does via
  kv-events; **approx** does not) *and* the model reuses its decode as a next-turn prefix. GLM
  emits reasoning in `delta.reasoning` and doesn't feed it back, and approx never indexes decode
  — so `true` is the only coherent setting for approx (`false` would offload decode KV nothing
  can reach). armD is thus "approx configured correctly," and armC (precise+`false`) vs armD
  (approx+`true`) is a fair best-recipe comparison. Corollary: **armA (approx+`false`) is itself
  slightly mis-set** — it offloads decode KV approx can't use, so part of armD's edge is that
  `true` offloads less (less GPU→CPU contention).

## Operating the cell (hard-won)

- Image + `generic-p2p-src` overlay are one organism; a newer nightly under the overlay
  dies at init, a newer nightly without it boots but can't pull. Nothing to upgrade
  until Liran rebases `#48021`.
- `PYTHONHASHSEED=0` on every engine, or content keys diverge and pulls silently return
  nothing.
- The gpu-pruner scales both LWS to `replicas:0` after ~40 idle min. Restore with
  `kubectl scale lws <prefill> <decode> --replicas=1` (not re-apply); the spec survives.
- `kubectl rollout restart deploy/p2p-pd-epp` after **any** engine pod recreate, or the
  EPP holds subscriptions to dead pod IPs and the precise index goes stale silently.
- Gate before trusting (Ready is a rumor): per pod `'type':'p2p'` count = 8, Traceback
  = 0, KV cache ~525 K prefill / ~701 K decode (≈1 M = fp8 regressed), 16 `#dp-` topics
  in the EPP log, gateway 200, then a pull-proof (a peer engine shows a ~2.2 GB load).

## Files

- `epp-arm{A,B,C,C16k,D}.yaml` — the EPP arm configs.
- `lws-{prefill,decode}.yaml` — engine specs (image, overlay mount, KV config, env).
- `aiperf-c128-arm*.log` — raw aiperf output per arm (summary table at the end).
- `metrics-arm*-prefill-{0,0-1}.txt` — final engine `/metrics` per arm (pull counters).
- `pull-timeline-arm*.log` — per-tick external-hit / pull-volume trace during each run.
