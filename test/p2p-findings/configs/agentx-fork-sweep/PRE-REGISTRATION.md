# Fork-group width sweep: pre-registered targets

Predictions below are fixed before any run. Each window's `manifest.json` holds
the same numbers machine-readable.

Model: `saving = pulls x shared_prefix_tokens / rate`, rate = 6,100 tok/s
(implied by Maroon's two real-fork runs: 6,069 and 6,273, agreeing within 3%).

`pulls = W - 1`. The cold seed is unavoidable: across all 209 corpus groups with
W>=3 and prefix >=12,288, the children's inherited fraction from the parent is
0.000 at the median and 0.076 at the maximum, so the first branch always
computes the prefix.

## Band A: ~40K prefix, width ladder

| window | W | prefix tok | pulls | predicted | peak ctx |
|---|---:|---:|---:|---:|---:|
| `21cde366f5bd2f-g5` | 44 | 40,640 | 43 | 286.5 s | 116,732 |
| `631738ac313214-g0` | 43 | 40,320 | 42 | 277.6 s | **56,002** |
| `21cde366f5bd2f-g7` | 30 | 40,384 | 29 | 192.0 s | 106,004 |
| `631738ac313214-g11` | 15 | 40,448 | 14 | 92.8 s | 193,834 |
| `631738ac313214-g17` | 6 | 41,600 | 5 | 34.1 s | 196,461 |
| `21cde366f5bd2f-g0` | 5 | 41,600 | 4 | 27.3 s | 99,105 |
| `cc95f57029d3e5-g0` | 4 | 41,728 | 3 | 20.5 s | 214,864 |
| `631738ac313214-g24` | 3 | 41,664 | 2 | 13.7 s | 104,443 |
| `631738ac313214-g16` | 2 | 41,280 | 1 | 6.8 s | 96,732 |

143 pull events, 951 s predicted.

## Band B: ~70K prefix, width ladder

| window | W | prefix tok | pulls | predicted | note |
|---|---:|---:|---:|---:|---|
| `c97f752dfb70c0-g2` | 10 | 70,528 | 9 | 104.1 s | |
| `a2a25745b7f9a0-g1` | 10 | 70,208 | 9 | 103.6 s | |
| `d5654f5758cb49-g3` | 8 | 75,520 | 7 | 86.7 s | replication anchor |
| `208d6e28928b0b-g1` | 4 | 72,128 | 3 | 35.5 s | |
| `9a7043c3f0a1f0-g0` | 2 | 72,128 | 1 | 11.8 s | |

29 pull events, 342 s predicted.

Two bands at different prefix sizes make this a 2-D test of the model rather
than a single line: width varies within a band, prefix varies across bands.
`d5654f5758cb49-g3` is Maroon's measured group, so it doubles as a
cross-namespace replication check.

## Primary endpoint

Per-pull avoided prefill, measured on branch starts only. The all-request mean
dilutes a handful of pull events by an order of magnitude; the branch starts are
the only requests that can pull.

Secondary: fork-group completion time (last branch's last token), which is the
metric an agentic user actually waits on.

## Classification

`analyze_fork_run.py` reads the router's own decisions from the EPP stream.
`p2psource/producer.go` `PreRequest` emits three messages, all at
`V(logging.TRACE)`:

| message | meaning |
|---|---|
| `set KV cache source header` | pulled |
| `evaluating KV cache source` without a header | a peer was known and declined |
| `no best-match peer stashed` | no holder in the index at dispatch |

The middle bucket is recoverable value: `bestCachedTokens - computingCachedTokens`
against `minCachedTokenDelta` says whether the gate or a self-match declined it.

**The EPP must run with `--v=5` or higher** or none of these lines exist and
per-request attribution is impossible.

## Negative control

Re-run one window with `minCachedTokenDelta` raised above its shared prefix.
Zero pulls by construction, workload byte-identical, predicted zero difference.
Preferred over selecting a small-prefix group: only one group exists in the
3,000-8,000 band, and holding the workload fixed is a stronger control.

## Open question on the rate

The arm configs set `peakPrefillThroughput: 3585` on
`prefix-cache-affinity-filter`, while the measured avoided-prefill rate is
~6,100 tok/s. If 3,585 is the accurate per-rank prefill rate then every
prediction here is ~1.7x low. Re-derive from the first run before treating the
predictions as calibrated.
