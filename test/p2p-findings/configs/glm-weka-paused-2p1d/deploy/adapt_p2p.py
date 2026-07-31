#!/usr/bin/env python3
"""Adapt the blog's p2w1d1w2 manifests (pr1947) for the P2P campaign.

One engine deployment serves all three arms; the router config is the only
per-arm variable. Deltas over the verbatim blog manifests, applied to the
campaign copies in place:

1. Engine image pinned to the validated fixed-stack nightly (P2P-tier floor).
2. OFFLOADING_MODE case "p2p-tiered" on BOTH roles: CPU tier (100 GiB/rank)
   + P2P secondary tier at the compensated per-pod base
   (P2P_BASE = 7777 - START_RANK), offload_prompt_only false.
3. Per-rank KV events publisher at the compensated base
   (KV_EVENTS_BASE = 5557 - START_RANK) feeding the precise index.
4. PYTHONHASHSEED=0 and --block-size 64 fleet-wide (deterministic hashes;
   precise index block size must match the engine).
5. Decode sidecar image swapped to the endpoint-fix build.

Run once from this directory: python3 adapt_p2p.py
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).parent / "modelserver/gpu/vllm-glm-5.2/base"
ENGINE_IMAGE = "vllm/vllm-openai:nightly-6f91edf96d3f3272945809c04702380053bff4de"
SIDECAR_IMAGE = "quay.io/niliguy/llm-d-router-disagg-sidecar:kv-source-endpoint-92e5de82"

P2P_TIERED_CASE = """\
                  p2p-tiered)
                    P2P_BASE=$((7777 - START_RANK))
                    KV_TRANSFER_CONFIG='{"kv_connector":"MultiConnector",
                                          "kv_role":"kv_both",
                                          "kv_load_failure_policy":"fail",
                                          "kv_connector_extra_config":{
                                            "connectors":[
                                              {"kv_connector":"NixlConnector","kv_role":"kv_both"},
                                              {"kv_connector":"OffloadingConnector","kv_role":"kv_both",
                                               "kv_connector_extra_config":{
                                                 "spec_name":"TieringOffloadingSpec",
                                                 "cpu_bytes_to_use":'"${KV_OFFLOAD_CPU_BYTES:-107374182400}"',
                                                 "eviction_policy":"lru",
                                                 "offload_prompt_only":false,
                                                 "secondary_tiers":[{"type":"p2p","host":"'"${POD_IP}"'","port":'"${P2P_BASE}"'}]
                                            }}]}}'
                    ;;
"""

KV_EVENTS_SNIPPET = """\
                KV_EVENTS_BASE=$((5557 - START_RANK))
                KV_EVENTS_ARGS="--kv-events-config {\\"enable_kv_cache_events\\":true,\\"publisher\\":\\"zmq\\",\\"endpoint\\":\\"tcp://*:${KV_EVENTS_BASE}\\",\\"topic\\":\\"kv@${POD_IP}:8000@zai-org/GLM-5.2-FP8\\"}"
"""

POD_IP_ENV = """\
              - name: POD_IP
                valueFrom:
                  fieldRef:
                    fieldPath: status.podIP
              - name: PYTHONHASHSEED
                value: "0"
"""


def patch(path, subs):
    s = path.read_text()
    for old, new, must in subs:
        if must and old not in s:
            sys.exit(f"FATAL: pattern not found in {path.name}: {old[:80]!r}")
        s = s.replace(old, new)
    path.write_text(s)


for role in ("prefill", "decode"):
    p = BASE / f"{role}.yaml"
    s = p.read_text()
    if "p2p-tiered" in s:
        sys.exit(f"FATAL: {p.name} already adapted - re-export pristine bases from pr1947 first")

    subs = [("image: vllm/vllm-openai:nightly\n", f"image: {ENGINE_IMAGE}\n", True)]

    if role == "prefill":
        # insert the p2p-tiered case before the default *) case
        subs.append(("                  *)\n", P2P_TIERED_CASE + "                  *)\n", True))
        # the case block references START_RANK/POD_IP; START_RANK is set above it already
    else:
        # decode has no OFFLOADING_MODE switch: replace the inline NixlConnector
        # config with the same case structure prefill uses (p2p-tiered + default)
        old_cfg = """--kv_transfer_config '{"kv_connector":"NixlConnector",
                                          "kv_role":"kv_both",
                                          "kv_load_failure_policy":"fail"}' \\"""
        new_cfg = """--kv_transfer_config "$KV_TRANSFER_CONFIG" \\"""
        subs.append((old_cfg, new_cfg, True))
        case_block = (
            "                case \"${OFFLOADING_MODE:-off}\" in\n"
            + P2P_TIERED_CASE
            + "                  *)\n"
            + "                    KV_TRANSFER_CONFIG='{\"kv_connector\":\"NixlConnector\",\n"
            + "                                          \"kv_role\":\"kv_both\",\n"
            + "                                          \"kv_load_failure_policy\":\"fail\"}'\n"
            + "                    ;;\n"
            + "                esac\n\n"
        )
        subs.append(
            ("                PROFILER_ARGS=\"\"\n", case_block + "                PROFILER_ARGS=\"\"\n", True)
        )

    # KV events: define args after START_RANK is computed, pass to vllm serve
    subs.append(
        ("                START_RANK=$(( ${LWS_WORKER_INDEX:-0} * DP_SIZE_LOCAL ))\n",
         "                START_RANK=$(( ${LWS_WORKER_INDEX:-0} * DP_SIZE_LOCAL ))\n" + KV_EVENTS_SNIPPET,
         True)
    )
    subs.append(
        ("                  --data-parallel-start-rank $START_RANK \\\n",
         "                  --data-parallel-start-rank $START_RANK \\\n"
         "                  --block-size 64 \\\n"
         "                  $KV_EVENTS_ARGS \\\n",
         True)
    )
    # env additions on the vllm container (first env: block after the vllm container)
    subs.append(
        ("            env:\n              - name: HF_TOKEN\n",
         "            env:\n" + POD_IP_ENV + "              - name: HF_TOKEN\n",
         True)
    )
    if role == "decode":
        subs.append(("              sizeLimit: 256Gi\n", "              sizeLimit: 1500Gi\n", True))
        subs.append(("                memory: 512Gi\n", "                memory: 1500Gi\n", True))
        subs.append(("image: ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0",
                     f"image: {SIDECAR_IMAGE}", True))
        # sidecar P2P injection flags, mirroring the validated GLM cell
        subs.append(
            ("              - --kv-connector=nixlv2\n",
             "              - --kv-connector=nixlv2\n"
             "              - --enable-p2p-pull\n"
             "              - --p2p-connector-port=7777\n",
             True)
        )
        # decode base has no OFFLOADING_MODE env; add it active
        subs.append(
            ("              - name: PYTHONHASHSEED\n                value: \"0\"\n",
             "              - name: PYTHONHASHSEED\n                value: \"0\"\n"
             "              - name: OFFLOADING_MODE\n                value: \"p2p-tiered\"\n"
             "              - name: KV_OFFLOAD_CPU_BYTES\n                value: \"107374182400\"\n",
             True)
        )
    else:
        # prefill defaults OFFLOADING_MODE to "off"; activate the p2p tier
        subs.append(
            ("              - name: OFFLOADING_MODE\n                value: \"off\"\n",
             "              - name: OFFLOADING_MODE\n                value: \"p2p-tiered\"\n",
             True)
        )
        # DEP8 prefill is KV-tight at max-model-len 120000: single-node
        # default util 0.92 leaves ranks DP4/DP5 at 5.91-5.95 GiB against
        # the 6.12 GiB floor (crash logs archived in workload/). 0.925 adds
        # ~0.7 GiB per H200 - above the 0.21 GiB deficit - without touching
        # MAX_MODEL_LEN (workload admission) or MTP (P/D handoff parity).
        subs.append(
            ("              - name: PREFILL_GPU_MEM_UTIL\n                value: \"\"\n",
             "              - name: PREFILL_GPU_MEM_UTIL\n                value: \"0.925\"\n",
             True)
        )
        # At util 0.925 the DeepEP warmup allocation (6.05 GiB at batch
        # ceiling 8192) OOMs by 0.25 GiB. 7168 trims it ~12.5% (~0.76 GiB),
        # preserving 120k admission, MTP parity, and the NIXL cache layout;
        # applied to the shared engine deployment, so all arms see it
        # identically and B-vs-C stays causal. Campaign adaptation - this
        # remains a reconstruction, not a blog reproduction.
        subs.append(
            ("                  --max-num-batched-tokens 8192 \\\n",
             "                  --max-num-batched-tokens 7168 \\\n",
             True)
        )

    subs.append(
        ("""              - name: VLLM_NIXL_SIDE_CHANNEL_HOST
                valueFrom:
                  fieldRef:
                    fieldPath: status.podIP
""",
         """              - name: VLLM_NIXL_SIDE_CHANNEL_HOST
                valueFrom:
                  fieldRef:
                    fieldPath: status.podIP
              - name: VLLM_P2P_SIDE_CHANNEL_HOST
                valueFrom:
                  fieldRef:
                    fieldPath: status.podIP
""",
         True)
    )
    patch(p, subs)
    print(f"patched {p.name}")

print("done")
