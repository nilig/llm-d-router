#!/bin/sh
# Crossover sweep v2: same 3-step protocol, but the PULL request carries the
# kv_transfer_params.p2p block the sidecar would inject (v1 proved the engine
# does not pull without it). Source = engine A (prefill-0 rank 0, port 7777).
NS=nilig-p2p
DIR=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/a5536e3c-535b-499e-b9eb-5ba4d86c97ae/scratchpad/glm-p2p
A=wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill-0
B=wide-ep-lws-nvidia-gpu-vllm-glm-5-2-prefill-0-1
OUT=$DIR/glm-crossover-results2.tsv
LOG=$DIR/glm-crossover-sweep2.log
: > "$LOG"
echo "L_target	prompt_tokens	cold_s	warm_s	pull_s	B_load_GB	verdict" > "$OUT"
ts() { date +%H:%M:%S 2>/dev/null || echo t; }

AIP=$(kubectl -n $NS get pod $A -o jsonpath='{.status.podIP}' 2>/dev/null)
echo "[$(ts)] source engine A podIP=$AIP (rank0, p2p port 7777)" >> "$LOG"
[ -n "$AIP" ] || { echo "no A pod IP - abort" >> "$LOG"; exit 1; }

payload() { # $1=n_words $2=nonce $3=pull(0/1) -> json on stdout
  python3 - "$1" "$2" "$3" "$AIP" <<'PY'
import json,sys,uuid
n=int(sys.argv[1]); nonce=sys.argv[2]; pull=sys.argv[3]=="1"; aip=sys.argv[4]
words=" ".join(f"w{nonce}x{i:06d}" for i in range(n))
d={"model":"zai-org/GLM-5.2-FP8","prompt":words,"max_tokens":1,"temperature":0}
if pull:
    d["kv_transfer_params"]={"p2p":{"kv_request_id":str(uuid.uuid4()),
                                    "remote_host":aip,"remote_port":7777}}
print(json.dumps(d))
PY
}

req() { # $1=pod; stdin json; stdout "time_total|prompt_tokens"
  kubectl -n $NS exec -i "$1" -c vllm -- sh -c '
    T=$(mktemp); cat > "$T"; R=$(mktemp)
    TT=$(curl -s -o "$R" -w "%{time_total}" --max-time 600 \
      -X POST localhost:8000/v1/completions \
      -H "Content-Type: application/json" --data-binary @"$T")
    PT=$(python3 -c "import json;print(json.load(open(\"$R\")).get(\"usage\",{}).get(\"prompt_tokens\",0))" 2>/dev/null || echo 0)
    echo "$TT|$PT"; rm -f "$T" "$R"' 2>/dev/null
}

b_load() {
  kubectl -n $NS exec "$B" -c vllm -- sh -c \
    'curl -s localhost:8000/metrics | grep "kv_offload_load_bytes_total" | grep -v "^#" | awk "{s+=\$2}END{print s+0}"' 2>/dev/null
}

for L in 8192 12288 16384 24576 32768; do
  N=$((L * 10 / 26)); NONCE="v2s${L}"   # v1 measured ~2.6 tokens/word
  P0=$(payload $N $NONCE 0)
  P1=$(payload $N $NONCE 1)
  C=$(printf '%s' "$P0" | req $A);  COLD=${C%|*};  PT=${C#*|}
  sleep 3
  W=$(printf '%s' "$P0" | req $A);  WARM=${W%|*}
  sleep 3
  L0=$(b_load)
  PU=$(printf '%s' "$P1" | req $B); PULL=${PU%|*}
  sleep 3
  L1=$(b_load)
  DGB=$(python3 -c "print(f'{(${L1:-0}-${L0:-0})/1e9:.2f}')")
  EXP=$(python3 -c "print(f'{${PT:-0}*93e3/1e9:.2f}')")
  V=$(python3 -c "
d=${DGB}; e=${EXP}
print('PULL_OK' if e>0 and d>0.5*e else 'NOPULL')")
  echo "$L	$PT	$COLD	$WARM	$PULL	$DGB	$V" >> "$OUT"
  echo "[$(ts)] L=$L tokens=$PT cold=${COLD}s warm=${WARM}s pull=${PULL}s Bload=${DGB}GB(exp ${EXP}) $V" >> "$LOG"
done
echo "[$(ts)] SWEEP2 COMPLETE" >> "$LOG"
