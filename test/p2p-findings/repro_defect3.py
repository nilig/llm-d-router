"""Deterministic repro of lookup-hangs Defect 3: unbounded HIT_PENDING wait.

Drives the REAL TieringOffloadingManager.lookup() against a primary tier whose
block is permanently write-in-flight (returns HIT_PENDING). On stock main the
method returns HIT_PENDING on every call forever -> the scheduler re-polls in a
hot loop and the request defers until the HTTP client times out. With the
defect3 pending-wait deadline, it downgrades to MISS past 8s -> recompute.

No GPU, no HTTP, no second pod. Bypasses __init__ and sets only the three
attributes the HIT_PENDING path of lookup() touches.
"""
import time

from vllm.v1.kv_offload.base import LookupResult, ReqContext
from vllm.v1.kv_offload.tiering.manager import TieringOffloadingManager


class StuckPrimary:
    """Primary tier whose block never finishes its write (HIT_PENDING forever)."""

    def lookup(self, key, req_context):
        return LookupResult.HIT_PENDING


def make_mgr():
    m = object.__new__(TieringOffloadingManager)  # skip the real constructor
    m._req_state = {}
    m.primary_tier = StuckPrimary()
    m.secondary_tiers = []
    m._maybe_process_finished_jobs = lambda: None  # shadow the method
    return m


def main():
    m = make_mgr()
    ctx = ReqContext(req_id="req-defect3")
    key = b"\xde\xad\xbe\xef" * 8

    results = {m.lookup(key, ctx).name for _ in range(1000)}
    print(f"1000 rapid calls -> {results}")

    print("waiting 8.5s (past the 8s deadline the fix enforces)...")
    time.sleep(8.5)
    after = m.lookup(key, ctx).name
    print(f"after 8.5s -> {after}")

    if after == "HIT_PENDING":
        print("RESULT: DEFECT 3 REPRODUCED - block stuck HIT_PENDING with no "
              "downgrade; the request would hang until the client timeout.")
    elif after == "MISS":
        print("RESULT: FIXED - downgraded to MISS past the deadline; the "
              "request recomputes instead of hanging.")
    else:
        print(f"RESULT: unexpected terminal state {after}")


if __name__ == "__main__":
    main()
