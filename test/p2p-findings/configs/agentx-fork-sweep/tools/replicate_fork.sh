#!/usr/bin/env bash
# Replicate the measured real-fork experiment on our cell.
#
# Window: d5654f5758cb49-g3, the exact measured group (W=8, 75,520-token
# prefix, ~21s spawn gaps > ~12s prefix compute, so the index seeds between
# spawns). Cut at the last child's first request per the measured protocol;
# 6 tail turns of one child dropped for our 120K max-model-len (source cell
# ran MAX_MODEL_LEN=auto) -- all 8 branch starts intact.
#
# Arms: spill-on/spill-off (token-precise pair). The spill mechanism is the
# point: prefix-cache-affinity-filter models the holder as busy for
# tokens/peakPrefillThroughput seconds, so siblings arriving inside the seed's
# modeled window get placed on cold ranks and the p2p producer directs a pull.
# blog-precise never spills at low load (3,088 evaluations, delta pinned at 0).
#
# Cross-arm cache inheritance is handled by --cache-bust first_turn_prefix in
# the runner, per the measured protocol -- no counterbalancing needed.
#
# UNTESTED COMBINATION GUARD: token-precise on the kv-source-endpoint image has
# not fired PreRequest before (campaign 1 ran it on the upstream image and was
# silent). If no p2psource evaluation lines appear while requests flow, abort
# fast instead of burning the window.
set -uo pipefail
cd "$(dirname "$0")"

NS=nilig-agentx-slo
EPP=agentx-slo-epp
POD=workload-access
W=windows-cut/d5654f5758cb49-g3

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
cleanup() { [ -n "${KW_PID:-}" ] && kill "$KW_PID" 2>/dev/null; }
trap cleanup EXIT

ready() {
  timeout 30 kubectl -n "$NS" get lws -o json 2>/dev/null \
    | python3 -c "import json,sys;print(sum(x.get('status',{}).get('readyReplicas',0) or 0 for x in json.load(sys.stdin)['items']))" 2>/dev/null || echo 0
}

log "waiting for both engines Ready (prefill is pending a node)"
for i in $(seq 1 720); do
  [ "$(ready)" -ge 2 ] && break
  sleep 30
done
[ "$(ready)" -ge 2 ] || { log "FAILED: engines not Ready"; exit 1; }
log "engines Ready"

log "tier check (expect ~6,125 blocks/rank for 20 GiB)"
kubectl -n "$NS" logs glm-5-2-prefill-0 -c vllm --tail=300000 2>/dev/null \
  | grep -oE "primary tier \(lru, [0-9]+ blocks\)" | tail -1

./keep_warm.sh >/tmp/replicate-keepwarm.log 2>&1 &
KW_PID=$!
log "keep-warm armed"

run_arm() {
  local tag=$1 cfg=$2
  log "=== $tag ($cfg)"
  rm -rf "$W/artifacts/$tag"
  # abort-fast watchdog: once the job is running, require p2psource lines
  # within 180s on the p2p arm (PreRequest logs on EVERY request there).
  if [ "$tag" = "spill-on" ]; then
    ( for i in $(seq 1 18); do
        sleep 10
        [ -f "$W/epp-${tag}.jsonl" ] || continue
        if grep -qE "evaluating KV cache source|no best-match peer stashed" "$W/epp-${tag}.jsonl"; then
          echo "[watchdog] PreRequest is firing"; exit 0
        fi
      done
      echo "[watchdog] WARNING: no p2psource lines after 180s -- combination likely silent" ) &
  fi
  # run_fork_arm.sh stages $W/trace.json itself (overwriting the older
  # full-length staging of this window id with the cut version).
  NS=$NS EPP=$EPP PVC_POD=$POD ARM_CONFIG=$cfg ./run_fork_arm.sh "$W" "$tag" 2>&1 | sed "s/^/[$tag] /"
  local n=0
  [ -f "$W/epp-${tag}.jsonl" ] && n=$(grep -c "set KV cache source header" "$W/epp-${tag}.jsonl" 2>/dev/null || echo 0)
  log "$tag: pulls issued = $n | ready = $(ready)"
}

run_arm spill-on  /config/spill-on.yaml
./.venv/bin/python delta_stats.py "$W/epp-spill-on.jsonl" --label "spill-on d5654f-g3" | tee -a sweep-results.txt

run_arm spill-off /config/spill-off.yaml

log "=== analysis"
./.venv/bin/python analyze_fork_run.py --manifest "$W/manifest.json" \
  --arm control:"$W/artifacts/spill-off" --arm p2p:"$W/artifacts/spill-on" \
  --epp p2p:"$W/epp-spill-on.jsonl" --json "$W/analysis.json" 2>&1 | tee "$W/analysis.txt"
log "replication complete"
