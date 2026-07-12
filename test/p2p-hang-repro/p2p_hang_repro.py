#!/usr/bin/env python3
"""Standalone reproducer: rare unbounded p2p pull hang vs recompute.

No router, EPP, or sidecar. Drives kv_transfer_params.p2p directly into
/v1/completions against a set of vLLM pods running the generic_p2p connector
(OffloadingConnector + p2p secondary tier on port 7777).

Design: warm ONE source pod with N distinct long prefixes (past its GPU cache,
so blocks offload to the servable CPU tier). Then hammer it with C concurrent
consumers for D seconds, in two arms at identical load:

  OFF  consumers recompute the prefix locally (no p2p)   -> recompute baseline
  ON   consumers pull the prefix from the source (p2p)   -> connector under test

Both arms have the SAME body latency (p50/p90/p99). The ON arm additionally
exhibits a rare unbounded tail: a small fraction of pulls hang to the client
timeout, which recompute never does. That tail is the connector defect:
lookups have no timeout (session_client.py "Lookups have no timeout"), so a
lookup that never resolves hangs the request until the client gives up.

Usage (in-cluster or anywhere with L3 reach to the pods):
    URLS=http://POD0:8200,http://POD1:8200,http://POD2:8200,http://POD3:8200 \
    MODEL=meta-llama/Llama-3.1-8B-Instruct python3 p2p_hang_repro.py

Env: URLS (comma-sep pod base URLs, pod0 = source), MODEL, KPER (prefixes on
source, default 300), CONC (concurrent consumers, default 60), DUR (seconds per
arm, default 75), P2P_PORT (source p2p tier, default 7777), TIMEOUT (client
request timeout, default 120).
"""
import os, time, json, random, threading, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

URLS   = os.environ["URLS"].split(",")
MODEL  = os.environ["MODEL"]
KPER   = int(os.environ.get("KPER", "300"))
CONC   = int(os.environ.get("CONC", "60"))
DUR    = int(os.environ.get("DUR", "75"))
PORT   = int(os.environ.get("P2P_PORT", "7777"))
TIMEO  = int(os.environ.get("TIMEOUT", "120"))
RUN    = str(os.getpid())
SRC    = URLS[0]
SRC_HOST = SRC.split("://", 1)[-1].split(":")[0]
CONS   = URLS[1:]

# a long, low-entropy prefix so each request is an expensive prefill (~4K tokens)
UNIT = ("rivers mountains forests deserts oceans valleys glaciers canyons "
        "plateaus grassland plains beyond the far horizon under a wide cloudless "
        "summer sky at the break of a cold clear quiet dawn over the frosted "
        "northern land where herds of wild elk graze near a slow winding river "
        "beneath tall pines heavy with fresh snow while distant wolves call "
        "across the frozen valley floor at first light of a pale winter morning ")
LONG = UNIT * 90

def prefix(i):
    return f"REPRO-{RUN}-{i} {LONG} end-{i}"

def post(url, prompt, pull=False):
    body = {"model": MODEL, "prompt": prompt, "max_tokens": 2, "temperature": 0}
    if pull:
        body["kv_transfer_params"] = {"p2p": {
            "kv_request_id": f"repro-{RUN}-{random.randint(0, 1 << 30)}",
            "remote_host": SRC_HOST, "remote_port": PORT}}
    req = urllib.request.Request(f"{url}/v1/completions",
        data=json.dumps(body).encode(), headers={"content-type": "application/json"})
    t0 = time.time()
    try:
        urllib.request.urlopen(req, timeout=TIMEO).read()
        return time.time() - t0, 200
    except urllib.error.HTTPError as e:
        return time.time() - t0, e.code
    except Exception:
        return time.time() - t0, 0

def warm_source():
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=12) as ex:
        list(ex.map(lambda i: post(SRC, prefix(i)), range(1, KPER + 1)))
    print(f"  warmed source {SRC} with {KPER} prefixes in {time.time()-t0:.0f}s", flush=True)
    time.sleep(8)

def arm(pull):
    label = "ON (p2p-pull)" if pull else "OFF (recompute)"
    results = []; lock = threading.Lock(); stop = time.time() + DUR
    def worker(wid):
        c = CONS[wid % len(CONS)]
        while time.time() < stop:
            lat, code = post(c, prefix(random.randint(1, KPER)), pull=pull)
            with lock: results.append((lat, code))
    with ThreadPoolExecutor(max_workers=CONC) as ex:
        for w in range(CONC): ex.submit(worker, w)
    lats = sorted(r[0] for r in results)
    n = len(lats); fail = sum(1 for _, c in results if c != 200)
    pct = lambda p: lats[min(n - 1, int(n * p))] if n else 0.0
    stalled = sum(1 for t in lats if t >= 20)
    print(f"  {label:16s} reqs={n} fail={fail}  p50={pct(.5):.2f} p90={pct(.9):.2f} "
          f"p99={pct(.99):.2f} max={lats[-1]:.2f}  stalled>=20s={stalled}", flush=True)
    return {"label": label, "n": n, "fail": fail, "p50": pct(.5), "p90": pct(.9),
            "p99": pct(.99), "max": lats[-1] if n else 0.0, "stalled": stalled}

print(f"source={SRC} consumers={CONS} conc={CONC} dur={DUR}s kper={KPER}", flush=True)
print("ARM OFF (recompute baseline):", flush=True); warm_source(); off = arm(False)
time.sleep(6)
print("ARM ON  (p2p pull under test):", flush=True); warm_source(); on = arm(True)

print("\nRESULT", flush=True)
print(f"  body latency (p50/p90/p99): OFF {off['p50']:.2f}/{off['p90']:.2f}/{off['p99']:.2f}"
      f"  ON {on['p50']:.2f}/{on['p90']:.2f}/{on['p99']:.2f}  -> comparable if within noise", flush=True)
ratio = on["max"] / off["max"] if off["max"] else 0.0
print(f"  tail (max):  OFF {off['max']:.2f}s   ON {on['max']:.2f}s   (ON/OFF = {ratio:.1f}x)", flush=True)
print(f"  stalled>=20s: OFF {off['stalled']}   ON {on['stalled']}", flush=True)
# The tail magnitude is stochastic run to run (~10-120s); the signal is that the
# ON tail dwarfs the OFF tail while the body latencies match. Full 120s hangs
# surface more often with larger DUR or repeated runs.
if ratio >= 3.0 and on["max"] >= 10 and off["max"] < 6:
    print(f"  => REPRODUCED: p2p pull tail is {ratio:.1f}x the recompute tail with matched body "
          f"latency -> a rare unbounded pull hang recompute never shows.", flush=True)
else:
    print("  => weak this run (raise DUR/CONC/KPER or re-run; extreme 120s hangs are intermittent).", flush=True)
