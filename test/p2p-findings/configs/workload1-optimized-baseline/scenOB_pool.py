"""Workload 1: the optimized-baseline guide's workload shape on gpt-oss.

150 shared-prefix groups x ~6K-token prefix, 500-token question, 500-token
output, POISSON arrivals (exponential inter-arrival), rate ladder 3->60.

Two pre-registered jobs (see RESULTS):
  1. low load: reference vs +P2P should be statistically equal (P2P inactive)
  2. near saturation: does prefix-cache-affinity-filter break stickiness,
     and do pulls then fire? If <~5% of high-rate requests pull, this
     workload is no-regression evidence, not a value claim.

Usage: scenOB_pool.py <endpoint> <arm-label> [rates_csv]
"""
import json
import random
import sys
import threading
import time
import urllib.request

EP = sys.argv[1]
ARM = sys.argv[2] if len(sys.argv) > 2 else "unlabeled"
STAGES = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else [3, 6, 12, 24, 36, 48, 60]
MODEL = "openai/gpt-oss-120b"
NUM_GROUPS = 150
PREFIX_TOKENS = 6000
QUESTION_TOKENS = 500
OUTPUT_TOKENS = 500
STAGE_DURATION_S = 60
REQUEST_TIMEOUT_S = 120
random.seed(7)

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()

PREFIXES = [f"obpool group-{g} shared context: " +
            " ".join(WORDS[(g * 31 + i) % len(WORDS)] for i in range(PREFIX_TOKENS))
            for g in range(NUM_GROUPS)]

lock = threading.Lock()
cur = {"ok": 0, "fail": 0, "ttft": [], "lat": []}


def one_request(qid):
    g = random.randrange(NUM_GROUPS)
    q = " ".join(WORDS[(qid * 13 + i) % len(WORDS)] for i in range(QUESTION_TOKENS))
    body = json.dumps({
        "model": MODEL,
        "prompt": PREFIXES[g] + f"\nquestion {qid}: " + q,
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
            for line in r:
                if line.strip() and ttft is None:
                    ttft = time.monotonic() - t0
                if line.strip() == b"data: [DONE]":
                    break
        with lock:
            cur["ok"] += 1
            if ttft is not None:
                cur["ttft"].append(ttft)
            cur["lat"].append(time.monotonic() - t0)
    except Exception:
        with lock:
            cur["fail"] += 1


def pct(v, p):
    return v[min(int(len(v) * p), len(v) - 1)] * 1000 if v else float("nan")


def warmup():
    """Seed all 150 prefixes so stage 1 measures placement, not cold fill."""
    t0 = time.monotonic()
    ok = [0]

    def seed(g):
        body = json.dumps({"model": MODEL, "prompt": PREFIXES[g], "max_tokens": 1,
                           "temperature": 0}).encode()
        req = urllib.request.Request(EP + "/v1/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S).read()
            with lock:
                ok[0] += 1
        except Exception:
            pass

    threads = []
    sem = threading.Semaphore(16)
    def worker(g):
        with sem:
            seed(g)
    for g in range(NUM_GROUPS):
        t = threading.Thread(target=worker, args=(g,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=REQUEST_TIMEOUT_S)
    print(f"# warmup: {ok[0]}/{NUM_GROUPS} prefixes seeded in "
          f"{time.monotonic()-t0:.0f}s", flush=True)


def run_stage(rate):
    """Poisson arrivals: exponential inter-arrival at the offered rate."""
    threads = []
    qid = 0
    t_end = time.monotonic() + STAGE_DURATION_S
    while time.monotonic() < t_end:
        time.sleep(random.expovariate(rate))
        t = threading.Thread(target=one_request, args=(qid,), daemon=True)
        t.start()
        threads.append(t)
        qid += 1
    for t in threads:
        t.join(timeout=REQUEST_TIMEOUT_S + 10)
    return qid


def main():
    print(f"# arm={ARM} groups={NUM_GROUPS}x{PREFIX_TOKENS}tok q={QUESTION_TOKENS} "
          f"out={OUTPUT_TOKENS} poisson stages={STAGES}", flush=True)
    warmup()
    print(f"{'offered':>7} {'sent':>6} {'ok':>6} {'fail':>5} {'wall_s':>7} "
          f"{'achieved':>9} {'ttft_p50':>9} {'ttft_p95':>9} {'lat_p50':>8}", flush=True)
    for rate in STAGES:
        with lock:
            cur["ok"] = 0; cur["fail"] = 0; cur["ttft"] = []; cur["lat"] = []
        print(f"# stage_start rate={rate} t={time.time():.0f}", flush=True)
        t0 = time.monotonic()
        sent = run_stage(rate)
        wall = time.monotonic() - t0
        with lock:
            ok, fail = cur["ok"], cur["fail"]
            tt = sorted(cur["ttft"]); la = sorted(cur["lat"])
        print(f"{rate:>7} {sent:>6} {ok:>6} {fail:>5} {wall:>7.1f} {ok/wall:>9.2f} "
              f"{pct(tt,0.5):>9.0f} {pct(tt,0.95):>9.0f} {pct(la,0.5):>8.0f}", flush=True)
        print(f"# stage_end rate={rate} t={time.time():.0f}", flush=True)
    print("# done", flush=True)


if __name__ == "__main__":
    main()
