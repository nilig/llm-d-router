"""Check whether the three-piece overlay (#48021-merged + #49877 + #49850,
no defect12 reimplementation) still exhibits the failure mode defect12's
diff targeted: a symmetric-P2P lookup whose LookupRespMsg is lost, leaving
the client-side probe stuck at None (RETRY) forever.

Drives the real ClientRole directly against the current overlay files
(no mocks of the class under test). Minimal sys.modules stubs stand in for
vllm.logger / vllm.v1.kv_offload.base / the protocol module so the actual
session_client.py loads and runs unmodified -- torch/vllm are not installed
in this environment.
"""
import sys
import types
import importlib.util
from pathlib import Path

OVERLAY = Path(__file__).parent / "combined_overlay_uc2resume"

# --- minimal stand-ins for vllm's import chain ---
vllm_logger = types.ModuleType("vllm.logger")
import logging
vllm_logger.init_logger = lambda name: logging.getLogger(name)
sys.modules["vllm"] = types.ModuleType("vllm")
sys.modules["vllm.logger"] = vllm_logger

vllm_v1 = types.ModuleType("vllm.v1")
vllm_v1_kv_offload = types.ModuleType("vllm.v1.kv_offload")
vllm_v1_kv_offload_base = types.ModuleType("vllm.v1.kv_offload.base")
from typing import NewType
vllm_v1_kv_offload_base.OffloadKey = NewType("OffloadKey", bytes)
sys.modules["vllm.v1"] = vllm_v1
sys.modules["vllm.v1.kv_offload"] = vllm_v1_kv_offload
sys.modules["vllm.v1.kv_offload.base"] = vllm_v1_kv_offload_base

for name in [
    "vllm.v1.kv_offload.tiering",
    "vllm.v1.kv_offload.tiering.base",
    "vllm.v1.kv_offload.tiering.p2p",
    "vllm.v1.kv_offload.tiering.p2p.session",
]:
    sys.modules[name] = types.ModuleType(name)


def load(modname, filename):
    spec = importlib.util.spec_from_file_location(modname, OVERLAY / filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)
    return mod


protocol = load("vllm.v1.kv_offload.tiering.p2p.session.protocol", "session_protocol.py")
client_mod = load("vllm.v1.kv_offload.tiering.p2p.session.client", "session_client.py")
ClientRole = client_mod.ClientRole


sent = []


def fake_send(msg):
    sent.append(msg)


def main():
    client = ClientRole(peer_id="peer:7777", send=fake_send)

    key = b"\xaa" * 8
    result = client.register_lookup("req-1", key)
    print(f"register_lookup -> {result} (expect None: in-flight)")
    client.flush_pending_lookups()
    print(f"after flush: sent={[m.get(protocol.TYPE_KEY) for m in sent]}")

    # Simulate the LookupRespMsg for this key being lost -- never call
    # on_lookup_resp(). The request is still being actively served (no
    # finish() yet), and the session has NOT been torn down.
    result = client.register_lookup("req-1", key)
    print(f"re-probe before any response -> {result} (expect None: still RETRY)")

    print(f"has_active_loads={client.has_active_loads} "
          f"(expect False: this request never issued a fetch)")

    # No natural recovery path fires here: no load timeout applies (no load
    # was ever armed for this request), and finish()/close() haven't run.
    # This is the state defect12 targeted with its own client-side expiry.
    stuck = client._requests["req-1"].probes.get(key, "MISSING")
    print(f"probe state with no disconnect, no finish: {stuck} "
          f"(expect None: stuck forever without close() or finish())")

    # Now simulate the session actually dying (the real recovery path:
    # ClientRole.close(), invoked when the transport detects the peer dead).
    close_result = client.close()
    print(f"close() -> failed_jobs={close_result.failed_jobs} "
          f"failed_req_ids={close_result.failed_req_ids}")

    if "req-1" in close_result.failed_req_ids:
        print("RESULT: session-close path recovers the stuck probe "
              "(matches P2PSecondaryTierManager._failed_req_ids handling).")
    else:
        print("RESULT: GAP -- close() did NOT report req-1 as failed; "
              "the stuck probe would never resolve.")


if __name__ == "__main__":
    main()
