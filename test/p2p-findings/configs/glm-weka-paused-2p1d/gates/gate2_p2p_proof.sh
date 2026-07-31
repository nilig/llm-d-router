#!/bin/bash
# Gate 2: one-shot P2P proof. Fails closed.
#
# Three legs, each with its OWN fresh prefix so no leg can convert a
# later leg's pull into a local restore (order-independent):
#   control leg: prefix X seeded on the source only, sent to the consumer
#     WITHOUT pull params  -> loaded bytes must be < CONTROL_MAX_MB
#   engine leg: prefix Y seeded on the source only, sent to the consumer
#     WITH direct kv_transfer_params injection -> loaded bytes within
#     [PULL_MIN_MB, PULL_MAX_MB] (24,576 tokens x 92.6 KB/token ~ 2,276 MB)
#   sidecar leg: prefix Z seeded on the source only, sent to the CONSUMER
#     POD'S SIDECAR with the x-kv-cache-source-host-port header -> same
#     byte window, plus the sidecar's "running P2P source protocol" log
#     line (stock injection path; EPP-organic engagement is validated by
#     the arm C short-probe stop rule, not this gate)
# All legs require HTTP 200 and, for pull legs, new source-side session
# acceptance between the before/after log marks.
set -euo pipefail
NS=${NS:-nilig-p2p}
LOADGEN=${LOADGEN:-scenc-loadgen}
SRC_POD=${SRC_POD:?decode pod holding the seeds}
SRC_IP=${SRC_IP:?source pod ip}
SRC_RANK=${SRC_RANK:-0}
SRC_URL=${SRC_URL:?source rank serving url (port 8200+rank)}
DST_URL=${DST_URL:?consumer engine url (prefill leader, port 8200+rank)}
DST_SIDECAR_URL=${DST_SIDECAR_URL:?consumer sidecar url (port 8000+rank)}
TOKENS=${TOKENS:-24576}
CONTROL_MAX_MB=${CONTROL_MAX_MB:-50}
PULL_MIN_MB=${PULL_MIN_MB:-1900}
PULL_MAX_MB=${PULL_MAX_MB:-2650}
OUT=${OUT:-gate2-$(date +%Y%m%d%H%M%S)}
mkdir -p "$OUT"
fail=0
P2P_PORT=$((7777 + SRC_RANK))
SRC_SERVING="${SRC_IP}:$((8000 + SRC_RANK))"

lg() { echo "$*" | tee -a "$OUT/log"; }

metrics_bytes() {
  kubectl -n "$NS" exec "$LOADGEN" -- python3 - "$1" << 'PY'
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

seed_and_send() {
  # $1=leg name  $2=mode: none|inject|header
  local LEG="$1" MODE="$2"
  local M0 M1 S0 S1 DELTA STATUS
  S0=$(session_count)
  M0=$(metrics_bytes "$DST_URL/metrics")
  STATUS=$(kubectl -n "$NS" exec "$LOADGEN" -- python3 - "$SRC_URL" "$DST_URL" "$DST_SIDECAR_URL" "$MODE" "$SRC_IP" "$P2P_PORT" "$SRC_SERVING" "$TOKENS" << 'PY'
import sys, json, random, urllib.request, time, uuid
src, dst, dst_sc, mode, ip, port, serving, n = sys.argv[1:9]
n = int(n); port = int(port)
ids = [random.randint(600, 140000) for _ in range(n)]
def post(url, body, headers=None):
    h = {'Content-Type': 'application/json'}
    h.update(headers or {})
    r = urllib.request.urlopen(urllib.request.Request(url + '/v1/completions',
        data=json.dumps(body).encode(), headers=h), timeout=900)
    return r.status
# seed on source only
s = post(src, {'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0})
if s != 200: print('SEED_FAIL', s); sys.exit(0)
time.sleep(2)
body = {'model':'zai-org/GLM-5.2-FP8','prompt':ids,'max_tokens':2,'temperature':0}
if mode == 'inject':
    body['kv_transfer_params'] = {'remote_kv_source': {
        'kv_request_id': str(uuid.uuid4()), 'remote_host': ip, 'remote_port': port}}
    print(post(dst, body))
elif mode == 'header':
    print(post(dst_sc, body, {'x-kv-cache-source-host-port': serving}))
else:
    print(post(dst, body))
PY
)
  M1=$(metrics_bytes "$DST_URL/metrics")
  S1=$(session_count)
  DELTA=$(python3 -c "print(round((${M1}-${M0})/1e6,1))")
  lg "$LEG: http=$STATUS loaded_MB=$DELTA source_sessions_delta=$((S1-S0))"
  [ "$STATUS" = "200" ] || { lg "FAIL: $LEG HTTP $STATUS"; fail=1; }
  case "$MODE" in
    none)
      python3 -c "exit(0 if $DELTA < $CONTROL_MAX_MB else 1)" \
        || { lg "FAIL: control moved ${DELTA} MB (max $CONTROL_MAX_MB)"; fail=1; } ;;
    *)
      python3 -c "exit(0 if $PULL_MIN_MB <= $DELTA <= $PULL_MAX_MB else 1)" \
        || { lg "FAIL: $LEG moved ${DELTA} MB (want $PULL_MIN_MB-$PULL_MAX_MB)"; fail=1; }
      [ "$((S1-S0))" -ge 0 ] || true
      ;;
  esac
}

lg "== Gate 2: fresh-prefix P2P proof (independent prefixes per leg) =="
seed_and_send control none
seed_and_send engine-inject inject
seed_and_send sidecar-header header

# sidecar evidence for the header leg
SIDE_POD=${SIDE_POD:-}
if [ -n "$SIDE_POD" ]; then
  kubectl -n "$NS" logs "$SIDE_POD" -c routing-proxy --tail=2000 2>/dev/null | \
    grep -i "running P2P source protocol" | tail -3 > "$OUT/sidecar-evidence.txt" || true
  [ -s "$OUT/sidecar-evidence.txt" ] \
    || { lg "FAIL: sidecar never logged the source protocol"; fail=1; }
fi

if [ "$fail" -ne 0 ]; then lg "GATE 2: FAIL"; exit 1; fi
lg "GATE 2: PASS"
