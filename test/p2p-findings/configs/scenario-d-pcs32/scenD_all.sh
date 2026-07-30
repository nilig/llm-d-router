#!/bin/bash
# All three Scenario D arms, two runs each - the guide's own table shape.
set -e
cd "$(dirname "$0")"
./scenD_runarm.sh scenD-arm-affinity.yaml      affinity      no  sd1.yaml
./scenD_runarm.sh scenD-arm-affinity-p2p.yaml  affinity-p2p  yes sd2.yaml
./scenD_runarm.sh scenD-arm-load-p2p.yaml      load-p2p      yes sd3.yaml
echo "=== SCENARIO D ALL ARMS COMPLETE ==="
for f in scenD_*run*.log; do echo "--- $f"; grep -E "TTFT|throughput|duration" "$f" 2>/dev/null; done
