"""Single controlled bottleneck probe for Scenario C.

Sends a steady rate for SEND_S seconds and samples prefill/decode occupancy
ONLY inside the send window - sampling during drain makes prefill look idle
even when it is the constraint, which is what confounded the earlier reads.
"""
import json, subprocess, sys, threading, time, urllib.request

EP, RATE, SEND_S = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
MODEL = "openai/gpt-oss-120b"
W = ("route cache block prefix decode tier pull peer session lookup offload "
     "tensor page score filter epoch batch stream token merge").split()
NG = 128
PREF = [f"scenc pool group-{g} document: " + " ".join(W[(g*37+i) % len(W)] for i in range(48000))
        for g in range(NG)]
done = {"ok": 0, "fail": 0}
lk = threading.Lock()


def req(i):
    b = json.dumps({"model": MODEL, "prompt": PREF[i % NG] + f" q{i}?",
                    "max_tokens": 64, "temperature": 0}).encode()
    r = urllib.request.Request(EP + "/v1/completions", data=b,
                               headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(r, timeout=180).read()
        with lk: done["ok"] += 1
    except Exception:
        with lk: done["fail"] += 1


def pods(role):
    o = subprocess.run(["kubectl", "get", "pods", "-n", "nilig-p2p", "-l",
                        f"app=scenc,role={role}", "-o",
                        "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}"],
                       capture_output=True, text=True).stdout.split()
    return [p for p in o if p]


def sample(role, port, names):
    tot_run = tot_wait = tot_def = 0
    for p in names:
        m = subprocess.run(["kubectl", "exec", "-n", "nilig-p2p", p, "-c", "modelserver",
                            "--", "curl", "-s", "-m", "5", f"localhost:{port}/metrics"],
                           capture_output=True, text=True).stdout
        for line in m.splitlines():
            if line.startswith("vllm:num_requests_running"):
                tot_run += float(line.split()[-1])
            elif line.startswith("vllm:num_requests_waiting{"):
                tot_wait += float(line.split()[-1])
            elif 'reason="deferred"' in line:
                tot_def += float(line.split()[-1])
    return tot_run, tot_wait, tot_def


def main():
    pf, dc = pods("prefill"), pods("decode")
    print(f"# rate={RATE} send={SEND_S}s prefill={len(pf)} decode={len(dc)}", flush=True)
    stop = time.monotonic() + SEND_S
    i = 0
    nxt = time.monotonic()
    ths = []
    sampled = []
    next_sample = time.monotonic() + 20
    while time.monotonic() < stop:
        now = time.monotonic()
        if now >= next_sample:
            pr, pw, _ = sample("prefill", 8000, pf[:4])
            dr, dw, dd = sample("decode", 8200, dc[:4])
            line = (f"  t={int(now-(stop-SEND_S))}s  PREFILL run={pr:.0f} wait={pw:.0f}"
                    f"   DECODE run={dr:.0f} wait={dw:.0f} deferred={dd:.0f}")
            print(line, flush=True)
            sampled.append(line)
            next_sample = now + 20
            continue
        if now < nxt:
            time.sleep(0.005); continue
        t = threading.Thread(target=req, args=(i,), daemon=True); t.start()
        ths.append(t); i += 1; nxt += 1.0/RATE
    print(f"# sent={i} (draining...)", flush=True)
    for t in ths: t.join(timeout=200)
    print(f"# ok={done['ok']} fail={done['fail']}", flush=True)


if __name__ == "__main__":
    main()
