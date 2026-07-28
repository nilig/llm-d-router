#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenB_runarm.sh scenB-arm-affinity.yaml   affinity   no  sb1.yaml
./scenB_runarm.sh scenB-arm-load.yaml       load       no  sb2.yaml
./scenB_runarm.sh scenB-arm-load-p2p.yaml   load-p2p   yes sb3.yaml
echo "=== SCENARIO B ALL ARMS COMPLETE ==="
for f in scenB_*.log; do echo "--- $f"; cat "$f"; done
