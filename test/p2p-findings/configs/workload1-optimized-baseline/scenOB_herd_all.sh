#!/bin/bash
set -e
cd "$(dirname "$0")"
./scenOB_herd.sh scenOB-arm-ref.yaml herd-noP2P  no  ob1.yaml
./scenOB_herd.sh scenOB-arm-p2p.yaml herd-withP2P yes ob2.yaml
echo "=== HERD AB COMPLETE ==="
