"""Step 0 crossover re-measurement, current fixed stack vs the guide's
original 2026-07-17 table (guides/p2p-kv-cache-sharing/benchmarking/README.md,
commit 4dcf3d53, unchanged since - diffed to confirm).

Goal: the guide's original table has no exact vLLM build/SHA recorded
(test/p2p-findings/capacity-number-provenance.md admits this explicitly -
"no specific SHA recorded"), only "nightly + generic_p2p branch". This
script re-runs the SAME methodology (single-request cold-pod prefill
latency, recompute vs P2P pull, 5 prefix lengths, 5-rep medians, warm-mesh
calibration) on today's fixed stack (nightly-1240c74c0a... +
combined-overlay-uc2resume) to see whether the raw numbers have moved -
NOT to attribute a specific cause, since the exact "before" build is
unknown.

Routes through the sidecar (port 8000) using its own
x-kv-cache-source-host-port header, the SAME mechanism the EPP uses for a
real pull (pkg/sidecar/proxy/chat_completions.go:135). An earlier version
of this script injected kv_transfer_params.p2p directly against the bare
engine port (8200), copying an older GLM crossover script's wire format -
that produced a 0% delta at every length, which turned out to be a silent
recompute fallback (verified via vllm:external_prefix_cache_hits_total
staying at 0 and prompt_tokens_by_source_total{source="external_kv_transfer"}
staying at 0 for the whole run - no session ever established, not even
during warm-mesh calibration). Going through the sidecar's own proven
header path instead of guessing the engine's raw wire format.

Usage: crossover_recheck.py <pod-A-name> <pod-B-name>
Pod A is the source (gets seeded); pod B is measured (recompute + pull).
"""
import json
import random
import subprocess
import statistics
import sys
import time

NS = "nilig-p2p"
MODEL = "openai/gpt-oss-120b"
LENGTHS = [2048, 8192, 16384, 32768, 49152]
REPS = 5
SETTLE_S = 1.5
SOURCE_HEADER = "x-kv-cache-source-host-port"

WORDS = ("route cache block prefix decode tier pull peer session lookup "
         "offload tensor page score filter epoch batch stream token merge").split()


def gen_prefix(n_tokens, nonce):
    # Per-nonce independent RNG stream (not a linear formula over nonce) -
    # a linear formula like WORDS[(nonce*k+i) % len(WORDS)] collides whenever
    # two nonces differ by a multiple of len(WORDS), silently making two
    # "different" prompts share almost all their content past the first few
    # tokens. That happened here: recompute and pull-source nonces differed
    # by exactly 500 (a multiple of the 20-word list), so pod B's own local
    # cache from the recompute call silently assisted the "pull" measurement
    # for the same rep (confirmed via a nonzero local_cache_hit counter that
    # should be impossible by design). random.Random(nonce) gives each nonce
    # a genuinely independent word sequence, no shared periodicity possible.
    rng = random.Random(nonce)
    return f"crossover nonce-{nonce}: " + " ".join(rng.choice(WORDS) for _ in range(n_tokens))


def pod_ip(name):
    out = subprocess.run(
        ["kubectl", "-n", NS, "get", "pod", name, "-o", "jsonpath={.status.podIP}"],
        capture_output=True, text=True, check=True)
    return out.stdout.strip()


def one_request(pod, prompt, pull_from_ip=None):
    body = {"model": MODEL, "prompt": prompt, "max_tokens": 1, "temperature": 0}
    data = json.dumps(body)
    header_args = ""
    if pull_from_ip:
        header_args = f'-H "{SOURCE_HEADER}: {pull_from_ip}:8000" '
    # Pass the temp file path as sys.argv[1] rather than interpolating it into
    # the python -c string - avoids nested shell/python quote-escaping entirely.
    shell_cmd = (
        'T=$(mktemp); cat > "$T"; R=$(mktemp); '
        'TT=$(curl -s -o "$R" -w "%{time_total}" --max-time 120 '
        '-X POST localhost:8000/v1/completions '
        f'{header_args}'
        '-H "Content-Type: application/json" --data-binary @"$T"); '
        'PT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); '
        'print(d.get(\'usage\', {}).get(\'prompt_tokens\', 0))" "$R" 2>/dev/null || echo 0); '
        'echo "$TT|$PT"; rm -f "$T" "$R"'
    )
    cmd = ["kubectl", "-n", NS, "exec", "-i", pod, "-c", "modelserver", "--", "sh", "-c", shell_cmd]
    r = subprocess.run(cmd, input=data, capture_output=True, text=True, timeout=150)
    line = r.stdout.strip().split("\n")[-1]
    t_str, pt_str = line.split("|")
    return float(t_str), int(pt_str)


def main():
    a, b = sys.argv[1], sys.argv[2]
    ip_a = pod_ip(a)
    print(f"# source(A)={a} ip={ip_a} target(B)={b} model={MODEL}", flush=True)

    warm_prompt = gen_prefix(4096, 999999)
    one_request(a, warm_prompt)
    time.sleep(SETTLE_S)
    t, pt = one_request(b, warm_prompt, pull_from_ip=ip_a)
    print(f"# warm-mesh calibration pull: {t:.3f}s ({pt} tokens) - discarded, session-establishment only", flush=True)

    print(f"{'tokens':>7} {'recompute_ms':>13} {'pull_ms':>9} {'delta':>7}", flush=True)
    for length in LENGTHS:
        recomputes, pulls, rc_tokens, pu_tokens = [], [], [], []
        for rep in range(REPS):
            rc_prompt = gen_prefix(length, length * 1000 + rep)
            t_rc, pt_rc = one_request(b, rc_prompt)
            recomputes.append(t_rc * 1000)
            rc_tokens.append(pt_rc)

            pu_prompt = gen_prefix(length, length * 1000 + rep + 500)
            one_request(a, pu_prompt)
            time.sleep(SETTLE_S)
            t_pu, pt_pu = one_request(b, pu_prompt, pull_from_ip=ip_a)
            pulls.append(t_pu * 1000)
            pu_tokens.append(pt_pu)

        rc_med = statistics.median(recomputes)
        pu_med = statistics.median(pulls)
        delta = (pu_med - rc_med) / rc_med * 100
        print(f"{length:>7} {rc_med:>13.1f} {pu_med:>9.1f} {delta:>6.0f}%  "
              f"(tokens rc~{statistics.median(rc_tokens):.0f} pull~{statistics.median(pu_tokens):.0f})",
              flush=True)


if __name__ == "__main__":
    main()
