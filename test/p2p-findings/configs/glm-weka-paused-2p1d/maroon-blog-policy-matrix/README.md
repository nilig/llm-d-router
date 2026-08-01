# GLM Weka blog-policy P2P matrix

First-sequence results are in [`RESULTS.md`](RESULTS.md).

This is the four-configuration comparison for the blog-provided
`p2w1d1w2` topology and the recovered Weka c64 workload.

| Configuration | Index | Placement | P2P |
|---|---|---|---|
| `01-blog-approximate-no-p2p.yaml` | Blog approximate GPU and CPU estimates | Blog weights | off |
| `02-blog-approximate-with-p2p.yaml` | Same | Identical | on |
| `03-blog-policy-precise-no-p2p.yaml` | KV-event precise | Blog-equivalent tier ratio | off |
| `04-blog-policy-precise-with-p2p.yaml` | Same | Identical | on |

The first file is byte-identical to PR #1947's custom EPP configuration.
The second file adds only `p2p-source-producer`, bound to the blog's CPU
approximate producer. This follows the existing approximate-P2P configuration
and makes estimate errors part of what the approximate treatment measures.

The precise files use one precise index with GPU weight 1.0 and CPU weight
0.4, then apply scheduler weight 5. This preserves the blog's GPU:CPU ratio of
5:2 and keeps active-request weight 1. The precise index takes the best tier
for a block; the blog's two approximate scores can add independent GPU and CPU
estimates. That index-semantics difference cannot be removed without running
two complete precise indexes and duplicating all KV-event subscriptions.

Within each index type, the P2P YAML differs from its control only by:

```yaml
- type: p2p-source-producer
  parameters:
    prefixMatchInfoProducerName: <that configuration's producer>
    prefillProfileName: prefill
    minCachedTokenDelta: 12288
```

All four configurations use the same engine deployment, Weka dataset, c64
concurrency, 900-second profiling window, and paired seed. The exact
deployment and workload requirements are in
`../maroon-precise-p2p-reproduction/README.md`.

Run the first sequence from the parent directory:

```bash
export NS=nilig-p2p
./install_epp_configmap.sh

SEED=42 ./run_arm.sh blog-approximate 64 matrix-s42-blog-approximate
SEED=42 ./run_arm.sh blog-approximate-p2p 64 matrix-s42-blog-approximate-p2p
SEED=42 ./run_arm.sh blog-precise 64 matrix-s42-blog-precise
SEED=42 ./run_arm.sh blog-precise-p2p 64 matrix-s42-blog-precise-p2p
```

For an order-balanced replication, run seed 43 in reverse order. Compare P2P
with no P2P within each index type first. The approximate-versus-precise
comparison measures index semantics and operational complexity, not P2P alone.
