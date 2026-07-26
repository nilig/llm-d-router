"""UC2 lookup-hang ladder re-test: same shape as
llm-d-benchmark/workload/profiles/inference-perf/uc2_llama_pool.yaml.in
(shared_prefix: 64 groups x 40 prompts, system_prompt_len=16000,
question_len=256, output_len=256; constant-rate stages 2/4/6/8/12/16/20/24
req/s x 60s), driven directly against the endpoint instead of through the
llmdbenchmark harness (unreliable CLI for long multi-stage runs per prior
findings -- this gives immediate, reliable per-stage pass/fail instead of
depending on its report pipeline).
"""
import json
import sys
import time
import threading
import urllib.request
from collections import deque

EP = sys.argv[1]
MODEL = "meta-llama/Llama-3.1-8B-Instruct"
NUM_GROUPS = 64
STAGES = [2, 4, 6, 8, 12, 16, 20, 24]
STAGE_DURATION_S = 60

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()


def make_prefix(group_idx):
    body = " ".join(WORDS[(group_idx * 37 + i) % len(WORDS)] for i in range(16000))
    return f"shared llama pool group-{group_idx} document: " + body


PREFIXES = [make_prefix(g) for g in range(NUM_GROUPS)]

lock = threading.Lock()
counters = {"sent": 0, "ok": 0, "fail": 0, "latencies": deque()}


def one_request(group_idx, req_idx):
    prompt = PREFIXES[group_idx] + f" q{req_idx}?"
    body = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "max_tokens": 256,
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(
        EP + "/v1/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            ok = bool(json.loads(r.read()).get("choices"))
        dt = time.monotonic() - t0
        with lock:
            counters["sent"] += 1
            counters["ok" if ok else "fail"] += 1
            counters["latencies"].append(dt)
    except Exception as e:
        dt = time.monotonic() - t0
        with lock:
            counters["sent"] += 1
            counters["fail"] += 1
            counters["latencies"].append(dt)
        return f"ERR {e}"[:120]
    return None


def run_stage(rate, duration):
    stop_at = time.monotonic() + duration
    req_idx = 0
    threads = []
    interval = 1.0 / rate
    next_send = time.monotonic()
    while time.monotonic() < stop_at:
        now = time.monotonic()
        if now < next_send:
            time.sleep(min(0.01, next_send - now))
            continue
        group_idx = req_idx % NUM_GROUPS
        t = threading.Thread(target=one_request, args=(group_idx, req_idx), daemon=True)
        t.start()
        threads.append(t)
        req_idx += 1
        next_send += interval
    # drain in-flight requests (up to the per-request timeout)
    for t in threads:
        t.join(timeout=125)
    return req_idx


def main():
    print(f"{'rate':>6} {'sent':>6} {'ok':>6} {'fail':>6} {'p50_ms':>8} {'p95_ms':>8}")
    for rate in STAGES:
        before = dict(counters)
        before_lat_len = len(counters["latencies"])
        with lock:
            counters["latencies"].clear()
        sent = run_stage(rate, STAGE_DURATION_S)
        with lock:
            lats = sorted(counters["latencies"])
            ok = counters["ok"]
            fail = counters["fail"]
            counters["ok"] = 0
            counters["fail"] = 0
            counters["sent"] = 0
        p50 = lats[len(lats) // 2] * 1000 if lats else float("nan")
        p95 = lats[int(len(lats) * 0.95)] * 1000 if lats else float("nan")
        print(f"{rate:>6} {sent:>6} {ok:>6} {fail:>6} {p50:>8.0f} {p95:>8.0f}", flush=True)


if __name__ == "__main__":
    main()
