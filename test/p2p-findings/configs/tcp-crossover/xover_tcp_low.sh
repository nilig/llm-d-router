#!/bin/bash
# Second half of the TCP ladder: the short lengths, same rig, same driver,
# same build as the 32K-48K sweep, so the whole ladder is self-consistent.
# The guide's current no-RDMA column was stitched from a different build and
# disagrees with this rig at 32K (+18.2% there vs -4.9% here).
set -u
NS=nilig-p2p
cd "$(dirname "$0")"
while kubectl exec -n $NS scenc-loadgen -- sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "xove[r].py" && echo x; done; true' 2>/dev/null | grep -q x; do
  sleep 30
done
read -r A B <<<"$(kubectl get pods -n $NS -l app=xover,build=tcp -o jsonpath='{.items[0].status.podIP} {.items[1].status.podIP}')"
echo "=== low-end sweep on same rig: src=$A dst=$B ==="
kubectl exec -n $NS scenc-loadgen -- sh -c \
  "nohup python3 -u /driver/xover.py http://$A:8000 http://$B:8000 $A tcp-crossover-low 2048,8192,16384,24576 5 > /tmp/xover_tcp_low.log 2>&1 & echo started"
last=0
while true; do
  body=$(kubectl exec -n $NS scenc-loadgen -- cat /tmp/xover_tcp_low.log 2>/dev/null)
  n=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
  if [ "$n" -gt "$last" ]; then printf '%s\n' "$body" | tail -n +$((last+1)); last=$n; fi
  printf '%s' "$body" | grep -q "^# done" && break
  alive=$(kubectl exec -n $NS scenc-loadgen -- sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "xove[r].py" && echo x; done; true' 2>/dev/null | wc -l | tr -d ' ')
  [ "${alive:-0}" -gt 0 ] || { echo "LOW SWEEP ENDED"; break; }
  sleep 30
done
kubectl exec -n $NS scenc-loadgen -- cat /tmp/xover_tcp_low.log > xover_tcp_low_result.log 2>/dev/null
echo "LOW SWEEP COMPLETE"
