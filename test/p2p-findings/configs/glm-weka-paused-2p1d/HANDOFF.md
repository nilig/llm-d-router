# Handoff: state and continuation (updated 2026-08-01 after c64 probe PASS)

## Where the campaign stands

- Cluster: kermit, namespace `nilig-p2p`. Fleet 4/4 Ready on
  `quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302` with the
  author's prefill settings (util 0.935, ceiling 2048). The vllm #50302
  crash is FIXED under real traffic (warm round 32/32; sustained c64
  probe clean). #50302 is merged upstream (`a0cd2b69`), so any
  post-merge nightly is a fallback engine if the baked image ever
  misbehaves.
- Active EPP config: armC (precise+P2P). `activate_arm.sh` re-proves
  live KV-event subscriptions after every armB/armC activation
  (`gates/subscriptions/`).
- Gate 1: PASS - live-subscription evidence, 32/32
  (`gates/archives/gate1-20260801181759/`).
- Gate 2: PASS - control 0.0 MB / engine-inject 1341.5 MB / pd-stock
  1341.5 MB (0.0% deviation, window 1200-1550 MB per the measured
  54.6 KB/token), session evidence delta>=1 OR live exact-peer
  (`gates/archives/gate2-20260801183650/`).
- Stage-1 engagement probe at c64: PASS at 10.6% (threshold 5%):
  3889 requests, 412 distinct organic source directives, 251 new peer
  sessions, 3.9 TB prefill tier restores (loaded-bytes includes LOCAL
  CPU->GPU restores; directives+sessions are the P2P-specific
  evidence). Archive: `gates/probe-c64-20260801185307/`.

## The one open decision (for codex)

The README defers to a "cold-roll policy" whose text never made it into
the repo (it lived in the original design message). Needed before the
causal B/C measurements: the cache-state rule between runs. Tension:
C runs warm persistent CPU tiers and leave peer sessions open, which a
following B run partially inherits; a full engine roll restores cold
state but costs ~40 min per roll (24 planned runs) and re-exposes the
boot to the gpu-pruner. Counterbalanced pairs (B/C then C/B, 3 paired
seeds) exist to neutralize order effects without rolls, and the blog's
own ladder ran rungs back-to-back warm. Recommendation on the table:
no rolls within the ladder, fixed warm-in convention (the scenario's
900 s steady-state minimum), rolls at most at cell boundaries. Codex to
rule; write the ruling into README.md so it is declared, then proceed.

## Continuation sequence after that ruling

1. Write the ruled policy into README.md (replace the dangling
   "Cold-roll policy ... per the campaign design" sentence).
2. Measurements at c64 (already qualified): three counterbalanced
   B/C repetitions with SEED=42/43/44 via
   `run_arm.sh <armB|armC> 64 <tag>`, order alternated (BC/CB/BC),
   plus one armA anchor run. B-vs-C is the only causal P2P
   comparison; A is context.
3. Remaining rungs c16/c32/c128: `gates/armC_probe.sh <conc> 900`
   first; measure only rungs with >=5% engagement (expect c128 yes;
   c16/c32 likely ties - a tie at <5% engagement is itself the
   reported result, run one paired B/C to confirm if cheap).
4. Results: per-rung tables (TTFT p50/p99, req/s, tok/s/user from
   `profile_export_aiperf.json`) B vs C with A anchor, plus mechanism
   counters (directives, sessions, loaded bytes) per run. Compare
   shapes against the author's p1w2d1w2 curves in
   `workload/blog-ladder-archive/headline_metrics.csv` (topology
   differs: no absolute claims).

## Run mechanics

- `run_arm.sh` clones the recovered Job (`workload/
  blog-campaign-job-c64.json`), changing only URL/metrics/artifact
  volume/concurrency/seed; it aborts on fleet!=4 Ready, foreign ACTIVE
  jobs (ALLOW_FOREIGN=1 to override), config/producer mismatch; snap
  counters before/after (`snap_counters.sh`).
- A Complete Job is not a valid run - grep the harness log for
  `errors=N` and check `was_cancelled`.
- The scenario rejects `--benchmark-duration < 900`.
- Gate 2 invocation template and pod-IP resolution: see the gate's
  header; IPs change on every pod recreation.

## Operational guards (session-local - they DIE with the operator session)

- gpu-pruner scales idle LWS roles to 0 within ~15-20 idle minutes.
  Restore:
  `kubectl scale lws -n nilig-p2p wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill --replicas=2`
  `kubectl scale lws -n nilig-p2p wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=1`
  Reboot ~40 min (prefill ~15, decode ~25); nodes retained so far.
- Keep-warm: ping every Ready engine every ~4 min from the in-cluster
  `scenc-loadgen` pod (decode :8200, prefill :8000,
  `/v1/completions`, max_tokens 8, python3 urllib - image has no
  curl). Benchmark traffic also counts.
- After any fleet reboot: `activate_arm.sh armC`, Gate 1, Gate 2
  (cold mesh makes the session delta valid again), and re-check pod
  IPs everywhere.

## Traps already hit (do not re-diagnose)

- `kubectl exec` heredocs need `-i` or python runs an empty script.
- EPP log greps are not evidence at --v=5; use live /proc/net/tcp
  checks (`gates/wait_precise_subscriptions.sh`); stream logs with a
  `grep --line-buffered '"requestID"'` filter (a 3-min unfiltered
  stream was 224 MB).
- The approx producer auto-instantiates alongside precise
  (RegisterAsDefaultProducer in runner.go) - its log lines under
  armB/C are expected, not a config mismatch.
- `accepting incoming connection` = session, not pull; sessions
  persist across runs and arms (Gate 2's warm-mesh rule exists for
  this).
- Stuck-LWS template: after any LWS spec change, delete pods; STS
  ordinal revision lag can recreate pod-0 on the old revision.
- KV footprint on this engine: 54.6 KB/token (FP8 KV). The 92.6
  KB/token figure is stale.
- `kv_offload_load_bytes` counts LOCAL CPU->GPU restores, not just
  P2P pulls - never present loaded-bytes alone as pull evidence.
