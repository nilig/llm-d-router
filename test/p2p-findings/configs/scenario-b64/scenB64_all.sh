#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenB64_runarm.sh scenB-arm-affinity.yaml   affinity   no  sb1.yaml
./scenB64_runarm.sh scenB-arm-load.yaml       load       no  sb2.yaml
./scenB64_runarm.sh scenB-arm-load-p2p.yaml   load-p2p   yes sb3.yaml
echo "=== SCENARIO B64 ALL ARMS COMPLETE ==="
