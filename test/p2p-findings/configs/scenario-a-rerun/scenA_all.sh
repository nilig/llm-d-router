#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenA_runarm.sh scenD-arm-affinity.yaml  affinity  no  sd1.yaml
./scenA_runarm.sh scenB-arm-load.yaml      load      no  sb2.yaml
./scenA_runarm.sh scenB-arm-load-p2p.yaml  load-p2p  yes sb3.yaml
echo "=== SCENARIO A ALL ARMS COMPLETE ==="
