"""Timestamped fleet counter sums every 15s, for offline per-stage attribution.

The driver prints `# stage_start/end rate=R t=<epoch>` markers; joining on
timestamps gives per-stage deltas of:
  hits/queries (GPU prefix cache), ext (external = offload-tier hits),
  load/store bytes (CPU tier traffic, local restores INCLUDED - the
  cross-arm delta at matched stages is the pull-attributable part).
"""
import subprocess, concurrent.futures as cf, sys, time

def pods():
    out = subprocess.run(["kubectl","get","pods","-n","nilig-p2p","-l","app=scend-agg","-o","name"],
                         capture_output=True, text=True).stdout.split()
    return [p.split('/',1)[1] for p in out]

KEYS = {
    'vllm:prefix_cache_hits_total': 'hits',
    'vllm:prefix_cache_queries_total': 'queries',
    'vllm:external_prefix_cache_hits_total': 'ext',
    'vllm:kv_offload_load_bytes_total': 'load_b',
    'vllm:kv_offload_store_bytes_total': 'store_b',
}

def scrape(p):
    m = subprocess.run(["kubectl","exec","-n","nilig-p2p",p,"-c","modelserver","--","sh","-c",
                        "curl -s --max-time 10 localhost:8200/metrics"],
                       capture_output=True, text=True).stdout
    acc = {}
    for ln in m.splitlines():
        for k, name in KEYS.items():
            if ln.startswith(k):
                try: acc[name] = acc.get(name,0.0) + float(ln.rsplit(' ',1)[1])
                except ValueError: pass
    return acc

while True:
    with cf.ThreadPoolExecutor(16) as ex:
        rows = list(ex.map(scrape, pods()))
    tot = {}
    n = 0
    for r in rows:
        if r: n += 1
        for k,v in r.items(): tot[k] = tot.get(k,0.0)+v
    print(f"t={time.time():.0f} pods={n} " +
          " ".join(f"{k}={tot.get(k,0):.0f}" for k in ('hits','queries','ext','load_b','store_b')),
          flush=True)
    time.sleep(15)
