"""UC2 paired A/B ladder: same workload shape as
llm-d-benchmark/workload/profiles/inference-perf/uc2_llama_pool.yaml.in
(shared_prefix: 64 groups x 40 prompts, system_prompt_len=16000,
question_len=256, output_len=256; constant-rate stages 2/4/6/8/12/16/20/24
req/s x 60s).

Adds what the first pass lacked: ACHIEVED THROUGHPUT per stage (completed /
stage wall-clock including drain), which is the metric the blog's UC2 claim
actually rests on. Latency percentiles are end-to-end request latency.

Usage: uc2_ladder2.py <endpoint> <arm-label>
"""
import json
import sys
import time
import threading
import urllib.request

EP = sys.argv[1]
ARM = sys.argv[2] if len(sys.argv) > 2 else "unlabeled"
MODEL = "meta-llama/Llama-3.1-8B-Instruct"
NUM_GROUPS = 64
STAGES = [2, 4, 6, 8, 12, 16, 20, 24]
STAGE_DURATION_S = 60
REQUEST_TIMEOUT_S = 180

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()


def make_prefix(group_idx):
    body = " ".join(WORDS[(group_idx * 37 + i) % len(WORDS)] for i in range(16000))
    return f"shared llama pool group-{group_idx} document: " + body


PREFIXES = [make_prefix(g) for g in range(NUM_GROUPS)]

lock = threading.Lock()
cur = {"ok": 0, "fail": 0, "lat": []}


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
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as r:
            ok = bool(json.loads(r.read()).get("choices"))
        dt = time.monotonic() - t0
        with lock:
            cur["ok" if ok else "fail"] += 1
            cur["lat"].append(dt)
    except Exception:
        dt = time.monotonic() - t0
        with lock:
            cur["fail"] += 1
            cur["lat"].append(dt)


def run_stage(rate, duration):
    """Launch at `rate` req/s for `duration`s, then drain. Returns wall-clock."""
    t_start = time.monotonic()
    stop_at = t_start + duration
    req_idx = 0
    threads = []
    interval = 1.0 / rate
    next_send = t_start
    while time.monotonic() < stop_at:
        now = time.monotonic()
        if now < next_send:
            time.sleep(min(0.01, next_send - now))
            continue
        t = threading.Thread(target=one_request,
                             args=(req_idx % NUM_GROUPS, req_idx), daemon=True)
        t.start()
        threads.append(t)
        req_idx += 1
        next_send += interval
    for t in threads:
        t.join(timeout=REQUEST_TIMEOUT_S + 10)
    return req_idx, time.monotonic() - t_start


def main():
    print(f"# arm={ARM} endpoint={EP}")
    print(f"{'rate':>5} {'sent':>6} {'ok':>6} {'fail':>5} {'wall_s':>8} "
          f"{'achieved':>9} {'p50_ms':>8} {'p95_ms':>8}", flush=True)
    for rate in STAGES:
        with lock:
            cur["ok"] = 0
            cur["fail"] = 0
            cur["lat"] = []
        sent, wall = run_stage(rate, STAGE_DURATION_S)
        with lock:
            lats = sorted(cur["lat"])
            ok, fail = cur["ok"], cur["fail"]
        achieved = ok / wall if wall > 0 else float("nan")
        p50 = lats[len(lats) // 2] * 1000 if lats else float("nan")
        p95 = lats[int(len(lats) * 0.95)] * 1000 if lats else float("nan")
        print(f"{rate:>5} {sent:>6} {ok:>6} {fail:>5} {wall:>8.1f} "
              f"{achieved:>9.2f} {p50:>8.0f} {p95:>8.0f}", flush=True)


if __name__ == "__main__":
    main()
