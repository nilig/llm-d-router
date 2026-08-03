# AgentX fork-group sweep: P2P value off saturation

## Why this exists

The weka campaign could only make P2P engage by shrinking the prefill CPU tier
to 25 GiB/rank (live: 12 GiB) against the blog's 100-150, and the effect only
reproduced at c128 — a rung the campaign's own handoff calls saturated. A
latency win measured between two overloaded configurations is not publishable:
the reader's response is "add a pod".

This campaign changes the lever. Aggregate value is

    pull rate x per-pull saving

Per-pull saving is already near its ceiling (~9-14 s of avoided prefill on a
58-86K inherited prefix, ~6,100 tok/s, reproduced within 3% across two runs).
The small aggregate came entirely from pull rate: 5 pulls in 71 requests.

But 71 is the wrong denominator. Continuation turns inside a branch stay on
their own rank and hit locally; they were never candidates. The real denominator
is **branch starts needing a prefix they do not hold** — 7 of them. Realized
efficiency was 5/7 and 3/7, not 5/71.

**Pull rate is set by fan-out structure, not by load.** Raising concurrency to
manufacture pulls saturates the cluster. Raising fan-out width does not. That is
the whole idea here.

## Selection

`tools/select_fork_groups.py` ranks every fork group in
`semianalysisai/cc-traces-weka-062126` (393 traces) by pull opportunity:
sibling subagents spawned in a burst, scored by the longest common prefix over
their first requests' `hash_ids`.

Validated against the one previously measured group: it rederives trace
`d5654f57…` group 3 as W=8, 1,180 blocks, 75,520 tokens, rows [77,84],
inherited fraction 0.0102 (= 768 parent-overlap tokens) — matching that run's
report on every figure, from an independent implementation.

It also agrees with the campaign's own selector on all 8 candidates above 70K.

### Two findings that shaped the design

**The corpus has far wider fan-out than the 70K floor admits.** Requiring
`>=70K exact common prefix` caps width at 10. Dropping to ~40K surfaces
W = 15, 23, 30, 43, 44 — every one still clearing `minCachedTokenDelta: 12288`
with 3.3x margin. One W=43 group yields 42 pull events against 21 for the three
selected 70K groups combined, and holds the prefix constant *inside* one
comparison instead of across three roots.

**Children never inherit the parent's context.** Across all 209 groups with
W>=3 and prefix >=12,288, inherited fraction is 0.000 at the median and 0.076
at the maximum. Subagents get a fresh tools+system+briefing block shared among
siblings but not with the parent, so a cold seed is unavoidable and
`pulls = W-1`. At W=43 that is a 97.7% pull rate, so it costs nothing where it
matters.

## Pre-registration

`PRE-REGISTRATION.md` fixes predictions for 14 windows across two prefix bands
before any run; each window's `manifest.json` carries the same numbers
machine-readable. 172 pull events, 1,293 s predicted total.

Primary endpoint is **per-pull avoided prefill on branch starts**, not the
all-request mean — which dilutes a handful of events by an order of magnitude.

Negative control is the delta gate, not a different trace: re-run the same
window with `minCachedTokenDelta` above its shared prefix. Zero pulls by
construction, workload byte-identical.

## Cell

`nilig-agentx-slo` on kermit, 16 GPUs, `p1w1d1w1`:

| | |
|---|---|
| model | `zai-org/GLM-5.2-FP8`, `--max-model-len 120000`, `--block-size 64`, fp8 KV |
| prefill | 1 pod, DP8, `PREFILL_GPU_MEM_UTIL=0.935`, `--max-num-batched-tokens 2048` |
| decode | 1 pod, DP8, `MAX_TOKENS_PER_NODE=32` |
| offload | `p2p-tiered`, 100 GiB/rank both roles, `offload_prompt_only: false` |
| engine | `quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302` |
| EPP | `ghcr.io/llm-d/llm-d-router-endpoint-picker-dev:main@088e4b74`, `--v=5` |

Prefill KV measured across all 8 ranks: **257,408 / 288,760 / 316,160** tokens
(min/mean/max), 2,310,080 per pod — within 1.3% of the `nilig-p2p` cell the
predictions were derived on.

Decode primary tier reported **30,624 blocks = 1,959,936 tokens/rank**, matching
the 100 GiB/rank arithmetic exactly. Three independent derivations of the KV
footprint now agree: bytes-per-block from transfer reconciliation
(3,502,592 B / 64 = 54,728 B/token), GiB-to-tokens from the vLLM logs, and this.

Deliberately **not** carrying over the asymmetric-tier deviation: 100 GiB on
both roles, per the blog.

### Arms

`deploy/manifests/44-cm-arms.yaml`, taken verbatim from
`ecrncevi-dev/wide-ep-lws-epp-token-{precise,precise-p2p}` — the pair the
real-fork result was measured on. They differ by exactly the five
`p2p-source-producer` lines, so the pull is the only variable.

Not derived from the approximate index: the 8-cell matrix showed approximate +
P2P fires zero pulls, because `lruCapacityPerServer: 200000` models a real
~7,700-block tier as still holding what it evicted.

## Gates

`CANDIDATE-GUIDE-GATES.md` — proposed for the P2P guide. Every entry maps to a
failure that actually happened tonight and was silent. The common shape: a
misconfigured P2P setup is indistinguishable from a working one that shows no
benefit, so a broken run reads as "P2P doesn't help".

Gate 1 result for this cell: **16/16 ranks subscribed** to the EPP's KV-event
ports, checked live via `/proc/net/tcp` from the engine side rather than grepped
from logs.

## Layout

```
tools/     selector, window extractor, arm runner, per-branch analyzer,
           counter summer
windows/   14 pre-registered windows (manifests for all; trace.json only for
           the one replayed — the rest regenerate deterministically from the
           pinned corpus via extract_fork_window.py)
deploy/    the full cell: apply.sh + manifests, two-phase so the control plane
           comes up without GPUs and the engines claim nodes separately
artifacts/ per-arm run outputs
```

## Run status (2026-08-03)

Cell built, gates passed, one arm valid, one arm lost. Recorded honestly because
the failure is more instructive than the numbers would have been.

| arm | status | records | with TTFT | branches |
|---|---|---:|---:|---:|
| control (`p2p-off`) | **valid** | 246 | 245 | 32 of 43 |
| treatment (`p2p-on`) | **invalid** | 246 | **0** | - |

The treatment ran against **no engines**. The gpu-pruner reclaimed both LWS at
~20:28, during the idle gap between the control arm draining (19:47) and the
treatment starting (20:50). Every request failed behind the gateway, yet aiperf
produced a full 246-record export and reported no errors. See gate C-ter.

No comparison is claimed. A single valid control arm is not a result.

### What the control arm did establish

- The workload is measured **off saturation**: `kv_usage` peaked at 23.4%,
  `queue` never exceeded `2r/0w`.
- Prefix routing captured **89.4% against a 91.3% theoretical ceiling** — 98% of
  available reuse, corroborating the blog's 96-97% and confirming why P2P's
  addressable share is the small residual.
- `ext_cache_hit` reached **83.4% with P2P switched off entirely** (P/D NIXL
  paired fetch). Anyone reading that as engagement would report a fabricated
  result.

### Blocking issues found and fixed in the harness

| issue | fix |
|---|---|
| `kubectl set args` does not exist; arm switching silently no-oped | JSON-patch the `--config-file` index in the epp container |
| aiperf never declares the phase finished (SPAWN_JOIN waits on every sibling) | wait for the record count to go stable, not for job completion |
| engines reclaimed during inter-arm gaps | `keep_warm.sh` for the campaign duration |
| a complete-looking run can be entirely empty | validate TTFT coverage, not record count |
| EPP restart changes its pod IP and empties the precise index | re-run gate C1 after every arm switch; declare a cold-or-warm protocol |

### To resume

Capacity is the constraint: 0 whole 8-GPU nodes free at the time of writing.

```
cd deploy && ./apply.sh engines     # refuses below 2 free nodes
./keep_warm.sh &                    # BEFORE the first arm, not between arms
NS=... EPP=... PVC_POD=... ARM_CONFIG=/config/p2p-off.yaml ./tools/run_fork_arm.sh windows/631738ac313214-g0 control
NS=... EPP=... PVC_POD=... ARM_CONFIG=/config/p2p-on.yaml  ./tools/run_fork_arm.sh windows/631738ac313214-g0 p2p
```

Both arms must be run under the same cold-index protocol — the first control run
had a 30-minute-warm index and would not have been a fair pair even had the
treatment survived.
