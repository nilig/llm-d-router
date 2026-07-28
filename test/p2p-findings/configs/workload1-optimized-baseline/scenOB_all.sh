#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenOB_runarm.sh scenOB-arm-ref.yaml ref no  ob1.yaml
./scenOB_runarm.sh scenOB-arm-p2p.yaml p2p yes ob2.yaml
echo "=== WORKLOAD1 BOTH ARMS COMPLETE ==="
