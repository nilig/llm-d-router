#!/usr/bin/env python3
"""Minimal 1-producer/1-consumer repro for the p2p lookup hangs.

Runs INSIDE the cluster (python:3.11-slim pod), stdlib only.

Round r:
  1. Seed the PRODUCER with a fresh unique ~16K-token prefix (plain request;
     the OffloadingConnector saves it to the CPU tier).
  2. Fire K parallel requests at the CONSUMER with the same prefix plus a
     unique suffix and kv_transfer_params.p2p pointing at the producer
     (exactly what the llm-d sidecar injects). Chunked prefill makes the
     consumer send one FetchMsg per chunk with HITs; parallel pulls congest
     the producer's transfer queue, opening the duplicate-fetch window.
  3. Any request taking > HANG_T seconds (vs ~2s normal) is a HANG.

Env: PRODUCER, CONSUMER (host:port of vllm :8200), ROUNDS, K, HANG_T.
Exit code 1 if any hang was observed, 0 otherwise.
"""
import json
import os
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

PRODUCER = os.environ["PRODUCER"]
CONSUMER = os.environ["CONSUMER"]
ROUNDS = int(os.environ.get("ROUNDS", "20"))
K = int(os.environ.get("K", "8"))
HANG_T = float(os.environ.get("HANG_T", "60"))
CLIENT_TIMEOUT = float(os.environ.get("CLIENT_TIMEOUT", "120"))
MODEL = "meta-llama/Llama-3.1-8B-Instruct"
# ~15K tokens of prefix (~10.3 tokens/line; max-model-len 17408 leaves
# suffix headroom).
PREFIX_LINES = 1450

WORDS = ("alpha beta gamma delta epsilon zeta eta theta iota kappa "
         "lambda mu nu xi omicron pi rho sigma tau upsilon").split()


def make_prefix(round_no: int) -> str:
    lines = [f"session {round_no} document line {i} "
             f"{WORDS[i % len(WORDS)]} {WORDS[(i * 7) % len(WORDS)]}"
             for i in range(PREFIX_LINES)]
    return "\n".join(lines)


def post(host: str, prompt: str, kv_params=None, timeout=CLIENT_TIMEOUT):
    body = {
        "model": MODEL,
        "prompt": prompt,
        "max_tokens": 16,
        "temperature": 0,
    }
    if kv_params is not None:
        body["kv_transfer_params"] = kv_params
    req = urllib.request.Request(
        f"http://{host}/v1/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            code = resp.status
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:150].decode(errors="replace")
        return time.monotonic() - t0, f"HTTP{exc.code}:{detail}"
    except Exception as exc:  # noqa: BLE001
        return time.monotonic() - t0, f"ERR:{type(exc).__name__}"
    return time.monotonic() - t0, code


def pull_one(prefix: str, idx: int):
    kv = {"p2p": {
        "kv_request_id": str(uuid.uuid4()),
        "remote_host": PRODUCER.split(":")[0],
        "remote_port": 7777,
    }}
    prompt = f"{prefix}\nquestion {idx}: summarize line {idx * 13} briefly."
    return post(CONSUMER, prompt, kv_params=kv)


SETTLE = float(os.environ.get("SETTLE", "0"))
PULL_DELAY = float(os.environ.get("PULL_DELAY", "0.15"))
BGSEED = os.environ.get("BGSEED", "1") == "1"


def bg_seeder(stop):
    """Keep the producer's step cadence and CPU-tier save queue busy so
    lookup resolutions fragment (HIT_PENDING wavefronts) and transfers
    queue - the conditions for multi-fetch and the duplicate-fetch race."""
    n = 0
    while not stop["done"]:
        lines = [f"bg {stop['round']} noise line {i} {WORDS[(i + n) % len(WORDS)]}"
                 for i in range(400)]
        post(PRODUCER, "\n".join(lines) + f"\nbg question {n}: ok?",
             timeout=30)
        n += 1


def main() -> int:
    hangs = 0
    stop = {"done": False, "round": 0}
    bg = None
    if BGSEED:
        import threading
        bg = threading.Thread(target=bg_seeder, args=(stop,), daemon=True)
        bg.start()
    for r in range(ROUNDS):
        stop["round"] = r
        prefix = make_prefix(r)
        # Fire the seed and the pulls CONCURRENTLY: the consumer's lookups
        # race the producer's in-progress prefill/CPU-tier save, so
        # resolutions fragment (servable / HIT_PENDING / not-yet waves) and
        # the consumer sends staggered follow-up FetchMsgs - the
        # duplicate-fetch race window.
        with ThreadPoolExecutor(max_workers=K + 1) as pool:
            seed_f = pool.submit(post, PRODUCER, prefix + "\nseed question: ok?")
            time.sleep(PULL_DELAY)
            results = list(pool.map(lambda i: pull_one(prefix, i), range(K)))
            sdt, scode = seed_f.result()
        print(f"[round {r}] seed: {sdt:.1f}s code={scode}", flush=True)
        if SETTLE:
            time.sleep(SETTLE)
        round_hangs = [(dt, code) for dt, code in results if dt > HANG_T]
        wall = max(dt for dt, _ in results)
        codes = [code for _, code in results]
        print(f"[round {r}] pulls: max={wall:.1f}s codes={codes}", flush=True)
        if round_hangs:
            hangs += len(round_hangs)
            print(f"[round {r}] *** {len(round_hangs)} HANG(s) "
                  f"(> {HANG_T}s): {round_hangs}", flush=True)
    stop["done"] = True
    print(f"DONE hangs={hangs}", flush=True)
    return 1 if hangs else 0


if __name__ == "__main__":
    raise SystemExit(main())
