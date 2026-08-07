#!/usr/bin/env bash
# Bring up the 16-GPU p1w1d1w1 cell in nilig-agentx-slo, in two phases.
#
#   ./apply.sh plane    # everything that needs no GPUs -- safe any time
#   ./apply.sh engines  # the two LWS pods; needs 2 whole free 8-GPU nodes
#   ./apply.sh validate # require a live render endpoint returning token IDs
#   ./apply.sh check    # preflight only
set -euo pipefail

NS=nilig-agentx-slo
SRC_NS=nilig-p2p            # HF token secret source (read-only)
HERE=$(cd "$(dirname "$0")" && pwd)

phase=${1:-check}

free_whole_nodes() {
  kubectl get pods -A -o json | python3 -c "
import json,sys,subprocess
from collections import Counter
pods=json.load(sys.stdin)
nodes=json.loads(subprocess.run(['kubectl','get','nodes','-o','json'],
                                capture_output=True,text=True).stdout)
used=Counter()
for p in pods['items']:
    if p['status']['phase'] not in ('Running','Pending'): continue
    g=sum(int((c.get('resources',{}).get('limits') or {}).get('nvidia.com/gpu',0) or 0)
          for c in p['spec']['containers'])
    if g and p['spec'].get('nodeName'): used[p['spec']['nodeName']]+=g
n=0
for x in nodes['items']:
    a=int(x['status']['allocatable'].get('nvidia.com/gpu',0) or 0)
    if a>=8 and not x['spec'].get('unschedulable') and a-used.get(x['metadata']['name'],0)>=8:
        n+=1
print(n)"
}

validate_render() {
  local ready_endpoints pod

  ready_endpoints=$(kubectl -n "$NS" get endpointslices.discovery.k8s.io \
    -l kubernetes.io/service-name=glm-5-2-render -o json | python3 -c '
import json, sys
slices = json.load(sys.stdin)["items"]
print(sum(len(endpoint.get("addresses", []))
          for item in slices
          for endpoint in item.get("endpoints", [])
          if endpoint.get("conditions", {}).get("ready") is True))')
  if [[ "$ready_endpoints" -lt 1 ]]; then
    echo "render validation failed: glm-5-2-render has no Ready endpoints" >&2
    return 1
  fi

  pod=$(kubectl -n "$NS" get pods \
    -l 'llm-d.ai/model=GLM-5.2-FP8,llm-d.ai/role=prefill' -o json | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    conditions = {c["type"]: c["status"] for c in pod["status"].get("conditions", [])}
    if conditions.get("Ready") == "True":
        print(pod["metadata"]["name"])
        break')
  if [[ -z "$pod" ]]; then
    echo "render validation failed: no Ready prefill pod is available" >&2
    return 1
  fi

  kubectl -n "$NS" exec "$pod" -c vllm -- python3 -c '
import json
import urllib.request

payload = json.dumps({
    "model": "zai-org/GLM-5.2-FP8",
    "prompt": "render readiness check",
    "max_tokens": 1,
}).encode()
request = urllib.request.Request(
    "http://glm-5-2-render:8000/v1/completions/render",
    data=payload,
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=10) as response:
    body = json.load(response)
if not isinstance(body, list) or not body or not body[0].get("token_ids"):
    raise SystemExit(f"render response has no token IDs: {body!r}")
token_ids = body[0]["token_ids"]
print(f"render ready: {len(token_ids)} token IDs")'
}

case "$phase" in
check)
  echo "namespace:        $(kubectl get ns $NS -o name 2>/dev/null || echo MISSING)"
  echo "hf secret:        $(kubectl -n $NS get secret llm-d-hf-token -o name 2>/dev/null || echo MISSING)"
  echo "whole 8-GPU nodes free: $(free_whole_nodes)  (engines need 2)"
  echo "manifests:"
  ls -1 "$HERE"/manifests
  ;;

plane)
  # The HF token is required by the engines but the copy costs nothing now.
  if ! kubectl -n "$NS" get secret llm-d-hf-token >/dev/null 2>&1; then
    echo "copying llm-d-hf-token from $SRC_NS (read-only on the source)"
    kubectl -n "$SRC_NS" get secret llm-d-hf-token -o json \
      | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':'llm-d-hf-token','namespace':'$NS'}
d.pop('status',None)
print(json.dumps(d))" \
      | kubectl apply -f -
  fi
  # Ordered: PVC + arms, render, RBAC, EPP, pool. No GPU requests anywhere here.
  kubectl apply -f "$HERE/manifests/21-pvc.yaml"
  kubectl apply -f "$HERE/manifests/44-cm-arms.yaml"
  kubectl apply -f "$HERE/manifests/43-cm-envoy.yaml"
  kubectl -n "$NS" apply -f "$HERE/manifests/20-render.yaml"
  kubectl apply -f "$HERE/manifests/40-epp-rbac.yaml"
  kubectl apply -f "$HERE/manifests/41-epp.yaml"
  kubectl apply -f "$HERE/manifests/42-inferencepool.yaml"
  kubectl -n "$NS" rollout status deploy/agentx-slo-epp --timeout=10m
  echo "control plane up; engines still to come"
  ;;

engines)
  n=$(free_whole_nodes)
  if [[ "$n" -lt 2 ]]; then
    echo "only $n whole 8-GPU nodes free; engines need 2. Refusing to create a"
    echo "half-scheduled cell that holds one node hostage while pending."
    exit 1
  fi
  kubectl apply -f "$HERE/manifests/30-lws-prefill.yaml"
  kubectl apply -f "$HERE/manifests/31-lws-decode.yaml"
  echo "applied; boot is ~15 min prefill / ~25 min decode"
  kubectl -n "$NS" get lws
  ;;
validate)
  validate_render
  ;;
*)
  echo "usage: $0 {check|plane|engines|validate}"; exit 2 ;;
esac
