# Weka long-pause resume pressure

This workload tests a real cache-ownership transition without weakening the
published EPP placement policy. It uses the same Weka corpus and AgentX replay
as the blog-policy matrix, but raises the per-trace idle-gap cap from the
scenario's 10 seconds to 60 seconds. The installed AIPerf runner documents 60
seconds as the InferenceX AgentX RFC setting.

The longer gaps let unrelated Weka conversations create cache pressure while a
conversation is idle. The intended condition is a resumed request for which a
remote source retains at least 12,288 more cached tokens than the selected
prefill endpoint. P2P is useful only after that condition occurs organically.

The scenario lock is retained and the one changed invariant is passed with
`--unsafe-override`. AIPerf therefore records `submission_valid=false`; these
runs are a declared workload variant, not a reproduction of the published
10-second-cap result.

## Stage 1: engagement calibration

Start with the exact blog approximate policy plus P2P at c128. The first probe
changes the idle-gap cap only:

```bash
resume-pressure/run_probe.sh 128 60 42
```

If that produces fewer than 5% source directives, increase the number of live
Weka trajectories while retaining the 60-second gap:

```bash
resume-pressure/run_probe.sh 256 60 42
```

Do not use `--agentic-cache-warmup-duration` for this corpus. The accelerated
replay reaches context-overflow and incomplete subagent histories during
warmup; AgentX correctly refuses the profiling handoff. The invalid 90- and
180-second attempts are retained under `artifacts/invalid-rp-*`.

Do not run a no-P2P performance comparison at a cell below the engagement gate.

The probe keeps `minCachedTokenDelta: 12288`. It reports the distribution of
the remote cached-token advantage from the streamed EPP trace, so a zero result
distinguishes equal-cache placement from threshold near misses.

## Stage 2: causal pairs

At the first qualified cell, run both index families as independent P2P pairs:

```text
blog approximate, no P2P  vs  blog approximate + P2P
blog-policy precise       vs  blog-policy precise + P2P
```

Within each pair, the EPP files differ only by `p2p-source-producer`. Use three
new seeds and alternate order. Keep the selected concurrency, 60-second gap,
deployment, engine cache, and 900-second measurement duration fixed.

Primary performance metrics are TTFT p50 and p99 for resumed turns, overall
request throughput, and output tokens/s/user. Mechanism evidence is the source
directive rate plus positive destination load-byte deltas; loaded bytes alone
are not attributable because local CPU-to-GPU restores use the same counter.
