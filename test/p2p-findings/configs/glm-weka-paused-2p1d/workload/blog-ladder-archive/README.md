# Blog benchmark ladder archive

Source: result tree shared by Elvir Crncevic (blog benchmark author),
received 2026-07-31. The tree maps to the blog's scatter points: four
groups (`142k + Baseline`, `142k + Offloading`, `142k + MTP +
Offloading`, `Full ISL + MTP + Offloading`), each holding per-topology
cells with per-concurrency rung directories, full aiperf artifacts,
engine logs, and the deployment yamls captured from the live namespace
at run time.

Contents here (summaries only; the full ~GB tree stays off-repo):

- `cli_commands.txt` - the exact `aiperf profile` invocation for every
  rung, extracted from each rung's `aiperf.log`. Across rungs of a cell
  only `--concurrency` and the artifact dir change; `--random-seed 42`
  and `--benchmark-duration 900` are fixed everywhere.
- `headline_metrics.csv` - req/s, TTFT p50/p99, ITL p50, per-user and
  aggregate token throughput for all 70 rungs.
- `mtp-offloading/` - per-cell metadata (`vllm_image.txt`,
  `vllm_version.txt`, `namespace.txt`, `pods.txt`, `epp-config.yaml`)
  and the full `profile_export_aiperf.json` per rung for the
  blog-comparable group (`142k + MTP + Offloading`).

What this establishes for the campaign:

- The ladder is c16/32/64/128 for the 142k groups (Full ISL adds
  c256/c512). Rungs are time-bounded (900 s), not request-counted.
- The runner invocation recovered from the c64 Job generalizes to the
  whole ladder: clone it and vary only `--concurrency`.
- The measured `epp-config.yaml` matches `epp/armA-blog-plugins.yaml`
  (prefill: GPU prefix w5 / CPU prefix w2 / active w1; decode: active
  w3) - arm A is the benchmarked policy verbatim.
- `p2w1d1w2` appears in no group: the campaign topology has no
  published ladder counterpart. The nearest measured 32-GPU cell is
  `p1w2d1w2` (one DP16 prefill engine instead of our two DP8 engines).
- The blog runs used `vllm/vllm-openai:nightly-dd72658e` (0.23.1rc1
  .dev1442); the campaign pins `nightly-6f91edf9` + the #50302 patch
  for the P2P tier. Engine-version deltas apply to all arms equally,
  so B-vs-C stays causal; absolute comparisons to these numbers carry
  the version caveat.
