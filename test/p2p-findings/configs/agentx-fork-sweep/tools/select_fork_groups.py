#!/usr/bin/env python3
"""Rank Weka corpus fork groups by their P2P pull opportunity.

A fork group is a burst of sibling subagents spawned by one parent. Siblings
cannot all be placed on the rank holding their shared prefix, so every sibling
beyond the holder is a pull candidate. Value scales as

    saving ~= pulls * shared_prefix_tokens / avoided_prefill_rate

with the rate measured at ~6,100 tok/s (two runs agreeing within 3%).

Emits a pre-registered candidate list: which trace, which subagents, which
source rows, and the predicted saving, before any run happens.

    pip install "datasets>=2" pyarrow
    ./select_fork_groups.py --top 25
    ./select_fork_groups.py --min-prefix 4096 --max-prefix 9216 --top 10  # negative controls
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass

DEFAULT_DATASET = "semianalysisai/cc-traces-weka-062126"

# Avoided prefill implied by Maroon's two runs: 6,069 and 6,273 tok/s.
DEFAULT_RATE = 6100.0

# A sibling whose inherited prefix is essentially the parent's own context needs
# no cold seed -- the parent's rank already holds it, so every child can pull.
INHERITED_SEED_FREE = 0.95

REQ_TYPES = ("n", "s")


@dataclass
class ForkGroup:
    trace_id: str
    group_index: int
    width: int
    agent_ids: list[str]
    first_spawn_s: float
    last_spawn_s: float
    span_s: float
    max_gap_s: float
    shared_prefix_blocks: int
    shared_prefix_tokens: int
    inherited_fraction: float
    cold_seed: int
    pulls: int
    predicted_saving_s: float
    peak_start_context_tokens: int
    peak_context_tokens: int
    child_first_input_tokens: list[int]
    source_row_range: list[int]
    hash_coverage: float


def lcp(a: list[int], b: list[int]) -> list[int]:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return a[:n]


def lcp_all(chains: list[list[int]]) -> list[int]:
    if not chains:
        return []
    out = chains[0]
    for c in chains[1:]:
        out = lcp(out, c)
        if not out:
            break
    return out


def inner_requests(entry: dict) -> list[dict]:
    return [r for r in (entry.get("requests") or []) if r.get("type") in REQ_TYPES]


def first_request(entry: dict) -> dict | None:
    reqs = inner_requests(entry)
    if not reqs:
        return None
    return min(reqs, key=lambda r: r.get("t", 0.0))


def tokens(req: dict, key: str) -> int:
    # Models declare aliases in/out; raw corpus rows use the short names.
    return int(req.get(key) or req.get({"in": "input_length", "out": "output_length"}[key]) or 0)


def parent_context_chain(trace: dict, spawn_t: float) -> list[int]:
    """hash_ids of the last parent turn at or before the spawn."""
    best, best_t = [], None
    for r in trace.get("requests", []):
        if r.get("type") not in REQ_TYPES:
            continue
        t = r.get("t", 0.0)
        if t <= spawn_t and (best_t is None or t >= best_t):
            best_t, best = t, list(r.get("hash_ids") or [])
    return best


def group_subagents(trace: dict, burst_window: float) -> list[list[tuple[int, dict]]]:
    """Cluster subagent entries into bursts by spawn-time proximity."""
    entries = [
        (i, r) for i, r in enumerate(trace.get("requests", []))
        if r.get("type") == "subagent"
    ]
    entries.sort(key=lambda pair: pair[1].get("t", 0.0))

    groups: list[list[tuple[int, dict]]] = []
    current: list[tuple[int, dict]] = []
    for idx, entry in entries:
        if not current:
            current = [(idx, entry)]
            continue
        prev_t = current[-1][1].get("t", 0.0)
        if entry.get("t", 0.0) - prev_t <= burst_window:
            current.append((idx, entry))
        else:
            groups.append(current)
            current = [(idx, entry)]
    if current:
        groups.append(current)
    return groups


def build_group(trace: dict, gidx: int, members: list[tuple[int, dict]], rate: float) -> ForkGroup | None:
    if len(members) < 2:
        return None

    block_size = int(trace.get("block_size") or 64)
    firsts = [(i, e, first_request(e)) for i, e in members]
    firsts = [(i, e, r) for i, e, r in firsts if r is not None and r.get("hash_ids")]
    if len(firsts) < 2:
        return None

    chains = [list(r["hash_ids"]) for _, _, r in firsts]
    shared = lcp_all(chains)
    if not shared:
        return None

    spawn_times = [e.get("t", 0.0) for _, e, _ in firsts]
    gaps = [b - a for a, b in zip(spawn_times, spawn_times[1:])] or [0.0]

    parent_chain = parent_context_chain(trace, min(spawn_times))
    inherited = len(lcp(shared, parent_chain)) / len(shared)
    cold_seed = 0 if inherited >= INHERITED_SEED_FREE else 1
    pulls = len(firsts) - cold_seed

    shared_tokens = len(shared) * block_size
    first_inputs = [tokens(r, "in") for _, _, r in firsts]

    # Two context peaks. The branch-start peak governs whether the pull-bearing
    # requests fit the server; the full peak governs whether replaying the
    # subagents to completion would overflow it later.
    peak_start = max(tokens(r, "in") + tokens(r, "out") for _, _, r in firsts)
    peak = 0
    for _, e, _ in firsts:
        for r in inner_requests(e):
            peak = max(peak, tokens(r, "in") + tokens(r, "out"))

    # Sanity: a first request's hash chain should cover most of its input. A low
    # ratio means hash_ids are incremental rather than cumulative here and the
    # LCP is not a prefix length -- surfaced rather than silently trusted.
    coverage = min(
        1.0,
        sum(len(c) * block_size for c in chains) / max(1, sum(first_inputs)),
    )

    rows = [i for i, _, _ in firsts]

    return ForkGroup(
        trace_id=str(trace.get("id")),
        group_index=gidx,
        width=len(firsts),
        agent_ids=[str(e.get("agent_id")) for _, e, _ in firsts],
        first_spawn_s=round(min(spawn_times), 3),
        last_spawn_s=round(max(spawn_times), 3),
        span_s=round(max(spawn_times) - min(spawn_times), 3),
        max_gap_s=round(max(gaps), 3),
        shared_prefix_blocks=len(shared),
        shared_prefix_tokens=shared_tokens,
        inherited_fraction=round(inherited, 4),
        cold_seed=cold_seed,
        pulls=pulls,
        predicted_saving_s=round(pulls * shared_tokens / rate, 2),
        peak_start_context_tokens=peak_start,
        peak_context_tokens=peak,
        child_first_input_tokens=first_inputs,
        source_row_range=[min(rows), max(rows)],
        hash_coverage=round(coverage, 3),
    )


def load_traces(dataset: str, split: str):
    try:
        from datasets import load_dataset
    except ImportError:
        sys.exit("need `pip install datasets pyarrow`")

    ds = load_dataset(dataset, split=split)
    for row in ds:
        if isinstance(row, dict) and "requests" in row and "id" in row:
            yield row
            continue
        # Corpus variants wrap the trace as a JSON string in a single column.
        for value in row.values():
            if isinstance(value, str) and value.lstrip().startswith("{"):
                try:
                    trace = json.loads(value)
                except json.JSONDecodeError:
                    continue
                if "requests" in trace:
                    yield trace
                    break


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--split", default="train")
    ap.add_argument("--burst-window", type=float, default=30.0,
                    help="max spawn gap (s) between consecutive siblings in one group")
    ap.add_argument("--min-width", type=int, default=2)
    ap.add_argument("--min-prefix", type=int, default=70000, help="shared prefix tokens")
    ap.add_argument("--max-prefix", type=int, default=None)
    ap.add_argument("--max-context", type=int, default=120000,
                    help="drop groups whose branch-start input+output would overflow the server")
    ap.add_argument("--max-full-context", type=int, default=0,
                    help="also bound the peak across the subagents' whole lives (0 = off)")
    ap.add_argument("--rate", type=float, default=DEFAULT_RATE)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--json", help="write the full ranked list here")
    args = ap.parse_args()

    found: list[ForkGroup] = []
    for trace in load_traces(args.dataset, args.split):
        for gidx, members in enumerate(group_subagents(trace, args.burst_window)):
            g = build_group(trace, gidx, members, args.rate)
            if g is None:
                continue
            if g.width < args.min_width:
                continue
            if g.shared_prefix_tokens < args.min_prefix:
                continue
            if args.max_prefix and g.shared_prefix_tokens > args.max_prefix:
                continue
            if args.max_context and g.peak_start_context_tokens > args.max_context:
                continue
            if args.max_full_context and g.peak_context_tokens > args.max_full_context:
                continue
            found.append(g)

    found.sort(key=lambda g: (-g.predicted_saving_s, g.max_gap_s))

    hdr = f"{'trace':14} {'grp':>3} {'W':>3} {'pulls':>5} {'prefix_tok':>10} {'inh':>5} {'maxgap_s':>8} {'pred_s':>7} {'start_ctx':>9} {'full_ctx':>9} {'cov':>5}"
    print(hdr)
    print("-" * len(hdr))
    for g in found[: args.top]:
        print(f"{g.trace_id[:14]:14} {g.group_index:3d} {g.width:3d} {g.pulls:5d} "
              f"{g.shared_prefix_tokens:10,d} {g.inherited_fraction:5.2f} {g.max_gap_s:8.1f} "
              f"{g.predicted_saving_s:7.1f} {g.peak_start_context_tokens:9,d} {g.peak_context_tokens:9,d} {g.hash_coverage:5.2f}")

    print(f"\n{len(found)} groups matched; total predicted saving "
          f"{sum(g.predicted_saving_s for g in found):,.0f} s over "
          f"{sum(g.pulls for g in found):,d} pull events")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump([asdict(g) for g in found], fh, indent=2)
        print(f"wrote {args.json}")


if __name__ == "__main__":
    main()
