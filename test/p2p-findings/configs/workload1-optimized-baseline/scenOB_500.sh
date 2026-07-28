#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenOB_runarm.sh scenOB-arm-ref500.yaml ref500 no  ob3.yaml
./scenOB_runarm.sh scenOB-arm-p2p500.yaml p2p500 yes ob4.yaml
echo "=== PENALTY500 AB COMPLETE ==="
