"""UC3 re-validation: gpt-oss-120b P/D docQA, same shape as
p2p-findings/gptoss-docqa-c192.yaml (192 conversations, private ~49152-token
system-prompt document each, 6 turns of 256-token question/answer,
concurrency 192, request_timeout 180s) -- driven directly against the
endpoint (mirrors the UC2 approach; llmdbenchmark's harness wrapper for this
config isn't reproducible in this session -- see RESULTS-4.md).
"""
import json
import sys
import time
import threading
import urllib.request

EP = sys.argv[1]
MODEL = "openai/gpt-oss-120b"
NUM_CONVERSATIONS = 48
TURNS = 6
INPUT_TOKENS = 256
OUTPUT_TOKENS = 256
SYS_PROMPT_TOKENS = 49152
CONCURRENCY = 48
REQUEST_TIMEOUT_S = 180

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()


def make_doc(idx):
    body = " ".join(WORDS[(idx * 41 + i) % len(WORDS)] for i in range(SYS_PROMPT_TOKENS))
    return f"document-{idx} reference material: " + body


DOCS = [make_doc(i) for i in range(NUM_CONVERSATIONS)]

lock = threading.Lock()
stats = {"ok": 0, "fail": 0, "ttft": [], "errors": []}


def one_turn(messages):
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        "max_tokens": OUTPUT_TOKENS,
        "temperature": 0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        EP + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
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
            stats["ok"] += 1
            if ttft is not None:
                stats["ttft"].append(ttft)
        return True
    except Exception as e:
        with lock:
            stats["fail"] += 1
            stats["errors"].append(str(e)[:100])
        return False


def run_conversation(conv_idx):
    doc = DOCS[conv_idx]
    messages = [{"role": "system", "content": doc}]
    for turn in range(TURNS):
        q = " ".join(WORDS[(conv_idx * 7 + turn * 13 + i) % len(WORDS)] for i in range(INPUT_TOKENS))
        messages.append({"role": "user", "content": f"turn {turn}: {q}?"})
        ok = one_turn(messages)
        # append a filler assistant turn so the conversation keeps growing
        # even though we don't have the real streamed content
        messages.append({"role": "assistant", "content": " ".join(WORDS[:OUTPUT_TOKENS % len(WORDS)]) * (OUTPUT_TOKENS // len(WORDS) + 1)})
        if not ok:
            return


def main():
    print(f"Launching {NUM_CONVERSATIONS} conversations x {TURNS} turns, concurrency={CONCURRENCY}")
    t_start = time.monotonic()
    sem = threading.Semaphore(CONCURRENCY)
    threads = []

    def worker(idx):
        with sem:
            run_conversation(idx)

    for i in range(NUM_CONVERSATIONS):
        t = threading.Thread(target=worker, args=(i,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=REQUEST_TIMEOUT_S * TURNS + 60)

    dur = time.monotonic() - t_start
    with lock:
        ok, fail = stats["ok"], stats["fail"]
        ttft = sorted(stats["ttft"])
        errs = stats["errors"][:5]
    p50 = ttft[len(ttft) // 2] if ttft else float("nan")
    p95 = ttft[int(len(ttft) * 0.95)] if ttft else float("nan")
    p99 = ttft[int(len(ttft) * 0.99)] if ttft else float("nan")
    print(f"duration={dur:.1f}s ok={ok} fail={fail} total={ok+fail}/{NUM_CONVERSATIONS * TURNS}")
    print(f"TTFT p50={p50*1000:.0f}ms p95={p95*1000:.0f}ms p99={p99*1000:.0f}ms")
    print(f"throughput={ok/dur:.2f} turns/s")
    if errs:
        print(f"sample errors: {errs}")


if __name__ == "__main__":
    main()
