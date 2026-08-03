#!/usr/bin/env python3
"""Per-branch analysis of a fork-group A/B, against pre-registered predictions.

The aggregate mean over all requests dilutes a handful of pull events by an
order of magnitude. This scores the branch starts -- the only requests that can
pull -- classifies each one, and tests the measured saving against the
manifest's prediction.

    ./analyze_fork_run.py --manifest windows/<w>/manifest.json \\
        --arm control:artifacts/control --arm p2p:artifacts/p2p \\
        --epp p2p:logs/epp-p2p.jsonl

Record schema (aiperf profile_export.jsonl):
  metadata: conversation_id, turn_index, agent_depth, x_request_id,
            benchmark_phase, was_cancelled, context_overflow_skip
  metrics : time_to_first_token, input_sequence_length,
            usage_prompt_cache_read_tokens, request_latency, ...
"""
from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys


def val(rec: dict, name: str):
    m = (rec.get("metrics") or {}).get(name)
    return m.get("value") if isinstance(m, dict) else m


def load_records(artifact_dir: str) -> list[dict]:
    p = pathlib.Path(artifact_dir)
    f = p / "profile_export.jsonl"
    if not f.exists():
        sys.exit(f"{f} not found")
    out = []
    for line in f.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        md = rec.get("metadata", {})
        if md.get("benchmark_phase") != "profiling":
            continue
        if md.get("was_cancelled") or md.get("context_overflow_skip"):
            continue
        out.append(rec)
    return out


def branch_starts(records: list[dict]) -> dict[str, dict]:
    """First profiling turn of each subagent conversation, keyed by conversation."""
    best: dict[str, dict] = {}
    for rec in records:
        md = rec["metadata"]
        if int(md.get("agent_depth") or 0) <= 0:
            continue
        cid = md.get("conversation_id")
        cur = best.get(cid)
        if cur is None or int(md.get("turn_index", 0)) < int(cur["metadata"].get("turn_index", 0)):
            best[cid] = rec
    return best


# p2psource/producer.go PreRequest emits exactly three messages, all at
# V(logging.TRACE) -- so the EPP must run with --v=5 or higher or none of this
# appears and per-request attribution is impossible.
MSG_HEADER = "set KV cache source header"     # requestID, value            -> pulled
MSG_EVAL = "evaluating KV cache source"       # requestID, best,            -> considered
                                              # bestCachedTokens, computing,
                                              # computingCachedTokens
MSG_NOPEER = "no best-match peer stashed"     # requestID                   -> no holder known


def load_directives(path: str) -> dict[str, dict]:
    """Per-request router decision, keyed by requestID.

    Returns {rid: {"state": pulled|rejected|no_peer, "best_cached": int,
                   "computing_cached": int, "delta": int, "source": str}}.
    A request that was evaluated but got no header is the interesting bucket:
    the router knew a better-cached peer and declined it, so the delta tells
    you whether the gate or a self-match was responsible.
    """
    out: dict[str, dict] = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = ev.get("msg") or ev.get("message") or ""
        rid = ev.get("requestID") or ev.get("request_id")
        if not rid:
            continue
        rid = str(rid)
        if msg == MSG_NOPEER:
            out.setdefault(rid, {})["state"] = "no_peer"
        elif msg == MSG_EVAL:
            best = int(ev.get("bestCachedTokens") or 0)
            comp = int(ev.get("computingCachedTokens") or 0)
            rec = out.setdefault(rid, {})
            rec.update({
                "best_cached": best,
                "computing_cached": comp,
                "delta": best - comp,
                "best_host": ev.get("best"),
                "computing_host": ev.get("computing"),
            })
            rec.setdefault("state", "rejected")
        elif msg == MSG_HEADER:
            rec = out.setdefault(rid, {})
            rec["state"] = "pulled"
            rec["source"] = ev.get("value")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--arm", action="append", required=True,
                    help="name:artifact_dir (give the control first)")
    ap.add_argument("--epp", action="append", default=[],
                    help="name:epp_log.jsonl for source-directive attribution")
    ap.add_argument("--json", help="write the per-branch table here")
    args = ap.parse_args()

    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    pred = manifest["prediction"]
    sel = manifest["selection"]

    arms: dict[str, dict] = {}
    order: list[str] = []
    for spec in args.arm:
        name, _, path = spec.partition(":")
        order.append(name)
        arms[name] = {"starts": branch_starts(load_records(path)), "dir": path}
    for spec in args.epp:
        name, _, path = spec.partition(":")
        if name in arms:
            arms[name]["directives"] = load_directives(path)

    control, *rest = order
    if not rest:
        sys.exit("need at least two arms")
    treat = rest[0]

    # The weka loader splits each subagent's inner context chains into extra
    # sibling conversations (":fa:NNN"). Only the "::sa:<agent>" main chains are
    # the fork siblings that share the group prefix, so score those and report
    # the rest separately rather than diluting the population.
    group_sessions = {b["session_id"] for b in manifest["branches"]}
    both = set(arms[control]["starts"]) & set(arms[treat]["starts"])
    common = sorted(both & group_sessions)
    extra = sorted(both - group_sessions)
    if extra:
        print(f"note: {len(extra)} child conversations outside the fork group "
              f"(inner :fa: chains) excluded from scoring\n")
    print(f"window {manifest['window_id']}  W={sel['width']}  "
          f"prefix={sel['shared_prefix_tokens']:,} tok")
    print(f"predicted: {pred['expected_pulls']} pulls x "
          f"{pred['expected_saving_per_pull_s']:.2f}s = {pred['expected_total_saving_s']:.1f}s")
    print(f"branch starts matched in both arms: {len(common)} of {sel['width']}\n")

    rows = []
    hdr = (f"{'branch (conversation)':38} {'ISL':>8} {control[:9]:>9} {treat[:9]:>9} "
           f"{'delta_ms':>9} {'pull':>5} {'cache_read':>11}")
    print(hdr)
    print("-" * len(hdr))
    for cid in common:
        c, t = arms[control]["starts"][cid], arms[treat]["starts"][cid]
        c_ttft, t_ttft = val(c, "time_to_first_token"), val(t, "time_to_first_token")
        if c_ttft is None or t_ttft is None:
            continue
        directives = arms[treat].get("directives")
        rid = str(t["metadata"].get("x_request_id"))
        dec = None if directives is None else directives.get(rid, {})
        state = None if dec is None else dec.get("state", "unseen")
        pulled = None if state is None else (state == "pulled")
        cache_read = val(t, "usage_prompt_cache_read_tokens")
        row = {
            "conversation_id": cid,
            "isl": val(t, "input_sequence_length"),
            f"{control}_ttft_ms": c_ttft,
            f"{treat}_ttft_ms": t_ttft,
            "delta_ms": t_ttft - c_ttft,
            "pulled": pulled,
            "router_state": state,
            "router_delta": (dec or {}).get("delta"),
            "cache_read_tokens": cache_read,
        }
        rows.append(row)
        mark = "-" if state is None else {"pulled": "yes", "rejected": "rej",
                                          "no_peer": "none"}.get(state, state[:4])
        print(f"{cid[:38]:38} {row['isl'] or 0:8,.0f} {c_ttft:9,.0f} {t_ttft:9,.0f} "
              f"{row['delta_ms']:9,.0f} {mark:>5} {cache_read or 0:11,.0f}")

    deltas = [r["delta_ms"] for r in rows]
    pulled = [r for r in rows if r["pulled"]]
    unpulled = [r for r in rows if r["pulled"] is False]

    print(f"\nall branch starts : n={len(deltas)} "
          f"median {statistics.median(deltas):,.0f} ms  mean {statistics.fmean(deltas):,.0f} ms")

    if pulled:
        saved = -sum(r["delta_ms"] for r in pulled) / 1000.0
        per = saved / len(pulled)
        rate = sel["shared_prefix_tokens"] / per if per > 0 else float("nan")
        print(f"pulled            : n={len(pulled)} of {pred['expected_pulls']} predicted  "
              f"saved {saved:,.1f}s  per pull {per:,.2f}s")
        print(f"  implied avoided-prefill rate: {rate:,.0f} tok/s "
              f"(prediction used {pred['avoided_prefill_rate_tok_s']:,.0f})")
        print(f"  measured / predicted saving : {saved / pred['expected_total_saving_s']:.2f}")
    if unpulled:
        med = statistics.median(r["delta_ms"] for r in unpulled)
        print(f"not pulled        : n={len(unpulled)}  median delta {med:,.0f} ms "
              f"(expected ~0; this is the untouched population and calibrates noise)")
        rej = [r for r in unpulled if r.get("router_state") == "rejected"]
        nop = [r for r in unpulled if r.get("router_state") == "no_peer"]
        if rej:
            deltas_tok = [r["router_delta"] for r in rej if r.get("router_delta") is not None]
            med_tok = statistics.median(deltas_tok) if deltas_tok else 0
            print(f"  rejected by the router: n={len(rej)}, median cached-token advantage "
                  f"{med_tok:,.0f} -- a peer WAS known and declined. If this sits just under "
                  f"minCachedTokenDelta the gate is costing pulls; that is recoverable value.")
        if nop:
            print(f"  no peer known         : n={len(nop)} -- the index had no holder at "
                  f"dispatch (publication lag, or podCacheSize evicted it).")
    if arms[treat].get("directives") is None:
        print("\nNOTE: no --epp log for the treatment arm, so pull attribution is absent. "
              "Per-branch classification needs the router's source directives; "
              "counter totals alone cannot attribute a pull to a request. "
              "The EPP must also run with --v=5 or higher: these lines are V(TRACE).")

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(
            {"manifest": manifest, "rows": rows}, indent=2))
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
