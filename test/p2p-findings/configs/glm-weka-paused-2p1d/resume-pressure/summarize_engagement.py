#!/usr/bin/env python3
"""Summarize P2P source decisions from an EPP JSONL stream."""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <epp-stream.jsonl>", file=sys.stderr)
        return 2

    evaluations = []
    directives = set()
    requests = set()
    with open(sys.argv[1], encoding="utf-8", errors="ignore") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            request_id = event.get("requestID")
            if request_id:
                requests.add(request_id)
            if event.get("msg") == "set KV cache source header" and request_id:
                directives.add(request_id)
            if event.get("msg") != "evaluating KV cache source":
                continue
            best = event.get("bestCachedTokens")
            computing = event.get("computingCachedTokens")
            if isinstance(best, int) and isinstance(computing, int):
                evaluations.append(best - computing)

    positive = sorted(delta for delta in evaluations if delta > 0)
    qualifying = [delta for delta in evaluations if delta >= 12288]
    engagement = 100.0 * len(directives) / len(requests) if requests else 0.0
    print(f"requests_seen={len(requests)}")
    print(f"source_directives={len(directives)}")
    print(f"engagement_rate={engagement:.3f}%")
    print(f"source_evaluations={len(evaluations)}")
    print(f"positive_remote_advantage={len(positive)}")
    print(f"qualifying_remote_advantage_ge_12288={len(qualifying)}")
    if positive:
        print(f"positive_delta_min={positive[0]}")
        print(f"positive_delta_median={positive[len(positive) // 2]}")
        print(f"positive_delta_max={positive[-1]}")
    return 0 if engagement >= 5.0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
