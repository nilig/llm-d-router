# Candidate gates for the P2P guide

Every one of these corresponds to a failure that actually happened, was silent,
and was only caught downstream. Ordered by how early they can run.

The common shape: **a misconfigured P2P setup is indistinguishable from a
working one that shows no benefit.** Without gates, the result of a broken run
is "P2P doesn't help" rather than "P2P wasn't on".

## A. Deployment wiring (before any traffic)

Four of tonight's failures were here. None produced an error at apply time.

| # | Gate | Failure it catches |
|---|---|---|
| A1 | Engine ServiceAccount exists in the namespace | StatefulSet silently refuses to create pods; LWS just says "Progressing" |
| A2 | Image-pull secret exists for the engine image | `ImagePullBackOff` after the node is already claimed |
| A3 | EPP's mounted ConfigMap name matches a ConfigMap that exists | `FailedMount`, EPP never starts |
| A4 | PVC bound before the benchmark job starts | Job pends indefinitely |

```bash
kubectl -n $NS get sa $ENGINE_SA && kubectl -n $NS get secret $PULL_SECRET
kubectl -n $NS get deploy $EPP -o json | jq -r '.spec.template.spec.volumes[].configMap.name // empty' \
  | while read c; do kubectl -n $NS get cm "$c" >/dev/null || echo "MISSING cm/$c"; done
```

**Do not trust `kubectl.kubernetes.io/last-applied-configuration`.** It disagreed
with the live spec tonight: the live EPP pointed at a different ConfigMap than
last-applied claimed, and copying from last-applied reproduced a stale name.
Read the live object.

## B. Router configuration

| # | Gate | Failure it catches |
|---|---|---|
| B1 | EPP loaded the config: every declared plugin appears in its logs, no parse error | Config written for a different EPP build; plugin silently absent |
| B2 | Treatment arm has `p2p-source-producer`; control arm does not | Two arms that are actually identical |
| B3 | EPP runs with `--v=5` or higher | All three `p2psource` log lines are `V(logging.TRACE)`; below 5 per-request attribution is impossible |
| B4 | `minCachedTokenDelta` < the workload's shared-prefix length | Gate silently declines every pull |
| B5 | `podCacheSize` >= endpoints x tiers | Per-key LRU evicts real holders; affinity zeroes and pulls never fire |
| B6 | Precise index, not approximate, when the tier is small | Approximate + P2P fires **zero** pulls: `lruCapacityPerServer: 200000` models a real ~7,700-block tier as still holding what it evicted |

B6 is the expensive one — an 8-cell matrix was spent discovering it.

## C. Mechanism engaged (before believing any measurement)

| # | Gate | Check |
|---|---|---|
| C1 | Every rank subscribed to KV events | count established TCP conns from the EPP IP to ports `5557..5557+DP-1` on **each** engine pod |
| C2 | Precise index non-empty | index size > 0 before the first measured request |
| C3 | Control transfers 0.0 MB | paired no-pull arm shows zero |
| C4 | Treatment fires pulls | `set KV cache source header` count > 0 |

C1 must be a **live socket check, not a log grep** — at `--v=5` the log volume is
enormous (a 3-minute unfiltered stream measured 224 MB) and absence of a line is
not absence of the condition. If the EPP image is distroless, check from the
engine side:

```bash
kubectl -n $NS exec $ENGINE_POD -c vllm -- python3 -c "
hx=''.join(f'{int(o):02X}' for o in reversed('$EPP_IP'.split('.')))
n=sum(1 for l in open('/proc/net/tcp') if len(l.split())>3 and l.split()[3]=='01'
      and l.split()[2].split(':')[0]==hx)
print('established conns from EPP:', n)"
```

Expect `DP_SIZE_LOCAL` connections per pod for KV events. Tonight: 8 on prefill
(plus 8 on the serving ports) and 8 on decode = **16/16 ranks**.

**Poll it, do not sample once.** Subscriptions are not established at the
moment the engines report Ready. Sampled immediately, this gate read 0/16 and
looked like a hard failure; 20 seconds later it was 16/16. A single-shot check
here produces false alarms, and worse, invites someone to disable the gate.

## D. Campaign hygiene

### D1. Arm switching resets the index

Switching arms by patching the EPP restarts it, and the precise index does not
survive: `KVEventsConfig.replay_endpoint` is null, so a fresh EPP learns only
from events published **after** it subscribes. Blocks cached before the restart
are invisible to it.

This creates a silent asymmetry. The arm that runs first, after the EPP has been
up for a while, sees a warm index. The arm that runs immediately after a restart
sees an empty one and can only pull for blocks created during its own run.
Whichever arm gets restarted is handicapped, and nothing in the output says so.

Two acceptable protocols, and the choice must be declared:

- **Both arms cold.** Restart the EPP before *each* arm and let the index rebuild
  from the run's own traffic. Works when the workload creates the shared prefix
  within the measured window (a fork group does: the cold-seed branch publishes
  the blocks the siblings then pull).
- **Both arms warm.** Fixed warm-in period after each restart before traffic
  starts, long enough for the index to repopulate.

What is not acceptable is restarting for one arm only. Gate on it: record EPP pod
age and index size at the first measured request of every arm, and refuse to
compare arms whose values differ by more than the declared tolerance.

### D2. The fleet can vanish between arms

The gpu-pruner scales idle LWS roles to 0 within ~15-20 minutes. A gap between
two arms is enough. Tonight: control drained at 19:47, treatment started at
20:50, engines reclaimed at ~20:28 in between.

What made it dangerous is how it presented. The treatment arm ran to completion
and produced a **full 246-record `profile_export.jsonl` with zero errors
reported by the harness** — and every single record had no TTFT, because every
request failed behind the gateway. A run that looks complete and is entirely
empty is worse than one that crashes.

Three defences, all cheap:

- **Keep-warm during the whole campaign, not per-arm.** Ping every ready engine
  every ~4 minutes from an in-cluster pod (`keep_warm.sh`). Benchmark traffic
  counts, but the gaps between arms do not.
- **Assert `readyReplicas == expected` immediately before and after every arm**,
  and abort the campaign if it changed. A run whose fleet size moved mid-flight
  is not comparable to its pair regardless of what the numbers say.
- **Validate records, not record counts.** `len(records)` is not evidence.
  Require a minimum fraction with non-null `time_to_first_token` before an arm
  counts as valid:

```bash
python3 -c "
import json,sys
r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ok=[x for x in r if (x.get('metrics') or {}).get('time_to_first_token')]
print(f'{len(ok)}/{len(r)} records have TTFT')
sys.exit(0 if r and len(ok)/len(r) > 0.95 else 1)" profile_export.jsonl
```

Also re-run gate C1 after **every** arm switch: patching the EPP gives it a new
pod IP, so a subscription count taken before the switch says nothing about the
pod now serving.

### D3. Verify the instrument can detect absence

Two checks in this campaign returned "0" for reasons unrelated to the thing
being measured, and both would have inverted the conclusion.

**`kubectl logs --tail=N` returns the LAST N lines.** A startup-log capture
written as `logs --tail=400 | head -200` contains no startup lines at all: at
`--v=5` the EPP emits thousands of trace lines within seconds of boot. The
capture reported `p2p-source-producer mentions: 0` while the plugin was in fact
instantiated and running. Stream from the beginning and let `head` close it:

```bash
kubectl -n $NS logs "$POD" -c epp 2>/dev/null | head -400 > startup.log
```

**Prove the positive case before trusting the negative.** Before believing "0
mentions", assert the capture contains lines that must be present regardless --
`Flags processed`, `Loaded raw configuration`, `Instantiated all plugins`. If
those are missing, the capture is broken, not the subject.

The general rule: a gate that can only return "absent" is not a gate. It must
distinguish "the thing is missing" from "I am not looking where it is".

### D4. Never edit a running script

Bash reads scripts incrementally from disk. Patching `run_fork_arm.sh` while it
executed shifted byte offsets under the live interpreter, which hit a syntax
error mid-campaign and skipped the artifact pull for an arm that had already
finished. The data survived on the PVC, but two of four arms were lost.

Edit a copy and swap between runs, or stop the run first.

## E. Reading the counters

Three ways to be wrong, all observed:

**E1 — `series` is a list, one entry per rank.** A reader that walks the JSON and
keeps one value reports a single rank. On a 16-rank cell that was a **4.8x**
undercount (12,722,175 reported vs 61,374,262 actual).

**E2 — series count must equal the expected rank count.** Summing correctly
doesn't help if the export only sees half the fleet. One export tonight had 16
series for a 32-rank cell and just **6** for `kv_offload_load_bytes`. Warn when
`len(series) < expected_ranks`; role attribution is impossible in that state.

**E3 — never sum prefill and decode external counters.** A P/D decode rank
fetches from prefill over NIXL by design. This run's **control** arm — P2P off
entirely — reported `ext_cache_hit=42.8%`. Read as engagement, that is a
completely fabricated result.

Related: `kv_offload_load_bytes` counts local CPU->GPU restores too, so
loaded-bytes alone is never pull evidence.

## F. Workload actually exercises the mechanism

| # | Gate | Why |
|---|---|---|
| F1 | Shared prefix > pull-vs-recompute crossover (~8,650 tokens measured) | Below it a pull is slower than recompute |
| F2 | `--max-context-length` == server `--max-model-len` | A larger client cap admits traces that overflow at the server and count toward the validity threshold |
| F3 | Pull opportunities exist structurally | Affinity routing captures 96-97% of available reuse, so the residual is small unless siblings are forced apart |

F3 is the one worth stating loudest in a guide. P2P addresses the reuse that
placement *cannot* capture. On agentic traces that means parallel subagent
fan-out — siblings sharing a parent prefix cannot all sit on the holder rank.
Chasing engagement by raising concurrency instead pushes the cluster to
saturation, where any latency win is unpublishable.

## Suggested shape in the guide

A single `verify-p2p.sh` that runs A -> B -> C and refuses to proceed. D is
campaign protocol, E is a short "reading the counters" section, and F belongs in
the benchmarking guidance rather than a script.

Fail-closed matters: each of these is a case where the run completes, produces
plausible numbers, and the numbers mean nothing.
