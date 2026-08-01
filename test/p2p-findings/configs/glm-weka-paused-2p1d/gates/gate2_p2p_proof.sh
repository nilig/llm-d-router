#!/bin/bash
# Gate 2: one-shot P2P proof. Fails closed.
#
# Port semantics on this deployment: prefill engines serve rank r
# directly at 8000+r (metrics on the same port); decode engines serve at
# 8200+r behind the sidecar at 8000+r. The serving endpoint used for
# rank addressing is IP:8000+r on both roles.
#
# Three legs, each with its OWN fresh prefix so no leg can convert a
# later leg's pull into a local restore (order-independent). Source and
# destination are PREFILL ranks on different pods (the P/D-relevant
# direction):
#   control leg: prefix X seeded on the source prefill only, sent
#     engine-direct to the destination prefill WITHOUT pull params
#     -> destination loaded bytes must be < CONTROL_MAX_MB
#   engine leg: prefix Y seeded on the source prefill, sent
#     engine-direct to the destination prefill WITH kv_transfer_params
#     injection -> loaded bytes within [PULL_MIN_MB, PULL_MAX_MB]
#     (24,576 tokens x 92.6 KB/token ~ 2,276 MB)
#   pd leg (stock path): prefix Z seeded on the source prefill, sent to
#     a DECODE SIDECAR with x-prefiller-host-port = destination prefill
#     serving endpoint and x-kv-cache-source-host-port = source prefill
#     serving endpoint -> the sidecar's prefill-leg injection must move
#     the same byte window INTO the destination prefill engine
# All legs require HTTP 200; the pull legs together require >= 1 new
# source-side session. EPP-organic engagement is validated by
# gates/armC_probe.sh, not this gate.
set -euo pipefail
NS=${NS:-nilig-p2p}
LOADGEN=${LOADGEN:-scenc-loadgen}
SRC_POD=${SRC_POD:?source PREFILL pod name (for session-accept evidence)}
SRC_PF_URL=${SRC_PF_URL:?source prefill engine url http://ip:(8000+r)}
SRC_PF_SERVING=${SRC_PF_SERVING:?source prefill serving endpoint ip:(8000+r)}
DST_PF_URL=${DST_PF_URL:?destination prefill engine url http://ip:(8000+r), different pod}
DST_PF_SERVING=${DST_PF_SERVING:?destination prefill serving endpoint ip:(8000+r)}
DECODE_SIDECAR_URL=${DECODE_SIDECAR_URL:?decode sidecar url http://ip:(8000+rank)}
TOKENS=${TOKENS:-24576}
CONTROL_MAX_MB=${CONTROL_MAX_MB:-50}
PULL_MIN_MB=${PULL_MIN_MB:-1900}
PULL_MAX_MB=${PULL_MAX_MB:-2650}
OUT=${OUT:-gate2-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"
fail=0
SRC_RANK_PORT=${SRC_PF_SERVING##*:}
P2P_PORT=$((7777 + SRC_RANK_PORT - 8000))

lg() { echo "$*" | tee -a "$OUT/log"; }

metrics_bytes() {
  kubectl -n "$NS" exec -i "$LOADGEN" -- python3 - "$1" << 'PY'
import sys, urllib.request
txt = urllib.request.urlopen(sys.argv[1], timeout=30).read().decode()
def fam(match):
    total, seen = 0.0, False
    for ln in txt.splitlines():
        if ln.startswith('#') or not match(ln): continue
        try: total += float(ln.rsplit(' ',1)[1]); seen = True
        except (IndexError, ValueError): pass
    return total, seen
t, s = fam(lambda ln: 'kv_offload_load_bytes_total' in ln)
if not s:
    t, s = fam(lambda ln: 'kv_offload_total_bytes_total' in ln and 'CPU_to_GPU' in ln)
print(t if s else 0.0)
PY
}

session_count() {
  kubectl -n "$NS" logs "$SRC_POD" -c vllm --tail=200000 2>/dev/null | \
    grep -c "accepting incoming connection" || true
}

run_leg() {
  # $1=leg name  $2=mode: none|inject|pd
  local LEG="$1" MODE="$2"
  local M0 M1 DELTA STATUS
  M0=$(metrics_bytes "$DST_PF_URL/metrics")
  STATUS=$(kubectl -n "$NS" exec -i "$LOADGEN" -- python3 - \
    "$SRC_PF_URL" "$DST_PF_URL" "$DECODE_SIDECAR_URL" "$MODE" \
    "$SRC_PF_SERVING" "$DST_PF_SERVING" "$P2P_PORT" "$TOKENS" << 'PY'
import sys, json, random, urllib.request, time, uuid
src, dst, sidecar, mode, src_sv, dst_sv, p2p_port, n = sys.argv[1:9]
n = int(n); p2p_port = int(p2p_port)
ids = [random.randint(600, 140000) for _ in range(n)]
def post(url, body, headers=None):
    h = {'Content-Type': 'application/json'}
    h.update(headers or {})
    r = urllib.request.urlopen(urllib.request.Request(url + '/v1/completions',
        data=json.dumps(body).encode(), headers=h), timeout=900)
    return r.status
s = post(src, {'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0})
if s != 200: print('SEED_FAIL', s); sys.exit(0)
time.sleep(2)
body = {'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0}
if mode == 'inject':
    body['kv_transfer_params'] = {'remote_kv_source': {
        'kv_request_id': str(uuid.uuid4()), 'remote_host': src_sv.rsplit(':',1)[0],
        'remote_port': p2p_port}}
    print(post(dst, body))
elif mode == 'pd':
    print(post(sidecar, body, {
        'x-prefiller-host-port': dst_sv,
        'x-kv-cache-source-host-port': src_sv}))
else:
    print(post(dst, body))
PY
)
  # the P/D prefill leg is async on the sidecar; give the transfer a moment
  [ "$MODE" = "pd" ] && sleep 10
  M1=$(metrics_bytes "$DST_PF_URL/metrics")
  DELTA=$(python3 -c "print(round((${M1}-${M0})/1e6,1))")
  lg "$LEG: http=$STATUS dst_prefill_loaded_MB=$DELTA"
  [ "$STATUS" = "200" ] || { lg "FAIL: $LEG HTTP $STATUS"; fail=1; }
  case "$MODE" in
    none)
      python3 -c "exit(0 if $DELTA < $CONTROL_MAX_MB else 1)" \
        || { lg "FAIL: control moved ${DELTA} MB (max $CONTROL_MAX_MB)"; fail=1; } ;;
    *)
      python3 -c "exit(0 if $PULL_MIN_MB <= $DELTA <= $PULL_MAX_MB else 1)" \
        || { lg "FAIL: $LEG moved ${DELTA} MB into the destination prefill (want $PULL_MIN_MB-$PULL_MAX_MB)"; fail=1; } ;;
  esac
}

lg "== Gate 2: fresh-prefix P2P proof (independent prefixes per leg) =="
lg "source=$SRC_PF_SERVING (p2p port $P2P_PORT) destination=$DST_PF_SERVING"
S_PULL_START=$(session_count)
run_leg control none
run_leg engine-inject inject
run_leg pd-stock pd
S_PULL_END=$(session_count)
lg "source sessions across pull legs: $((S_PULL_END-S_PULL_START))"
[ "$((S_PULL_END-S_PULL_START))" -ge 1 ] \
  || { lg "FAIL: no new source-side session across the pull legs - transfers were not peer transfers"; fail=1; }

if [ "$fail" -ne 0 ]; then lg "GATE 2: FAIL"; exit 1; fi
lg "GATE 2: PASS"
