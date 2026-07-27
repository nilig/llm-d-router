#!/bin/bash
# Pin the no-RDMA (TCP fallback) pull-vs-recompute crossover.
# Prior 5-point data bracketed it between 32K and 48K; this sweeps that band
# at 4K resolution so minCachedTokenDelta is derivable for TCP deployments.
set -u
NS=nilig-p2p
cd "$(dirname "$0")"

for i in $(seq 1 60); do
  r=$(kubectl get pods -n $NS -l app=xover,build=tcp --no-headers 2>/dev/null | grep -c "1/1 *Running")
  echo "[$i] xtcp ready=$r/2"
  [ "$r" = "2" ] && break
  sleep 20
done
[ "$r" = "2" ] || { echo "ABORT: pods not ready"; exit 1; }

read -r A B <<<"$(kubectl get pods -n $NS -l app=xover,build=tcp -o jsonpath='{.items[0].status.podIP} {.items[1].status.podIP}')"
echo "src(A)=$A  dst(B)=$B"

echo "=== confirm NO rdma device in the container (this is the point) ==="
PA=$(kubectl get pods -n $NS -l app=xover,build=tcp -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$PA" -- sh -c 'ls /dev/infiniband 2>/dev/null || echo "NO /dev/infiniband (TCP fallback confirmed)"'

echo "=== sweep 32K-48K at 4K resolution, 5 reps ==="
kubectl exec -n $NS scenc-loadgen -- sh -c \
  "nohup python3 -u /driver/xover.py http://$A:8000 http://$B:8000 $A tcp-crossover 32768,36864,40960,45056,49152 5 > /tmp/xover_tcp.log 2>&1 & echo started"

last=0
while true; do
  body=$(kubectl exec -n $NS scenc-loadgen -- cat /tmp/xover_tcp.log 2>/dev/null)
  n=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
  if [ "$n" -gt "$last" ]; then printf '%s\n' "$body" | tail -n +$((last+1)); last=$n; fi
  printf '%s' "$body" | grep -q "^# done" && break
  alive=$(kubectl exec -n $NS scenc-loadgen -- sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "xover.py" && echo x; done; true' 2>/dev/null | wc -l | tr -d ' ')
  [ "${alive:-0}" -gt 0 ] || { echo "SWEEP ENDED"; break; }
  sleep 30
done
kubectl exec -n $NS scenc-loadgen -- cat /tmp/xover_tcp.log > xover_tcp_result.log 2>/dev/null
echo "SWEEP COMPLETE"
