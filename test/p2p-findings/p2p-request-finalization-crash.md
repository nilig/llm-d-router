# P2P findings — request-finalization crash (vLLM #49635)

A single long completion (~2,900 tokens, `offload_prompt_only:false`)
kills `EngineCore` roughly 35-60 seconds after the response finishes,
while the pod is otherwise idle: `KeyError` in
`tiering/manager.py:542 prepare_store`, reached via
`offloading/scheduler.py:1045 _build_store_jobs`. The crash is
process-wide: every in-flight request 500s via `EngineDeadError`, the pod
restarts. Reproduced twice on `nightly-4080263bb2c5d10deac17aaeb88e0823bc35bca9`
(the pin behind the guide's interim `generic_p2p` overlay) — once from a
single request, once under a 16-way concurrent burst.

## Root cause

`OffloadingConnectorScheduler.request_finished()` used to notify the
manager (`manager.on_request_finished()`) before the scheduler had
constructed the request's final store job. `TieringOffloadingManager`
would then delete `_req_state[req_id]` once `pending_primary_stores`
drained. On the next scheduler step, `_build_store_jobs()` called
`prepare_store()` for the same finished request, which indexed the
deleted state unguarded — `KeyError`, `EngineCore` dies.

Bisected to `vllm-project/vllm#46284` (commit `cf9fd645`, "Fix KV offload
request-finished lifecycle contract", merged 2026-06-24) — every line
involved blames to that single commit as an addition. It sat on `main`
unnoticed for a month because `generic_p2p` deployments up to this point
still shipped the branch's own `tiering/manager.py` in the overlay; only
once the tiering base merged upstream and dropped out of the branch's
changed-files list did main's (buggy) copy go live for the first time,
via the guide's interim overlay.

## Regression test evidence

Confirmed NOT a longstanding issue: 7+ prior configs in this findings set
ran `offload_prompt_only:false` on `nightly-2afa3f7e` / `nightly-6a9f24aa`
+ the old branch-carried `tiering/manager.py`, under 49K-token prompts at
concurrency 32-192, with zero `KeyError`s. The regression tracks the
tiering base's move from branch overlay to upstream main, not the P2P
mechanism itself.

## Fix and verification

Filed as `vllm-project/vllm#49635`. Two independently-authored fixes
landed within hours, both deferring `manager.on_request_finished()` until
after `_build_store_jobs()` has issued the request's final store:

- `vllm-project/vllm#49671` (Palaiologos1453) — initial version notified
  from four separate call sites in `_build_store_jobs`; adapted to a
  single post-pass over `finished_req_ids` after review from Or Ozeri.
- `orozery/vllm@fa07027d` — independently converged on the same
  single-post-pass shape, and additionally deletes the now-redundant
  `_maybe_cleanup_finished_req` call sites the post-pass supersedes.
  This is the variant `#49671` ultimately adopted (commit `ecf6bc52`).

Both verified on kermit against the original crash reproducer (same
config: `offload_prompt_only:false`, block size 64, P2P secondary tier,
`nightly-4080263b`, `generic_p2p` overlay at `145a460c`):

- **Cluster**: redeployed the guide stack (4-16 pods depending on the
  run) with the fix's `scheduler.py` overlaid via ConfigMap. The single
  ~2,900-token completion that previously killed the engine ~35-60s
  later: 0 restarts through a 100s observation window, twice, plus the
  rest of each session (~15+ min further bursts). The 16-way burst that
  previously returned 16x `EngineDeadError`: 16/16 ok. A 100-request
  burst: 100/100. Cross-pod pulls unaffected by the fix (seed 1.20s vs
  pull 0.19s in one check; external prefix-cache hits covering ~the full
  prefix).
- **Unit**: Or's variant's own test file, run against `nightly-4080263b`
  in a GPU pod — unpatched, exactly the file's 4 new/changed lifecycle
  tests fail; patched, 114/114 pass, including on this repo's older base
  (Or's `utils.py` harness adaptation resolves two base-sensitivity
  failures the PR-head variant left on this same nightly).

Approved by both maintainers as of 2026-07-24; not yet merged/in a
nightly as of this writing. The guide's interim overlay still needs the
fix layered on top of `generic_p2p` (ConfigMap `p2p-fix-or` in the
`nilig-p2p` deployments) until it lands upstream.

## Non-blocking hardening suggested, not yet acted on

`TieringOffloadingManager.prepare_store()` still has no defensive guard
against a missing `_req_state` entry — the ordering fix makes the crash
unreachable today, but nothing prevents a future ordering regression from
reintroducing it as a fleet-wide `EngineDeadError` instead of a logged
skipped offload. Suggested placement: after
`_maybe_process_finished_jobs()`, before `primary_tier.prepare_store()`
(checking after would leave primary-tier allocation without a matching
completion). Posted as a review comment on `#49671`; not filed as its
own issue.
