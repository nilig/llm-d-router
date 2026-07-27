"""Scenario C - P/D prefill placement ladder.

Workload mirrors the guide's Scenario A uniform shared-prefix pool so the
P/D numbers are directly comparable to the aggregated ones already in the
guide: 128 prefixes x 48K tokens, 256-token questions, 64-token outputs,
constant-rate stages ramped past saturation.

Reports achieved throughput per stage (completions / stage wall-clock incl.
drain) plus TTFT and end-to-end latency percentiles. Streaming, so TTFT is
measured at first token - the metric that separates prefill placement from
decode intake.

Usage: scenC_ladder.py <endpoint> <arm-label> [stages_csv]
"""
import json
import sys
import time
import threading
import urllib.request

EP = sys.argv[1]
ARM = sys.argv[2] if len(sys.argv) > 2 else "unlabeled"
STAGES = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else [1, 2, 3, 4]
MODEL = "openai/gpt-oss-120b"
NUM_GROUPS = 128
PREFIX_TOKENS = 48000
QUESTION_TOKENS = 256
OUTPUT_TOKENS = 64
STAGE_DURATION_S = 60
REQUEST_TIMEOUT_S = 180

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()

PREFIXES = [
    f"scenc pool group-{g} document: " +
    " ".join(WORDS[(g * 37 + i) % len(WORDS)] for i in range(PREFIX_TOKENS))
    for g in range(NUM_GROUPS)
]

lock = threading.Lock()
cur = {"ok": 0, "fail": 0, "ttft": [], "lat": []}


def one_request(g, i):
    q = " ".join(WORDS[(i * 11 + k) % len(WORDS)] for k in range(QUESTION_TOKENS))
    body = json.dumps({
        "model": MODEL,
        "prompt": PREFIXES[g] + f" question {i}: {q}?",
        "max_tokens": OUTPUT_TOKENS,
        "temperature": 0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(EP + "/v1/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft = None
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as r:
            for raw in r:
                if raw.strip() and ttft is None:
                    ttft = time.monotonic() - t0
                if raw.strip() == b"data: [DONE]":
                    break
        dt = time.monotonic() - t0
        with lock:
            cur["ok"] += 1
            cur["lat"].append(dt)
            if ttft is not None:
                cur["ttft"].append(ttft)
    except Exception:
        with lock:
            cur["fail"] += 1


def run_stage(rate, duration):
    t_start = time.monotonic()
    stop_at = t_start + duration
    i = 0
    threads = []
    interval = 1.0 / rate
    nxt = t_start
    while time.monotonic() < stop_at:
        now = time.monotonic()
        if now < nxt:
            time.sleep(min(0.01, nxt - now))
            continue
        t = threading.Thread(target=one_request, args=(i % NUM_GROUPS, i), daemon=True)
        t.start()
        threads.append(t)
        i += 1
        nxt += interval
    for t in threads:
        t.join(timeout=REQUEST_TIMEOUT_S + 10)
    return i, time.monotonic() - t_start


def pct(xs, p):
    return xs[int(len(xs) * p)] * 1000 if xs else float("nan")


def warmup():
    """Populate every prefix once before measuring.

    Without this the first stages measure cold-fill capacity, not placement:
    128 distinct 48K prefixes against 8 prefill pods at ~6.4s per cold 48K
    prefill caps the fleet near 1.25 req/s regardless of routing arm, so all
    arms would look identical. Warmup runs under the arm's own placement
    policy, which is the realistic steady state for that arm.
    """
    t0 = time.monotonic()
    sem = threading.Semaphore(16)
    ths = []

    def w(g):
        with sem:
            one_request(g, 10_000 + g)

    for g in range(NUM_GROUPS):
        t = threading.Thread(target=w, args=(g,), daemon=True)
        t.start()
        ths.append(t)
    for t in ths:
        t.join(timeout=REQUEST_TIMEOUT_S + 10)
    with lock:
        ok, fail = cur["ok"], cur["fail"]
        cur["ok"] = 0; cur["fail"] = 0; cur["ttft"] = []; cur["lat"] = []
    print(f"# warmup: {ok} ok / {fail} fail in {time.monotonic()-t0:.0f}s "
          f"({NUM_GROUPS} prefixes populated)", flush=True)


def main():
    print(f"# arm={ARM} endpoint={EP} groups={NUM_GROUPS} prefix~{PREFIX_TOKENS}tok")
    warmup()
    print(f"{'rate':>5} {'sent':>6} {'ok':>6} {'fail':>5} {'wall_s':>7} {'achieved':>9} "
          f"{'ttft_p50':>9} {'ttft_p95':>9} {'lat_p50':>8}", flush=True)
    for rate in STAGES:
        with lock:
            cur["ok"] = 0; cur["fail"] = 0; cur["ttft"] = []; cur["lat"] = []
        sent, wall = run_stage(rate, STAGE_DURATION_S)
        with lock:
            ok, fail = cur["ok"], cur["fail"]
            tt = sorted(cur["ttft"]); la = sorted(cur["lat"])
        print(f"{rate:>5} {sent:>6} {ok:>6} {fail:>5} {wall:>7.1f} {ok/wall:>9.2f} "
              f"{pct(tt,0.5):>9.0f} {pct(tt,0.95):>9.0f} {pct(la,0.5):>8.0f}", flush=True)


if __name__ == "__main__":
    main()
