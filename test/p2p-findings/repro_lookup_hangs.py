#!/usr/bin/env python3
"""In-process, deterministic repro of the two symmetric-P2P lookup hangs.

Drives the real ClientRole / ServerRole / P2PSession classes with in-memory
connections and stub transport/tiering - no GPU, no HTTP, no second process.
Run inside any environment with the p2p branch installed:

    python3 repro_inprocess.py            # asserts BUGGY behavior (unfixed)
    EXPECT=fixed python3 repro_inprocess.py   # asserts fix behavior

Scenario 1 (livelock seed, ClientRole only):
    a resolved MISS is consumed by pop-on-read; the very next probe of the
    same hash re-registers it as in-flight and re-queues a LookupMsg. Under
    fragmented responses this oscillation never converges (observed live:
    6,600-20,500 LookupMsgs for one request, ~85/s, until client timeout).

Scenario 2 (duplicate-fetch teardown, full P2PSession pair):
    a second FetchMsg for the same kv_request_id while the first is still
    open makes the server raise "duplicate fetch" and the session coordinator
    disconnects. A LookupMsg flushed during the dead window is silently
    dropped (_do_send). The consumer's lookup entry then stays in-flight
    forever: with no consumer-side deadline the request defers until the
    HTTP client gives up.
"""
import os
import time

EXPECT_FIXED = os.environ.get("EXPECT", "bug") == "fixed"

from vllm.v1.kv_offload.base import LookupResult, ReqContext  # noqa: E402
from vllm.v1.kv_offload.tiering.p2p.session import client as client_mod  # noqa: E402
from vllm.v1.kv_offload.tiering.p2p.session.client import ClientRole  # noqa: E402
from vllm.v1.kv_offload.tiering.p2p.session.session import P2PSession  # noqa: E402


def scenario1_livelock_seed():
    sent = []
    cl = ClientRole(peer_id="peer:7777", send=sent.append)
    h = b"\x01" * 16
    rid = "req-livelock"

    assert cl.register_lookup(rid, h) is None      # registers, in-flight
    cl.flush_pending_lookups()
    assert len(sent) == 1                          # LookupMsg on the wire
    cl.on_lookup_resp(rid, [h], [False])           # source answers MISS

    first = cl.register_lookup(rid, h)             # consume the MISS
    assert first is False
    second = cl.register_lookup(rid, h)            # probe again (next pass)
    cl.flush_pending_lookups()

    if EXPECT_FIXED:
        assert second is False, f"expected sticky MISS, got {second!r}"
        assert len(sent) == 1, "sticky MISS must not re-send a LookupMsg"
        print("scenario1: FIXED behavior confirmed (sticky MISS, no re-send)")
    else:
        assert second is None, f"expected re-registered in-flight, got {second!r}"
        assert len(sent) == 2, "pop-on-read re-queues a LookupMsg per pass"
        print("scenario1: BUG confirmed (MISS forgotten on read; "
              "re-registered + LookupMsg re-sent -> livelock seed)")


class MemConn:
    """In-memory ControlConnection pair endpoint."""

    def __init__(self, peer_id):
        self.peer_id = peer_id
        self.inbox = []
        self.peer = None
        self.alive = True

    def send(self, msg):
        if self.alive and self.peer is not None and self.peer.alive:
            self.peer.inbox.append(msg)

    def recv(self):
        out, self.inbox = self.inbox, []
        return out

    def mark_dead(self):
        self.alive = False

    def close(self):
        self.alive = False


class FakeTransport:
    """Just enough DataTransport surface for handshake + fetch serving."""

    base_addr = 0
    num_blocks = 4096
    block_len = 1 << 20
    config_fingerprint = "repro"

    def get_agent_metadata(self):
        return b"fake-agent-metadata"

    def add_remote_peer(self, *a, **kw):
        return None

    def remove_remote_peer(self, *a, **kw):
        return None

    _tid = 0

    def write_blocks(self, *a, **kw):
        # Return a transfer id but never complete it (poll always empty):
        # keeps the first fetch's outbound state open - the duplicate-fetch
        # window.
        FakeTransport._tid += 1
        return FakeTransport._tid

    def poll(self, *a, **kw):
        import types
        return types.SimpleNamespace(done=[], failed=[])

    def __getattr__(self, name):
        def _noop(*a, **kw):
            return None
        return _noop


class FakeParent:
    """Tiering-manager stand-in: every block is a servable HIT."""

    def __init__(self):
        self.finished = []

    def on_new_request(self, ctx):
        return None

    def lookup(self, key, ctx):
        return LookupResult.HIT

    _job_seq = 0

    def create_store_job(self, hashes, ctx):
        # JobMetadata with parallel keys/block_ids; the server feeds these
        # into add_stored_blocks to match against fetch demand.
        import types
        FakeParent._job_seq += 1
        return types.SimpleNamespace(job_id=FakeParent._job_seq,
                                     keys=list(hashes),
                                     block_ids=list(range(len(hashes))))

    def on_request_finished(self, ctx):
        self.finished.append(ctx.req_id)


def pump(a, b, parent_a, parent_b, n=6):
    for _ in range(n):
        a.poll()
        b.poll()
        a.serve_external_requests(parent_a)
        b.serve_external_requests(parent_b)
        a.flush_pending_lookups()
        b.flush_pending_lookups()


def scenario2_duplicate_fetch_teardown():
    conn_c, conn_p = MemConn("producer:7777"), MemConn("consumer:7777")
    conn_c.peer, conn_p.peer = conn_p, conn_c

    consumer = P2PSession(peer_id="producer:7777", local_id="consumer:7777",
                          transport=FakeTransport(), local_block_len=1 << 20,
                          conn=conn_c)
    producer = P2PSession(peer_id="consumer:7777", local_id="producer:7777",
                          transport=FakeTransport(), local_block_len=1 << 20,
                          conn=conn_p)
    pc, pp = FakeParent(), FakeParent()
    pump(consumer, producer, pc, pp)
    assert consumer._send_ready and producer._send_ready, "handshake failed"

    rid = "req-dupfetch"
    hashes = [bytes([i]) * 16 for i in range(8)]
    for h in hashes:
        consumer.register_lookup(rid, h)
    pump(consumer, producer, pc, pp)
    resolved = [consumer.register_lookup(rid, h) for h in hashes]
    assert all(r is True for r in resolved), f"lookups not HIT: {resolved}"

    # Two fetches for the same id (per-chunk pulls do exactly this); the
    # fake transport never completes transfers, so fetch #1 stays open.
    consumer.request_blocks(101, rid, hashes[:4], [0, 1, 2, 3])
    pump(consumer, producer, pc, pp, n=2)
    consumer.request_blocks(102, rid, hashes[4:], [4, 5, 6, 7])
    pump(consumer, producer, pc, pp, n=2)

    assert not conn_p.alive or not conn_c.alive, (
        "expected duplicate-fetch protocol error to disconnect the session")
    print("scenario2: duplicate fetch -> session disconnected (protocol "
          "error), as caught live")

    # A lookup for a DIFFERENT request flushed into the dead session is
    # silently dropped...
    rid2 = "req-collateral"
    h2 = b"\xaa" * 16
    assert consumer.register_lookup(rid2, h2) is None
    consumer.flush_pending_lookups()          # _do_send: conn dead -> dropped
    assert not conn_p.inbox and not producer._server._pending_inbound_lookups

    # ...and the consumer keeps reporting it in-flight. Unfixed: forever
    # (the deferred-forever hang). Fixed: resolves MISS once the consumer
    # deadline passes.
    deadline = getattr(client_mod, "_CONSUMER_LOOKUP_TIMEOUT_S", None)
    if EXPECT_FIXED:
        assert deadline is not None, "fix constant missing"
        client_mod_wait = min(deadline + 0.5, 10)
        time.sleep(client_mod_wait)
        res = consumer.register_lookup(rid2, h2)
        assert res is False, f"expected deadline MISS, got {res!r}"
        print("scenario2: FIXED behavior confirmed (dropped lookup expires "
              f"to MISS after {deadline}s -> request recomputes)")
    else:
        for _ in range(50):
            res = consumer.register_lookup(rid2, h2)
            assert res is None, f"expected in-flight forever, got {res!r}"
            time.sleep(0.02)
        print("scenario2: BUG confirmed (dropped lookup stays in-flight "
              "forever -> request deferred until client timeout)")


if __name__ == "__main__":
    scenario1_livelock_seed()
    scenario2_duplicate_fetch_teardown()
    print(f"ALL SCENARIOS PASSED (mode={'fixed' if EXPECT_FIXED else 'bug'})")
