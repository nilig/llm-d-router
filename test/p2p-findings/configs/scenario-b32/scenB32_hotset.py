"""Scenario B - hot set (the guide's "payoff case").

Workload per guides/p2p-kv-cache-sharing/benchmarking/README.md: a small hot
set takes all traffic - 8 shared prefixes x 48K tokens, decode-heavy requests
(512 output tokens), rates ramped well past what the prefix owners alone can
absorb. Affinity concentrates each hot prefix on its owner pod; load-aware
placement plus the pull serves the same hot content from the whole fleet.

The guide's table has only `affinity` and `load + P2P`. This driver exists to
fill the two missing arms: `affinity + P2P` (the SHIPPED DEFAULT, untested in
the payoff case) and `load, no P2P` (the recompute floor).

Reports achieved req/s, latency p50, and failures per stage - the three
columns the guide's Scenario B table uses - plus TTFT so decode-concentration
can be separated from prefill cost.

Usage: scenB_hotset.py <endpoint> <arm-label> [rates_csv]
"""
import json
import sys
import time
import threading
import urllib.request

EP = sys.argv[1]
ARM = sys.argv[2] if len(sys.argv) > 2 else "unlabeled"
STAGES = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else [12, 24, 36, 48]
MODEL = "openai/gpt-oss-120b"
NUM_HOT = 32                # resized: 32x48K = 1.54M tokens > one pod GPU cache (1.22M)
PREFIX_TOKENS = 48000
OUTPUT_TOKENS = 512         # decode-heavy: this is what concentrates load on owners
STAGE_DURATION_S = 60
REQUEST_TIMEOUT_S = 120     # guide reports failures at 120s client timeout

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()

HOT = [f"hotset prefix-{g} document: " +
       " ".join(WORDS[(g * 53 + i) % len(WORDS)] for i in range(PREFIX_TOKENS))
       for g in range(NUM_HOT)]

lock = threading.Lock()
cur = {"ok": 0, "fail": 0, "ttft": [], "lat": []}


def one_request(g, i):
    body = json.dumps({
        "model": MODEL,
        "prompt": HOT[g] + f" question {i}?",
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
        with lock:
            cur["ok"] += 1
            cur["lat"].append(time.monotonic() - t0)
            if ttft is not None:
                cur["ttft"].append(ttft)
    except Exception:
        with lock:
            cur["fail"] += 1


def run_stage(rate, duration):
    t0 = time.monotonic()
    stop = t0 + duration
    i = 0
    ths = []
    interval = 1.0 / rate
    nxt = t0
    while time.monotonic() < stop:
        now = time.monotonic()
        if now < nxt:
            time.sleep(min(0.005, nxt - now)); continue
        t = threading.Thread(target=one_request, args=(i % NUM_HOT, i), daemon=True)
        t.start(); ths.append(t); i += 1; nxt += interval
    for t in ths:
        t.join(timeout=REQUEST_TIMEOUT_S + 10)
    return i, time.monotonic() - t0


def pct(xs, p):
    return xs[int(len(xs) * p)] * 1000 if xs else float("nan")


def warmup():
    """Seed each hot prefix once so the ladder measures steady state."""
    t0 = time.monotonic()
    ths = [threading.Thread(target=one_request, args=(g, 90000 + g), daemon=True)
           for g in range(NUM_HOT)]
    for t in ths: t.start()
    for t in ths: t.join(timeout=REQUEST_TIMEOUT_S + 10)
    with lock:
        ok, fail = cur["ok"], cur["fail"]
        cur["ok"] = 0; cur["fail"] = 0; cur["ttft"] = []; cur["lat"] = []
    print(f"# warmup: {ok} ok / {fail} fail in {time.monotonic()-t0:.0f}s "
          f"({NUM_HOT} hot prefixes seeded)", flush=True)


def main():
    print(f"# arm={ARM} hot={NUM_HOT}x{PREFIX_TOKENS}tok out={OUTPUT_TOKENS}", flush=True)
    warmup()
    print(f"{'offered':>7} {'sent':>6} {'ok':>6} {'fail':>5} {'wall_s':>7} "
          f"{'achieved':>9} {'ttft_p50':>9} {'lat_p50':>8}", flush=True)
    for rate in STAGES:
        with lock:
            cur["ok"] = 0; cur["fail"] = 0; cur["ttft"] = []; cur["lat"] = []
        sent, wall = run_stage(rate, STAGE_DURATION_S)
        with lock:
            ok, fail = cur["ok"], cur["fail"]
            tt = sorted(cur["ttft"]); la = sorted(cur["lat"])
        print(f"{rate:>7} {sent:>6} {ok:>6} {fail:>5} {wall:>7.1f} {ok/wall:>9.2f} "
              f"{pct(tt,0.5):>9.0f} {pct(la,0.5):>8.0f}", flush=True)


def _done():
    print("# done", flush=True)


if __name__ == "__main__":
    main()
    _done()
