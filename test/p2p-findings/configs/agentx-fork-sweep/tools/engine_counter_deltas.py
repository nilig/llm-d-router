#!/usr/bin/env python3
"""Snapshot and compare per-role vLLM counters for the AgentX grid."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import subprocess
import sys
import time
from collections import defaultdict


MODEL_SELECTOR = "llm-d.ai/model=GLM-5.2-FP8"
PORTS = range(8000, 8008)
INTERESTING = (
    "prefix_cache",
    "prompt_tokens",
    "external_prefix",
    "kv_offload",
    "nixl_",
)
REMOTE_SCRAPER = """
import json
import urllib.request

metrics = {}
for port in range(8000, 8008):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=10) as response:
        metrics[str(port)] = response.read().decode()
print(json.dumps(metrics))
"""
LABEL_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"')


def kubectl(*args: str) -> str:
    result = subprocess.run(
        ["kubectl", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def ready_engine_pods(namespace: str) -> dict[str, str]:
    data = json.loads(kubectl(
        "-n", namespace, "get", "pods", "-l", MODEL_SELECTOR, "-o", "json"))
    pods = {}
    for pod in data["items"]:
        labels = pod["metadata"].get("labels", {})
        role = labels.get("llm-d.ai/role")
        if role not in {"prefill", "decode"}:
            continue
        conditions = {
            condition["type"]: condition["status"]
            for condition in pod.get("status", {}).get("conditions", [])
        }
        if conditions.get("Ready") == "True":
            pods[pod["metadata"]["name"]] = role
    if not pods:
        raise RuntimeError(f"no Ready engine pods found in {namespace}")
    return dict(sorted(pods.items()))


def normalized_series(sample: str) -> tuple[str, str]:
    if "{" not in sample:
        return sample, sample
    name, raw_labels = sample.split("{", 1)
    labels = {
        key: value
        for key, value in LABEL_RE.findall(raw_labels.rsplit("}", 1)[0])
        if key not in {"engine", "model_name"}
    }
    suffix = ",".join(f'{key}="{labels[key]}"' for key in sorted(labels))
    return name, f"{name}{{{suffix}}}" if suffix else name


def parse_metrics(text: str) -> dict[str, float]:
    metrics: defaultdict[str, float] = defaultdict(float)
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.rsplit(None, 1)
        if len(fields) != 2:
            continue
        sample, raw_value = fields
        name, series = normalized_series(sample)
        if not name.startswith("vllm:") or not any(key in name for key in INTERESTING):
            continue
        if name.endswith(("_bucket", "_created")):
            continue
        try:
            value = float(raw_value)
        except ValueError:
            continue
        if math.isfinite(value):
            metrics[series] += value
    return dict(sorted(metrics.items()))


def scrape_pod(namespace: str, pod: str) -> dict[str, dict[str, float]]:
    raw = kubectl(
        "-n", namespace, "exec", pod, "-c", "vllm", "--",
        "python3", "-c", REMOTE_SCRAPER,
    )
    by_port = json.loads(raw)
    missing = [str(port) for port in PORTS if str(port) not in by_port]
    if missing:
        raise RuntimeError(f"{pod} did not return metrics for ports {missing}")
    return {
        port: parse_metrics(by_port[port])
        for port in sorted(by_port, key=int)
    }


def snapshot(namespace: str, destination: pathlib.Path) -> None:
    roles = ready_engine_pods(namespace)
    instances = {
        pod: scrape_pod(namespace, pod)
        for pod in roles
    }
    totals_by_role: dict[str, defaultdict[str, float]] = {
        role: defaultdict(float) for role in sorted(set(roles.values()))
    }
    for pod, ports in instances.items():
        for metrics in ports.values():
            for series, value in metrics.items():
                totals_by_role[roles[pod]][series] += value
    document = {
        "schema": 2,
        "timestamp": time.time(),
        "namespace": namespace,
        "instances": instances,
        "roles": roles,
        "totals_by_role": {
            role: dict(sorted(totals.items()))
            for role, totals in totals_by_role.items()
        },
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"wrote {destination}: {len(instances)} pods, "
          f"{sum(len(ports) for ports in instances.values())} ranks")


def counter_deltas(before: dict, after: dict, role: str) -> dict[str, float]:
    before_totals = before.get("totals_by_role", {}).get(role, {})
    after_totals = after.get("totals_by_role", {}).get(role, {})
    keys = set(before_totals) | set(after_totals)
    return {
        key: after_totals.get(key, 0.0) - before_totals.get(key, 0.0)
        for key in sorted(keys)
    }


def print_results(directory: pathlib.Path) -> None:
    pairs = []
    for before_path in sorted(directory.glob("agentx-*-pre.json")):
        after_path = before_path.with_name(
            before_path.name.removesuffix("-pre.json") + "-post.json")
        if after_path.exists():
            pairs.append((before_path, after_path))
    if not pairs:
        raise RuntimeError(f"no pre/post snapshot pairs found in {directory}")

    for before_path, after_path in pairs:
        tag = before_path.name.removeprefix("agentx-").removesuffix("-pre.json")
        before = json.loads(before_path.read_text())
        after = json.loads(after_path.read_text())
        print(tag)
        roles = sorted(set(before.get("totals_by_role", {}))
                       | set(after.get("totals_by_role", {})))
        for role in roles:
            print(f"  {role}")
            deltas = counter_deltas(before, after, role)
            nonzero = [(key, value) for key, value in deltas.items() if value]
            if not nonzero:
                print("    no counter changes")
                continue
            for key, value in nonzero:
                print(f"    {key}: {value:+.6g}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default="nilig-agentx-slo")
    parser.add_argument("--snapshot", type=pathlib.Path)
    parser.add_argument("--results", action="store_true")
    parser.add_argument("--snapshot-dir", type=pathlib.Path,
                        default=pathlib.Path("/tmp"))
    args = parser.parse_args()
    if bool(args.snapshot) == bool(args.results):
        parser.error("choose exactly one of --snapshot or --results")
    try:
        if args.snapshot:
            snapshot(args.namespace, args.snapshot)
        else:
            print_results(args.snapshot_dir)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))


if __name__ == "__main__":
    main()
