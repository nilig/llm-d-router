#!/usr/bin/env python3
"""Sum aiperf server_metrics_export.json across every engine series.

`metrics[<name>].series` is a LIST with one entry per DP rank. Any reader that
walks the tree and keeps a single value reports one rank and undercounts the
pool -- on a 16-rank cell that was a 4.8x error.

    ./sum_server_metrics.py run-a/server_metrics_export.json run-b/... --expect-ranks 32
"""
from __future__ import annotations

import argparse
import json

INTERESTING = (
    "vllm:external_prefix_cache_hits",
    "vllm:external_prefix_cache_queries",
    "vllm:kv_offload_load_bytes",
    "vllm:kv_offload_store_bytes",
    "vllm:prefix_cache_hits",
    "vllm:prefix_cache_queries",
)


def series_of(metric: dict) -> list[dict]:
    s = metric.get("series")
    if isinstance(s, list):
        return s
    return [s] if isinstance(s, dict) else []


def load(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh).get("metrics", {})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("exports", nargs="+")
    ap.add_argument("--expect-ranks", type=int, default=0,
                    help="warn if a metric has fewer series than this (label collisions "
                         "across pods hide ranks and make a role split impossible)")
    ap.add_argument("--per-engine", action="store_true")
    ap.add_argument("--metric", action="append", help="override the default metric list")
    args = ap.parse_args()

    names = args.metric or list(INTERESTING)

    for path in args.exports:
        metrics = load(path)
        print(f"\n=== {path}")
        for name in names:
            m = metrics.get(name)
            if not m:
                continue
            s = series_of(m)
            total = sum(float(x.get("stats", {}).get("total") or 0) for x in s)
            rate = sum(float(x.get("stats", {}).get("rate") or 0) for x in s)
            engines = sorted({str((x.get("labels") or {}).get("engine")) for x in s})
            print(f"  {name}")
            print(f"    series={len(s)} engines={len(engines)} total={total:,.0f} rate={rate:,.1f}/s")
            if args.expect_ranks and len(s) < args.expect_ranks:
                print(f"    WARNING: {len(s)} series < {args.expect_ranks} expected ranks -- "
                      f"engine labels collide across pods, so this file cannot attribute "
                      f"prefill vs decode. Scrape pods directly for a role split.")
            if args.per_engine:
                for x in sorted(s, key=lambda y: int((y.get('labels') or {}).get('engine', -1))):
                    lab = (x.get("labels") or {}).get("engine")
                    print(f"      engine {lab:>3}: {float(x['stats']['total']):,.0f}")

        hits = metrics.get("vllm:external_prefix_cache_hits")
        qrys = metrics.get("vllm:external_prefix_cache_queries")
        if hits and qrys:
            h = sum(float(x["stats"]["total"]) for x in series_of(hits))
            q = sum(float(x["stats"]["total"]) for x in series_of(qrys))
            if q:
                print(f"  external hit rate: {100 * h / q:.1f}%  ({h:,.0f} / {q:,.0f})")
                print("    note: a P/D decode rank fetches from prefill by design, so a rate "
                      "near 100% is NIXL pairing, not a P2P pull. Never sum prefill and "
                      "decode connector counters as one engagement figure.")


if __name__ == "__main__":
    main()
