"""Does PR #49877's finish() gap persist at head 15b53af1?

Same scenario as the repro run against the earlier head c1e15b9: a load is
in flight when the request finishes, and the peer's AbortAckMsg arrives
afterwards. The contract under test is that every job accepted by
request_blocks() produces exactly one terminal LoadResult, so the manager
can resolve its primary-tier write reservation.

Drives the real ClientRole from the overlay - no mocks of the class under
test. Minimal sys.modules stubs stand in for vllm.logger / base / tiering
base so the file loads without torch.
"""
import importlib.util
import logging
import sys
import types
from pathlib import Path
from typing import NewType

OVERLAY = Path(__file__).parent / "combined_overlay_49877new"

vl = types.ModuleType("vllm.logger"); vl.init_logger = lambda n: logging.getLogger(n)
sys.modules["vllm"] = types.ModuleType("vllm")
sys.modules["vllm.logger"] = vl
b = types.ModuleType("vllm.v1.kv_offload.base"); b.OffloadKey = NewType("OffloadKey", bytes)
for n in ["vllm.v1", "vllm.v1.kv_offload", "vllm.v1.kv_offload.tiering",
          "vllm.v1.kv_offload.tiering.base", "vllm.v1.kv_offload.tiering.p2p",
          "vllm.v1.kv_offload.tiering.p2p.session"]:
    sys.modules[n] = types.ModuleType(n)
sys.modules["vllm.v1.kv_offload.base"] = b


def load(mod, fn):
    spec = importlib.util.spec_from_file_location(mod, OVERLAY / fn)
    m = importlib.util.module_from_spec(spec)
    sys.modules[mod] = m
    spec.loader.exec_module(m)
    return m


proto = load("vllm.v1.kv_offload.tiering.p2p.session.protocol", "session_protocol.py")
cl = load("vllm.v1.kv_offload.tiering.p2p.session.client", "session_client.py")

sent = []
client = cl.ClientRole(peer_id="peer:7777", send=sent.append)

client.request_blocks(job_id=42, kv_request_id="req-1",
                      keys=[b"\xaa" * 8], block_ids=[0], send_ready=True)
print("after request_blocks: sent =", [m.get(proto.TYPE_KEY) for m in sent])

# the request finishes while that load is still in flight
client.finish("req-1")
print("after finish():        sent =", [m.get(proto.TYPE_KEY) for m in sent])

# the peer acknowledges the abort finish() just sent
abort = [m for m in sent if m.get(proto.TYPE_KEY) == proto.AbortFetchMsg.TYPE]
round_seq = abort[-1].get(proto.AbortFetchMsg.ROUND_SEQ, 0) if abort else 0
client.on_abort_ack("req-1", round_seq)

results = client.collect_results()
print("LoadResults:", results)
if len(results) == 1 and results[0].job_id == 42 and results[0].success is False:
    print("RESULT: FIXED at this head - exactly one failed LoadResult for job 42.")
else:
    print(f"RESULT: GAP PERSISTS - expected one failed LoadResult for job_id=42, "
          f"got {results}. Job 42 is orphaned: no terminal signal reaches "
          f"TieringOffloadingManager, so its primary write reservation is "
          f"never resolved.")
