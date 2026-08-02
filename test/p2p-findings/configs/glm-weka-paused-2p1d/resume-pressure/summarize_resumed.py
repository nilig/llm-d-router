#!/usr/bin/env python3
"""Report latency for profiling turns that resume after an observed idle gap."""

import json
import math
import sys


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    index = min(len(ordered) - 1, math.ceil(quantile * len(ordered)) - 1)
    return ordered[index]


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"usage: {sys.argv[0]} <profile_export.jsonl> [minimum-gap-seconds]", file=sys.stderr)
        return 2

    minimum_gap_ns = float(sys.argv[2] if len(sys.argv) == 3 else 30) * 1e9
    records = []
    with open(sys.argv[1], encoding="utf-8", errors="ignore") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            metadata = record.get("metadata", {})
            conversation = metadata.get("conversation_id")
            started = metadata.get("request_start_ns")
            if conversation and isinstance(started, int):
                records.append((started, conversation, metadata, record.get("metrics", {})))

    previous_end = {}
    profiling = []
    resumed = []
    for started, conversation, metadata, metrics in sorted(records):
        if metadata.get("benchmark_phase") == "profiling":
            profiling.append(metrics)
            ended = previous_end.get(conversation)
            if ended is not None and started - ended >= minimum_gap_ns:
                resumed.append(metrics)
        request_end = metadata.get("request_end_ns")
        if isinstance(request_end, int):
            previous_end[conversation] = request_end

    def report(label: str, rows: list[dict]) -> None:
        ttft = [
            metric["time_to_first_token"]["value"]
            for metric in rows
            if isinstance(metric.get("time_to_first_token", {}).get("value"), (int, float))
        ]
        input_tokens = [
            metric["input_sequence_length"]["value"]
            for metric in rows
            if isinstance(metric.get("input_sequence_length", {}).get("value"), (int, float))
        ]
        print(f"{label}_requests={len(rows)}")
        print(f"{label}_ttft_p50_ms={percentile(ttft, 0.50):.3f}")
        print(f"{label}_ttft_p95_ms={percentile(ttft, 0.95):.3f}")
        print(f"{label}_ttft_p99_ms={percentile(ttft, 0.99):.3f}")
        print(f"{label}_input_tokens_p50={percentile(input_tokens, 0.50):.0f}")

    report("profiling", profiling)
    report("resumed", resumed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
