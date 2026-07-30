#!/bin/bash
# Assert the EPP is serving the intended arm. Reads ONLY the file named by
# --config-file: the ConfigMap carries every arm as a separate file, so
# grepping the whole map matches other arms' configs and proves nothing.
# Fails loudly if the config body is empty, so an unresolved lookup can never
# read as a pass.
# Usage: arm_gate.sh <yes|no> [expected-config-filename]
# The filename check catches a helm upgrade that failed silently and left
# the EPP serving a previous scenario's config.
NS=nilig-p2p
EXPECT=$1
EXPECT_FILE="${2:-}"
kubectl get deploy llm-d-router-epp -n $NS -o json > /tmp/_epp_deploy.json
kubectl get cm llm-d-router-epp -n $NS -o json > /tmp/_epp_cm.json
python3 - "$EXPECT" "$EXPECT_FILE" <<'PY'
import json, sys
expect = sys.argv[1]
expect_file = sys.argv[2] if len(sys.argv) > 2 else ''
d = json.load(open('/tmp/_epp_deploy.json'))
cm = json.load(open('/tmp/_epp_cm.json'))
f = None
for c in d['spec']['template']['spec']['containers']:
    if c['name'] == 'epp':
        a = c['args']; f = a[a.index('--config-file')+1].split('/')[-1]
print('active config file:', f)
if expect_file and f != expect_file:
    print(f'GATE FAIL: EPP is serving {f!r}, expected {expect_file!r} - the helm upgrade did not take')
    sys.exit(1)
body = cm.get('data', {}).get(f)
if not body:
    print(f'GATE FAIL: config file {f!r} not found in ConfigMap (keys={list(cm.get("data",{}))})')
    sys.exit(1)
p2p = body.count('type: p2p-source-producer')
lru = body.count('no-hit-lru-scorer')
pcs = body.count('prefix-cache-scorer')
print(f'  bytes={len(body)}  p2p-source-producer={p2p}  no-hit-lru-scorer={lru}  prefix-cache-scorer={pcs}')
if expect == 'no' and p2p != 0:
    print('GATE FAIL: expected NO p2p producer'); sys.exit(1)
if expect == 'yes' and p2p == 0:
    print('GATE FAIL: expected a p2p producer'); sys.exit(1)
print('GATE OK')
PY
