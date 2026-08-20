import json, sys, copy, yaml

NIXL = '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_load_failure_policy":"recompute"}'
# Arm 2 prefill: single-tier CPU offload. NIXL still carries the P/D handoff;
# the OffloadingConnector is local retention only. No secondary_tiers.
MULTI = ('{"kv_connector":"MultiConnector","kv_role":"kv_both",'
         '"kv_load_failure_policy":"recompute",'
         '"kv_connector_extra_config":{"connectors":['
         '{"kv_connector":"NixlConnector","kv_role":"kv_both"},'
         '{"kv_connector":"OffloadingConnector","kv_role":"kv_both",'
         '"kv_connector_extra_config":{"cpu_bytes_to_use":107374182400,'
         '"block_size":128,"eviction_policy":"lru"}}]}}')
CLUSTER_ENV = [
    {"name": "VLLM_CACHE_ROOT", "value": "/.cache/vllm"},
    {"name": "NCCL_IB_HCA", "value": "ibp"},
    {"name": "NCCL_SOCKET_IFNAME", "value": "eth0"},
    {"name": "GLOO_SOCKET_IFNAME", "value": "eth0"},
    {"name": "POD_PORT", "value": "8000"},
]
LOADER = ["--load-format=runai_streamer", "--model-loader-extra-config",
          '{"distributed":true,"concurrency":16,"memory_limit":17179869184}']
PREFILL_NODE, DECODE_NODE = "g11bab6", "g1238bc"

def tiering(cpu_bytes, prompt_only):
    return ('{"kv_connector":"OffloadingConnector","kv_role":"kv_both",'
            '"kv_load_failure_policy":"recompute",'
            '"kv_connector_extra_config":{"spec_name":"TieringOffloadingSpec",'
            '"cpu_bytes_to_use":%d,"block_size":128,"eviction_policy":"lru",'
            '"offload_prompt_only":%s,'
            '"secondary_tiers":[{"type":"p2p","host":"$(POD_IP)","port":7777}]}}'
            % (cpu_bytes, "true" if prompt_only else "false"))


def set_arg(args, flag, value):
    for i, a in enumerate(args):
        if a == flag:
            args[i + 1] = value
            return
    raise SystemExit("flag not found: " + flag)

def add_env(c):
    have = {e["name"] for e in c.get("env", [])}
    for e in CLUSTER_ENV:
        if e["name"] not in have:
            c["env"].append(e)

def set_shm(spec, size):
    for v in spec["volumes"]:
        if v["name"] == "shm":
            v["emptyDir"]["sizeLimit"] = size

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
out = []
for d in docs:
    if d.get("kind") != "Deployment":
        out.append(d); continue
    name = d["metadata"]["name"]
    # GPU-exact placement leaves no room for RollingUpdate surge: the old and
    # new ReplicaSets would together want more GPUs than the node has, and the
    # rollout deadlocks. Recreate is required for arm switching too.
    d["spec"]["strategy"] = {"type": "Recreate"}
    spec = d["spec"]["template"]["spec"]
    c = spec["containers"][0]
    args = c["args"]
    arm = sys.argv[3] if len(sys.argv) > 3 else "1"
    is_prefill = name.endswith("-prefill")
    if arm == "2" and is_prefill:
        set_arg(args, "--kv-transfer-config", MULTI)
    elif arm == "3":
        # Prefill is the pull source, so it must not be prompt-only.
        set_arg(args, "--kv-transfer-config",
                tiering(107374182400, False) if is_prefill else tiering(107374182400, True))
    else:
        set_arg(args, "--kv-transfer-config", NIXL)
    # Sidecar v0.9.0 predates `offloading` support (added 2026-07-04, PR #1888)
    # and rejects it outright, so every arm runs v0.10.0-rc.1 to match the EPP.
    for ic in spec.get("initContainers", []):
        if "disagg-sidecar" in ic.get("image", ""):
            ic["image"] = "ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.10.0-rc.1"
    if arm == "3":
        c["env"].append({"name": "VLLM_P2P_SIDE_CHANNEL_HOST",
                         "valueFrom": {"fieldRef": {"fieldPath": "status.podIP"}}})
        for ic in spec.get("initContainers", []):
            ic["args"] = [("--kv-connector=offloading" if a.startswith("--kv-connector=") else a)
                          for a in ic.get("args", [])]
    for a in LOADER:
        if a not in args:
            args.append(a)
    add_env(c)
    if name.endswith("-prefill"):
        spec["nodeSelector"] = {"kubernetes.io/hostname": PREFILL_NODE}
        d["spec"]["replicas"] = 8
    else:
        spec["nodeSelector"] = {"kubernetes.io/hostname": DECODE_NODE}
        d["spec"]["replicas"] = 8
        set_arg(args, "--tensor-parallel-size", None) if False else None
        for i, a in enumerate(args):
            if a == "--tensor-parallel-size=4":
                args[i] = "--tensor-parallel-size=1"
        r = c["resources"]
        for side in ("limits", "requests"):
            r[side]["nvidia.com/gpu"] = "1"
        # A 100 GiB decode CPU tier needs the same headroom prefill gets.
        r["requests"]["memory"] = "160Gi"
        r["limits"]["memory"] = "220Gi"
        # 8 decoders x 16 CPU requests exceeds the node's 127.96 allocatable.
        # Match prefill: request 8, burst to 16.
        r["requests"]["cpu"] = "8"
        r["limits"]["cpu"] = "16"
        set_shm(spec, "120Gi")
    out.append(d)
yaml.safe_dump_all(out, open(sys.argv[2], "w"), default_flow_style=False, sort_keys=False)
print("wrote", sys.argv[2])
