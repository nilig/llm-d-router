# Handoff: state and continuation (written 2026-08-01, branch p2p-findings @ 02d81d8a)

## Where the campaign stands

- Cluster: kermit, namespace `nilig-p2p`. Fleet 4/4 Ready on
  `quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302` with the
  author's prefill settings (util 0.935, ceiling 2048). The vllm #50302
  crash is FIXED under real traffic: warm round 32/32 HTTP 200 through
  the EPP, zero decode restarts (previously 3/32 + decode crash).
- Active EPP config: armC (precise+P2P). `activate_arm.sh` re-proves
  live KV-event subscriptions after every B/C activation.
- Gate 1: PASS (live-subscription evidence, 32/32;
  `gates/archives/gate1-20260801181759/`).
- Gate 2: every byte assertion PASSES on the recalibrated window
  (control 0.0 MB; engine-inject 1341.5 MB; pd-stock 1341.5 MB = 0.0%
  deviation; window 1200-1550 MB around the measured 54.6 KB/token).
  The ONLY failing assertion is source-session delta >= 1.

## The one open decision (for codex)

Session-delta semantics on a warm mesh. P2P sessions persist beyond the
pull that created them: the first Gate 2 run consumed the only
`accepting incoming connection` event; reruns ride the same open
session, so the log delta reads 0 while a live ESTABLISHED connection
on the source's P2P port 7777 from the destination prefill IP is
verifiable in /proc/net/tcp. Proposal on the table: satisfy the session
assertion by EITHER new-session delta >= 1 OR a live ESTABLISHED
source-port-7777 connection whose remote address equals the destination
pod IP, captured at gate end (same live-evidence style as
`wait_precise_subscriptions.sh`). Alternative: declare Gate 2
single-shot per mesh-cold (conflicts with no-restart reruns).

## Continuation sequence after that ruling

1. Apply the ruled session check to `gates/gate2_p2p_proof.sh`, rerun
   Gate 2 (fresh prefixes, no fleet restart), require full PASS.
2. `gates/armC_probe.sh 64` - organic engagement probe (needs >0
   source-header emissions AND >0 prefill loaded-bytes delta; prints
   engagement % for the 5% rule).
3. Ladder c16/32/64/128 (the blog's own rungs; 900 s per rung, seed 42
   fixed): stage 1 = one paired B/C run + probe per rung; stage 2 = at
   rungs with >=5% engagement, three counterbalanced B/C repetitions
   with SEED=42/43/44 via `run_arm.sh <arm> <conc> <tag>`, plus one
   armA anchor per rung. B-vs-C is the only causal P2P comparison.

## Gate 2 invocation (re-resolve pod IPs first - they change on reboot)

```
kubectl get pods -n nilig-p2p -l llm-d.ai/inference-serving=true -o wide
cd gates && NS=nilig-p2p \
  SRC_POD=<prefill-0 pod name> \
  SRC_PF_URL=http://<prefill-0 IP>:8000 SRC_PF_SERVING=<prefill-0 IP>:8000 \
  DST_PF_URL=http://<prefill-1 IP>:8000 DST_PF_SERVING=<prefill-1 IP>:8000 \
  DECODE_SIDECAR_URL=http://<decode-0 IP>:8000 \
  OUT=archives/gate2-$(date +%Y%m%d%H%M%S) bash gate2_p2p_proof.sh
```

## Operational guards (session-local - they DIE with the operator session)

Two watchdogs ran from the operator's machine and do not survive it:

- gpu-pruner guard: the cluster pruner scales idle LWS roles to 0.
  Restore with:
  `kubectl scale lws -n nilig-p2p wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill --replicas=2`
  `kubectl scale lws -n nilig-p2p wide-ep-lws-nvidia-gpu-vllm-glm-5-2-decode --replicas=1`
  Reboot ~40 min total (prefill ~15, decode ~25). Nodes have been
  retained across reaps so far.
- keep-warm ticker: any Ready engine idles back into the pruner's
  sights in ~15-20 min. Ping each Ready engine every ~4 min (decode
  pods :8200, prefill pods :8000, `/v1/completions`, max_tokens 8, via
  the in-cluster `scenc-loadgen` pod - python3 urllib; the image has no
  curl). Real benchmark traffic also counts as warm.

After any fleet reboot: re-run `activate_arm.sh armC` (it re-proves
subscriptions), then Gate 1, then Gate 2 - pod IPs and the session
state will have changed (a cold mesh makes the session delta valid
again).

## Traps already hit (do not re-diagnose)

- `kubectl exec` heredocs need `-i` or python runs an empty script.
- EPP log greps are not evidence at --v=5; use live /proc/net/tcp
  checks (`gates/wait_precise_subscriptions.sh`).
- The approx producer auto-instantiates alongside precise
  (RegisterAsDefaultProducer for PrefixCacheMatchInfoDataKey in
  runner.go) - its log lines under armB/C are expected, not a config
  mismatch.
- `accepting incoming connection` = session, not pull; sessions persist
  across runs and arms.
- Stuck-LWS template: after any LWS spec change, delete pods; STS
  ordinal revision lag can recreate pod-0 on the old revision until
  pod-1 is Ready.
- KV footprint on this engine is 54.6 KB/token (FP8 KV); the old
  92.6 KB/token expectation is stale.
- A Complete benchmark Job is not a valid arm - grep the harness log
  for `errors=N`; abort rungs with foreign ACTIVE jobs (run_arm.sh
  enforces both).
