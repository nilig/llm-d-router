#!/usr/bin/env python3
"""Extract one fork group into a standalone replayable Weka trace.

Produces a directory usable with `--custom-dataset-type weka_trace`, plus a
manifest recording the pre-registered predictions for that group so the
expected result is fixed on disk before any run.

The window keeps the parent turn preceding the burst (the loader drops
subagents with no preceding parent turn, and that turn is the SPAWN anchor),
the group's subagent entries, and optionally the following parent turn so the
parent waits on SPAWN_JOIN and a task-completion time exists.

Timestamps are rebased so the window starts at t=0. Parent and inner-request
`t` are shifted by the same offset, preserving the loader's spawn-relative
ordering rule.

    ./extract_fork_window.py --trace-id 631738ac313214 --group 0 --out-dir windows/
"""
from __future__ import annotations

import argparse
import copy
import json
import pathlib
import sys

from select_fork_groups import (
    DEFAULT_DATASET,
    DEFAULT_RATE,
    REQ_TYPES,
    build_group,
    group_subagents,
    inner_requests,
    load_traces,
    tokens,
)


def anchor_indices(trace: dict, first_row: int, last_row: int) -> tuple[int | None, int | None]:
    """Nearest parent turn before the burst, and the first one after it."""
    before = after = None
    for i, r in enumerate(trace["requests"]):
        if r.get("type") not in REQ_TYPES:
            continue
        if i < first_row:
            before = i
        elif i > last_row and after is None:
            after = i
    return before, after


def shift(obj: dict, delta: float) -> dict:
    obj = copy.deepcopy(obj)
    obj["t"] = round(obj.get("t", 0.0) - delta, 6)
    for r in obj.get("requests", []) or []:
        if "t" in r:
            r["t"] = round(r["t"] - delta, 6)
    return obj


def trim_inner(entry: dict, keep: str) -> dict:
    if keep == "all":
        return entry
    reqs = inner_requests(entry)
    reqs.sort(key=lambda r: r.get("t", 0.0))
    n = 1 if keep == "first" else int(keep)
    entry = copy.deepcopy(entry)
    entry["requests"] = reqs[:n]
    return entry


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--split", default="train")
    ap.add_argument("--trace-id", required=True, help="full id or unique prefix")
    ap.add_argument("--group", type=int, required=True)
    ap.add_argument("--burst-window", type=float, default=30.0,
                    help="must match the value used during selection")
    ap.add_argument("--keep-inner", default="all",
                    help="'all', 'first', or an integer count of inner requests per subagent")
    ap.add_argument("--no-join", action="store_true",
                    help="omit the following parent turn (no SPAWN_JOIN, no task-completion metric)")
    ap.add_argument("--rate", type=float, default=DEFAULT_RATE)
    ap.add_argument("--out-dir", default="windows")
    args = ap.parse_args()

    target = None
    for trace in load_traces(args.dataset, args.split):
        if str(trace["id"]).startswith(args.trace_id):
            target = trace
            break
    if target is None:
        sys.exit(f"trace {args.trace_id} not found")

    groups = group_subagents(target, args.burst_window)
    if args.group >= len(groups):
        sys.exit(f"group {args.group} out of range ({len(groups)} groups)")
    members = groups[args.group]
    meta = build_group(target, args.group, members, args.rate)
    if meta is None:
        sys.exit("group did not resolve (fewer than 2 members with hash_ids)")

    first_row, last_row = meta.source_row_range
    before, after = anchor_indices(target, first_row, last_row)
    if before is None:
        sys.exit("no preceding parent turn; the loader would drop these subagents")

    keep_rows = [before] + [i for i, _ in members]
    if after is not None and not args.no_join:
        keep_rows.append(after)
    keep_rows = sorted(set(keep_rows))

    delta = target["requests"][before].get("t", 0.0)
    out_requests = []
    for i in keep_rows:
        r = target["requests"][i]
        if r.get("type") == "subagent":
            r = trim_inner(r, args.keep_inner)
        out_requests.append(shift(r, delta))

    window = {
        "id": f"{target['id']}-g{args.group}",
        "models": target["models"],
        "block_size": target["block_size"],
        "hash_id_scope": target["hash_id_scope"],
        "requests": out_requests,
    }

    out = pathlib.Path(args.out_dir) / f"{target['id'][:14]}-g{args.group}"
    out.mkdir(parents=True, exist_ok=True)
    trace_path = out / "trace.json"
    trace_path.write_text(json.dumps(window))

    branches = []
    for (row, entry), first_in in zip(members, meta.child_first_input_tokens):
        reqs = inner_requests(entry)
        branches.append({
            "agent_id": entry.get("agent_id"),
            "session_id": f"{window['id']}::sa:{entry.get('agent_id')}",
            "source_row": row,
            "spawn_s": round(entry.get("t", 0.0) - delta, 3),
            "first_input_tokens": first_in,
            "inner_requests": len(reqs),
        })
    branches.sort(key=lambda b: b["spawn_s"])

    manifest = {
        "source_trace": target["id"],
        "group_index": args.group,
        "burst_window_s": args.burst_window,
        "window_id": window["id"],
        "anchor_row": before,
        "join_row": None if args.no_join else after,
        "kept_rows": keep_rows,
        "timestamp_offset_s": delta,
        "block_size": target["block_size"],
        "selection": {
            "width": meta.width,
            "shared_prefix_blocks": meta.shared_prefix_blocks,
            "shared_prefix_tokens": meta.shared_prefix_tokens,
            "inherited_fraction": meta.inherited_fraction,
            "max_gap_s": meta.max_gap_s,
            "span_s": meta.span_s,
            "peak_start_context_tokens": meta.peak_start_context_tokens,
            "peak_context_tokens": meta.peak_context_tokens,
        },
        "prediction": {
            "avoided_prefill_rate_tok_s": args.rate,
            "cold_seed_branches": meta.cold_seed,
            "expected_pulls": meta.pulls,
            "expected_saving_per_pull_s": round(meta.shared_prefix_tokens / args.rate, 3),
            "expected_total_saving_s": meta.predicted_saving_s,
            "expected_pull_tokens_total": meta.pulls * meta.shared_prefix_tokens,
        },
        "branches": branches,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"window   {out}")
    print(f"  trace  {trace_path} ({trace_path.stat().st_size:,} bytes)")
    print(f"  rows   anchor={before} subagents={first_row}..{last_row} join={manifest['join_row']}")
    print(f"  W={meta.width} prefix={meta.shared_prefix_tokens:,} tok "
          f"({meta.shared_prefix_blocks} blocks)")
    print(f"  predicts {meta.pulls} pulls x "
          f"{manifest['prediction']['expected_saving_per_pull_s']:.2f}s = "
          f"{meta.predicted_saving_s:.1f}s avoided prefill")


if __name__ == "__main__":
    main()
