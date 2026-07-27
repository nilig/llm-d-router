"""Fleet in-flight depth and its distribution across pods.

The point is the shape, not the total: a cold precise-affinity fleet scores
every endpoint identically (nothing is cached), so a deterministic picker can
send the whole offered concurrency to one pod.
"""
import subprocess, concurrent.futures as cf, sys, time
def pods():
    out=subprocess.run(["kubectl","get","pods","-n","nilig-p2p","-l","app=scend-agg","-o","name"],
                       capture_output=True,text=True).stdout.split()
    return [p.split('/',1)[1] for p in out]
def scrape(p):
    m=subprocess.run(["kubectl","exec","-n","nilig-p2p",p,"-c","modelserver","--","sh","-c",
                      "curl -s --max-time 20 localhost:8200/metrics"],capture_output=True,text=True).stdout
    r=w=h=q=0.0
    for ln in m.splitlines():
        if ln.startswith('vllm:num_requests_running'): r+=float(ln.rsplit(' ',1)[1])
        elif ln.startswith('vllm:num_requests_waiting{'): w+=float(ln.rsplit(' ',1)[1])
        elif ln.startswith('vllm:prefix_cache_hits_total'): h+=float(ln.rsplit(' ',1)[1])
        elif ln.startswith('vllm:prefix_cache_queries_total'): q+=float(ln.rsplit(' ',1)[1])
    return (p[-5:], r, w, h, q, bool(m))
for i in range(int(sys.argv[1]) if len(sys.argv)>1 else 1):
    with cf.ThreadPoolExecutor(16) as ex:
        rows=[x for x in ex.map(scrape, pods()) if x[5]]
    R=sum(x[1] for x in rows); W=sum(x[2] for x in rows)
    H=sum(x[3] for x in rows); Q=sum(x[4] for x in rows)
    busy=sum(1 for x in rows if x[1]+x[2]>0)
    top=max(rows,key=lambda x:x[1]+x[2]) if rows else None
    share=100*(top[1]+top[2])/(R+W) if R+W else 0
    print(f"[{time.strftime('%H:%M:%S')}] inflight={R+W:5.0f}/128  busy_pods={busy:2d}/{len(rows)}  "
          f"top_pod={top[0]} holds {top[1]+top[2]:3.0f} ({share:4.1f}%)  fleet_hit={100*H/Q if Q else 0:4.1f}%", flush=True)
    if i+1 < (int(sys.argv[1]) if len(sys.argv)>1 else 1): time.sleep(30)
