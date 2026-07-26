"""UC4 re-validation: Llama-3.1-8B P/D multi-turn chat, prefill-pulls-from-
decode. Unlike UC3's docQA driver, this uses REAL generated content as each
turn's assistant history (not filler) -- Llama's chat template is round-trip
stable (tokenize(generated) == generated ids), which is what lets a later
turn's prefill leg match and pull the previous turn's decode-generated
answer as session history (see project_pd_multiturn_experiment memory,
llama-chat-pull3.sh finding). Natural EOS (no ignore_eos): forced
continuation embeds special tokens as text and breaks the retokenization
chain per that same finding.
"""
import json
import sys
import time
import threading
import urllib.request

EP = sys.argv[1]
MODEL = "meta-llama/Llama-3.1-8B-Instruct"
NUM_CONVERSATIONS = 16
TURNS = 6
MAX_TOKENS_PER_TURN = 150
REQUEST_TIMEOUT_S = 60
CONCURRENCY = 16

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()

lock = threading.Lock()
stats = {"ok": 0, "fail": 0, "ttft": []}


def one_turn(messages):
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        "max_tokens": MAX_TOKENS_PER_TURN,
        "temperature": 0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        EP + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    ttft = None
    content_parts = []
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as r:
            for raw in r:
                line = raw.decode("utf-8", errors="ignore").strip()
                if not line.startswith("data: "):
                    continue
                if ttft is None:
                    ttft = time.monotonic() - t0
                payload = line[len("data: "):]
                if payload == "[DONE]":
                    break
                try:
                    obj = json.loads(payload)
                    delta = obj["choices"][0].get("delta", {})
                    piece = delta.get("content")
                    if piece:
                        content_parts.append(piece)
                except Exception:
                    pass
        with lock:
            stats["ok"] += 1
            if ttft is not None:
                stats["ttft"].append(ttft)
        return "".join(content_parts) or "(empty response)"
    except Exception as e:
        with lock:
            stats["fail"] += 1
        return None


def run_conversation(conv_idx):
    topic = " ".join(WORDS[(conv_idx * 5 + i) % len(WORDS)] for i in range(6))
    messages = [{"role": "system", "content": "You are a helpful, concise assistant."}]
    for turn in range(TURNS):
        q = f"Conversation {conv_idx}, turn {turn}: tell me one new fact about {topic}, in one short sentence."
        messages.append({"role": "user", "content": q})
        answer = one_turn(messages)
        if answer is None:
            return
        messages.append({"role": "assistant", "content": answer})


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
        t.join(timeout=REQUEST_TIMEOUT_S * TURNS + 30)

    dur = time.monotonic() - t_start
    with lock:
        ok, fail = stats["ok"], stats["fail"]
        ttft = sorted(stats["ttft"])
    p50 = ttft[len(ttft) // 2] if ttft else float("nan")
    p95 = ttft[int(len(ttft) * 0.95)] if ttft else float("nan")
    print(f"duration={dur:.1f}s ok={ok} fail={fail} total={ok+fail}/{NUM_CONVERSATIONS * TURNS}")
    print(f"TTFT p50={p50*1000:.0f}ms p95={p95*1000:.0f}ms")
    print(f"throughput={ok/dur:.2f} turns/s")


if __name__ == "__main__":
    main()
