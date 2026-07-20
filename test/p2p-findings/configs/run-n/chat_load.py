#!/usr/bin/env python3
"""Heavy-decode chat multi-turn load with live message history.

Each conversation: unique ~6K-token system prompt, TURNS rounds; every round
streams a long natural answer (temp 0, no ignore_eos) and appends it to the
history, so turn N+1 carries the real generated text - the token-stable
multi-turn that lets the EPP see decode-held KV. Reports per-turn TTFT
(first SSE content chunk) and end-to-end times.

usage: chat_load.py HOST PORT CONCURRENCY TURNS TAG OUTFILE
"""
import http.client, json, sys, threading, time

HOST, PORT, C, TURNS, TAG, OUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
MODEL = "meta-llama/Llama-3.1-8B-Instruct"
QS = ["Analyze the scenario in 15 detailed numbered sections.",
      "Continue with 15 more sections, each a full paragraph.",
      "Now give counterarguments for each point, in detail.",
      "Propose alternatives, one paragraph each.",
      "Assess risks of each alternative in detail.",
      "Write an implementation plan with detailed steps.",
      "Review the plan critically, section by section.",
      "Summarize everything comprehensively section by section."]
lock = threading.Lock()
rows = []

def turn(conn_host, msgs):
    body = json.dumps({"model": MODEL, "messages": msgs, "max_tokens": 2500,
                       "temperature": 0, "stream": True}).encode()
    c = http.client.HTTPConnection(conn_host, PORT, timeout=600)
    t0 = time.time(); ttft = None; text = []
    c.request("POST", "/v1/chat/completions", body=body,
              headers={"Content-Type": "application/json"})
    r = c.getresponse()
    if r.status != 200:
        c.close(); raise RuntimeError(f"HTTP {r.status}: {r.read()[:120]}")
    buf = b""
    while True:
        chunk = r.read1(65536)
        if not chunk: break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line.startswith(b"data:"): continue
            payload = line[5:].strip()
            if payload == b"[DONE]": continue
            try: d = json.loads(payload)
            except Exception: continue
            delta = d.get("choices", [{}])[0].get("delta", {}).get("content")
            if delta:
                if ttft is None: ttft = time.time() - t0
                text.append(delta)
    c.close()
    return "".join(text), ttft or (time.time() - t0), time.time() - t0

def conv(i):
    sysmsg = f"[{TAG}-c{i}] You are a meticulous analyst. " + " ".join(["ctx"] * 5000)
    msgs = [{"role": "system", "content": sysmsg}]
    for t in range(TURNS):
        msgs.append({"role": "user", "content": QS[t % len(QS)]})
        try:
            a, ttft, e2e = turn(HOST, msgs)
        except Exception as e:
            with lock: rows.append({"conv": i, "turn": t, "err": str(e)[:80]})
            return
        msgs.append({"role": "assistant", "content": a})
        with lock: rows.append({"conv": i, "turn": t, "ttft": round(ttft, 3), "e2e": round(e2e, 1), "chars": len(a)})

t0 = time.time()
ths = [threading.Thread(target=conv, args=(i,)) for i in range(C)]
for x in ths: x.start()
for x in ths: x.join()
dur = time.time() - t0

with open(OUT, "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
ok = [r for r in rows if "ttft" in r]; er = [r for r in rows if "err" in r]
def pct(v, p):
    v = sorted(v); return v[min(len(v)-1, int(p*len(v)))] if v else 0
print(f"{TAG}: turns ok={len(ok)} err={len(er)} dur={dur:.0f}s")
for t in range(TURNS):
    tv = [r["ttft"] for r in ok if r["turn"] == t]
    if tv: print(f"  turn{t}: n={len(tv)} ttft p50={pct(tv,.5):.2f} p95={pct(tv,.95):.2f}")
allt = [r["ttft"] for r in ok]
print(f"  ALL: ttft p50={pct(allt,.5):.2f} p95={pct(allt,.95):.2f} p99={pct(allt,.99):.2f} gen_chars_avg={sum(r['chars'] for r in ok)//max(1,len(ok))}")
