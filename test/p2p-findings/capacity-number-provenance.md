# P2P findings — GPU KV capacity number provenance (guide report + blog)

The published gpt-oss-120b capacity figures in the guide's benchmark
report and the blog draft disagreed with each other and, in the P/D case,
with a fresh measurement. Neither was a copy-paste error or careless
mistake — each number was genuinely measured, but for a *different*
config or vLLM nightly than the one it ended up describing. Tracing the
actual provenance:

## The three numbers and where each one is really from

**~0.48M tokens/pod** — genuinely measured, but for a deliberately
different config: `--gpu-memory-utilization=0.60` on the series-2
"sessions exceed fleet GPU cache" scenario (`RESULTS.md` line ~235,
`RESULTS-2.md` line 18), where the whole point was to force eviction
under a smaller GPU budget. It was never the number for the guide's
actual shipped aggregated config (`--gpu-memory-utilization=0.85`) — it
got carried into `benchmark-results/gpt-oss-120b-h200.md` and the blog's
Use Case 1 table as if it were.

**~1.38M tokens/pod** — also genuinely measured, at `0.85`/`65536` (the
guide's real aggregated flags), but on an earlier vLLM nightly than the
one now pinned (`RESULTS.md` line 48, no specific SHA recorded). A fresh
read on the current pin (`nightly-4080263bb2c5d10deac17aaeb88e0823bc35bca9`,
same `0.85`/`65536` flags, two independent pod starts) gives
**1,218,315 tokens** instead — nightly-to-nightly drift in the memory
profiler/CUDA-graph accounting, not a config difference. The 1.38M figure
was then reused *again*, by reference rather than measurement, for the
P/D topology's CPU-tier sizing rationale in Run L
(`RESULTS-2.md` line 290: "128 GiB CPU tier both roles (~2.3x the
~1.38M-token GPU KV at TP=1)") — the P/D topology's GPU KV was never
independently measured. The blog's Use Case 3 table copied Run L's
numbers directly, inheriting the un-verified-for-P/D figure.

**1,607,392 tokens/pod (P/D, fresh measurement, this session)** — a
minimal 2-pod probe (1 prefill + 1 decode, TP=1 both legs, gpt-oss-120b,
`MultiConnector[NixlConnector + OffloadingConnector]`, current pinned
nightly, "as the pd-disaggregation guide ships" — no explicit
`--gpu-memory-utilization` or `--max-model-len` override, since neither
`guides/pd-disaggregation/modelserver/gpu/vllm/base/patch-{prefill,decode}.yaml`
nor the recipes base sets them). vLLM's own defaults apply instead:
`--gpu-memory-utilization=0.92` (logged explicitly) and
`--max-model-len=131072` (gpt-oss-120b's native context, vs the
aggregated config's explicit 65536 cap). Both legs identical, as
expected for matched TP=1/config. Manifest:
[configs/2026-07-capacity-and-scenarios/pd-capacity-probe.yaml](configs/2026-07-capacity-and-scenarios/pd-capacity-probe.yaml).
First attempt OOMKilled at `memory: 32Gi` (too small for the 88 GiB
`cpu_bytes_to_use` shm-backed tier); the guide's own proven value is
`memory: 160Gi` (`modelserver/gpu/vllm/patch-vllm.yaml`) — used that on
retry, 0 restarts.

## What this means for the published numbers

Neither the guide's report nor the blog can currently cite a P/D GPU-KV
figure with real provenance — the true number depends on which
`--gpu-memory-utilization` the P/D deployment actually runs, which
neither document states. Two ways to close this:

1. Explicitly set `--gpu-memory-utilization=0.85` on the P/D legs (for
   consistency with the aggregated config) and re-measure — expect
   something below 1.61M, roughly `1.61M * 0.85/0.92 ≈ 1.49M` if the
   relationship is close to linear, but this needs a real measurement,
   not an extrapolation, before publishing.
2. Leave the P/D legs at vLLM's defaults (as the guide currently ships
   them) and publish 1.61M as the actual figure, documenting the
   `--gpu-memory-utilization`/`--max-model-len` used so it's
   reproducible.

Either way, the aggregated topology's report and blog entries should be
corrected to 1.22M (this session's twice-confirmed measurement on the
current pin), and the P/D entry should stop being derived by reference
to a number that was never independently checked for that topology.

## Downstream corrections already made (guide only, not yet the blog)

- `benchmark-results/gpt-oss-120b-h200.md` and `benchmarking/README.md`:
  aggregated GPU KV corrected to ~1.22M, CPU:GPU ratio corrected to
  ~1.8x (was reported as 4.4x using the wrong 0.48M denominator), and the
  document-Q&A headline's "oversubscribes the fleet's aggregate GPU KV"
  claim removed — at the corrected capacity the 9.2M-token corpus fits
  inside the fleet's aggregate cache with room to spare, so the
  mechanism driving the headline's displaced-request pattern is
  per-pod queueing under concurrency, not capacity scarcity. See guide
  commits `97c45027`, `d4a5fb91` on `guides/p2p-kv-cache-sharing`.
- Blog (`llm-d.github.io`, `blog/2026-08-15_p2p-kv-cache-sharing-llm-d.md`):
  Use Case 1's capacity figure and oversubscription framing were
  corrected the same way (commit `cc1dd76`). Use Case 3's P/D figure and
  the guide's placement-rule closing section were **not yet corrected**
  as of this writing — pending a decision on how to handle the
  unresolved P/D provenance above.
