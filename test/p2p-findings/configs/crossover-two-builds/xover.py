"""Pull-vs-recompute crossover (guide Step 0) for one engine build.

Replicates the guide's stated method so the numbers are directly comparable
to its published table: 5-rep medians, warm mesh, UNIQUE prefix per
repetition, prefix lengths 2K/8K/16K/32K/48K.

Per (length, rep) two independent prefixes are used, because the consumer
caches whatever it just served:
  recompute : seed prefix_r on A, send to B with NO p2p params  -> B computes
  pull      : seed prefix_p on A, send to B WITH p2p params     -> B pulls

The engine reads `kv_transfer_params.remote_kv_source` = {kv_request_id,
remote_host, remote_port} (see _remote_kv_source_params in the p2p tier's
manager.py). NOTE: the sidecar's internal field constant is named "p2p"
(requestFieldP2PParams) but that is NOT the wire key the engine parses -
injecting under "p2p" is silently ignored and the request just recomputes.
No sidecar or EPP is in this path; the driver injects directly.

The mesh is warmed first: the first pull between two peers pays a one-time
session-establishment cost the guide measured at ~6s, so an unwarmed probe
reads the transient rather than steady-state pull cost.

Usage: xover.py <src_url> <dst_url> <src_cluster_ip> <label> [lengths_csv] [reps]

`src_url`/`dst_url` are how THIS driver reaches the pods (port-forwards).
`src_cluster_ip` is what the consumer engine dials for the pull, so it must
be the source pod's in-cluster IP, not the forwarded address.
"""
import json
import statistics
import sys
import time
import urllib.request
import uuid

SRC_URL, DST_URL, SRC_IP, LABEL = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
LENGTHS = [int(x) for x in sys.argv[5].split(",")] if len(sys.argv) > 5 else [2048, 8192, 16384, 32768, 49152]
REPS = int(sys.argv[6]) if len(sys.argv) > 6 else 5
MODEL = "openai/gpt-oss-120b"
P2P_PORT = 7777
TIMEOUT = 300

WORDS = ("route cache block prefix decode tier pull peer session lookup offload "
         "tensor page score filter epoch batch stream token merge").split()


def make_prefix(tag, ntok):
    # ~1 token per word for this vocabulary; unique per tag so nothing is
    # ever served twice.
    return f"xover {tag} " + " ".join(WORDS[(hash(tag) + i) % len(WORDS)] for i in range(ntok))


def post(url, prompt, p2p_src=None, max_tokens=1):
    body = {"model": MODEL, "prompt": prompt, "max_tokens": max_tokens, "temperature": 0}
    if p2p_src:
        body["kv_transfer_params"] = {"remote_kv_source": {
            "kv_request_id": str(uuid.uuid4()),
            "remote_host": p2p_src,
            "remote_port": P2P_PORT,
        }}
    req = urllib.request.Request(f"{url}/v1/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        r.read()
    return (time.monotonic() - t0) * 1000.0


def warm_mesh():
    """Force one pull so the P2P session is established before timing."""
    tag = f"warm-{uuid.uuid4().hex[:8]}"
    p = make_prefix(tag, 4096)
    post(SRC_URL, p)
    time.sleep(3)
    dt = post(DST_URL, p, p2p_src=SRC_IP)
    print(f"# mesh warm: first pull {dt:.0f} ms (one-time session cost, discarded)", flush=True)


def main():
    print(f"# build={LABEL} src={SRC_URL} dst={DST_URL} p2p_remote_host={SRC_IP} reps={REPS}", flush=True)
    warm_mesh()
    print(f"{'tokens':>8} {'recompute_ms':>13} {'pull_ms':>10} {'delta':>8}", flush=True)
    rows = []
    for n in LENGTHS:
        rec, pul = [], []
        for r in range(REPS):
            tag_r = f"{LABEL}-r-{n}-{r}-{uuid.uuid4().hex[:6]}"
            pr = make_prefix(tag_r, n)
            post(SRC_URL, pr)                  # seed on A (offloads to its tier)
            time.sleep(2)
            rec.append(post(DST_URL, pr))      # B recomputes (no p2p params)

            tag_p = f"{LABEL}-p-{n}-{r}-{uuid.uuid4().hex[:6]}"
            pp = make_prefix(tag_p, n)
            post(SRC_URL, pp)                  # seed on A
            time.sleep(2)
            pul.append(post(DST_URL, pp, p2p_src=SRC_IP))  # B pulls from A

        mr, mp = statistics.median(rec), statistics.median(pul)
        d = 100.0 * (mp - mr) / mr
        rows.append((n, mr, mp, d))
        print(f"{n:>8} {mr:>13.1f} {mp:>10.1f} {d:>+7.1f}%", flush=True)
    print("# done", flush=True)


if __name__ == "__main__":
    main()
