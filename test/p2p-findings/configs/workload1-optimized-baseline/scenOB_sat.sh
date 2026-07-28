#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenOB_runarm.sh scenOB-arm-ref.yaml refsat no  ob1.yaml
./scenOB_runarm.sh scenOB-arm-p2p.yaml p2psat yes ob2.yaml
echo "=== SATURATION AB COMPLETE ==="
