import json, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
EP, NONCE = sys.argv[1], sys.argv[2]
W = "route cache block prefix decode tier pull peer session lookup offload tensor page score filter epoch batch stream token merge".split()
PREFIX = f"gate-{NONCE} unique pool document: " + " ".join(W[(hash(NONCE)+i) % len(W)] for i in range(16000))
def one(i):
    body = json.dumps({"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":PREFIX+f" q{i}?","max_tokens":8,"temperature":0}).encode()
    r = urllib.request.Request(EP+"/v1/completions", data=body, headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            return bool(json.loads(resp.read()).get("choices"))
    except Exception as e:
        return str(e)[:60]
print("seed:", one(0)); time.sleep(12)
with ThreadPoolExecutor(max_workers=8) as ex:
    res = list(ex.map(one, range(1, 41)))
print("burst ok:", sum(1 for x in res if x is True), "/ 40")
