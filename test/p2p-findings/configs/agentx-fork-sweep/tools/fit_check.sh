#!/usr/bin/env bash
# Gate: the approximate index's lruCapacityPerServer must equal the engines'
# real per-rank tier capacity, read from the engine's own boot line
#   "primary tier (lru, N blocks)"
# The weka 8-cell matrix ran 200000 against a real ~7,700 and the index
# modeled evicted blocks as held: zero pulls, silently. This turns that
# mismatch into a refusal.
#
#   ./fit_check.sh <config.yaml> [role]     role defaults to prefill
set -uo pipefail
NS=${NS:-nilig-agentx-slo}
CFG=${1:?arm config yaml}
ROLE=${2:-prefill}

configured=$(grep -E "^\s*lruCapacityPerServer:" "$CFG" | head -1 | grep -oE "[0-9]+")
[ -n "$configured" ] || { echo "FAIL: no lruCapacityPerServer in $CFG"; exit 1; }

pods=$(kubectl -n "$NS" get pods -o name 2>/dev/null | grep -oE "glm-5-2-${ROLE}-[0-9-]+" | sort -u)
[ -n "$pods" ] || { echo "FAIL: no ${ROLE} pods running"; exit 1; }

fail=0
for pod in $pods; do
  # every rank on the pod logs its own tier size; they must agree
  sizes=$(kubectl -n "$NS" logs "$pod" -c vllm --tail=300000 2>/dev/null \
    | grep -oE "primary tier \(lru, [0-9]+ blocks\)" | grep -oE "[0-9]+" | sort -u)
  if [ -z "$sizes" ]; then
    echo "FAIL: $pod logged no 'primary tier (lru, N blocks)' line (offload tier absent?)"
    fail=1; continue
  fi
  n=$(echo "$sizes" | wc -l | tr -d ' ')
  if [ "$n" -ne 1 ]; then
    echo "FAIL: $pod ranks disagree on tier size: $(echo $sizes | tr '\n' ' ')"
    fail=1; continue
  fi
  if [ "$sizes" != "$configured" ]; then
    echo "FAIL: $pod tier=$sizes blocks but $CFG configures lruCapacityPerServer=$configured"
    fail=1
  else
    echo "OK: $pod tier=$sizes == configured $configured"
  fi
done
exit $fail
