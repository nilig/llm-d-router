#!/usr/bin/env python3
"""Summarise the router's P2P source decisions from an EPP stream.

The question this answers is not "was P2P faster" but "did a peer ever hold
meaningfully more of the prefix than the rank we chose". That quantity --
bestCachedTokens minus computingCachedTokens -- is what minCachedTokenDelta
gates on, and it is measurable without any latency comparison.

    ./delta_stats.py epp-stream.jsonl --gate 12288 --label "K=4"
"""
from __future__ import annotations

import argparse
import json
import statistics


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--gate", type=int, default=12288)
    ap.add_argument("--label", default="")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    evals, pulls, nopeer = [], 0, 0
    for line in open(args.stream):
        try:
            d = json.loads(line)
        except Exception:
            continue
        m = d.get("msg")
        if m == "set KV cache source header":
            pulls += 1
        elif m == "no best-match peer stashed":
            nopeer += 1
        elif m == "evaluating KV cache source":
            evals.append((
                int(d.get("bestCachedTokens") or 0),
                int(d.get("computingCachedTokens") or 0),
                d.get("best"), d.get("computing"),
            ))

    selfm = sum(1 for b, c, bh, ch in evals if bh == ch)
    deltas = sorted(b - c for b, c, bh, ch in evals if bh != ch)
    over = sum(1 for x in deltas if x >= args.gate)

    out = {
        "label": args.label,
        "evaluations": len(evals),
        "no_peer": nopeer,
        "self_match": selfm,
        "non_self": len(deltas),
        "delta_min": deltas[0] if deltas else None,
        "delta_median": int(statistics.median(deltas)) if deltas else None,
        "delta_p90": deltas[int(0.9 * (len(deltas) - 1))] if deltas else None,
        "delta_max": deltas[-1] if deltas else None,
        "clearing_gate": over,
        "gate": args.gate,
        "pulls": pulls,
    }
    if args.json:
        print(json.dumps(out))
        return

    lbl = f"[{args.label}] " if args.label else ""
    print(f"{lbl}evaluations={len(evals)} no_peer={nopeer} self_match={selfm} non_self={len(deltas)}")
    if deltas:
        print(f"{lbl}  best-minus-computing tokens: min={deltas[0]:,} "
              f"median={int(statistics.median(deltas)):,} "
              f"p90={deltas[int(0.9*(len(deltas)-1))]:,} max={deltas[-1]:,}")
        print(f"{lbl}  clearing gate {args.gate:,}: {over} of {len(deltas)} "
              f"({100*over/len(deltas):.1f}%)")
    print(f"{lbl}  pulls issued: {pulls}")


if __name__ == "__main__":
    main()
