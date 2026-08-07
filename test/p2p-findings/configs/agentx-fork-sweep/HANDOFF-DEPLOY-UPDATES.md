# Deployment/config updates for review (render + tier weights)

Follow-up to HANDOFF-REVIEW.md. Two config changes rolled across every
surface we own, with validation evidence. Review asks at the bottom.

## Change 1: render served by the model servers

Following llm-d#2188 (merged upstream for the precise well-lit path), the
render (tokenizer) Service owns no pods: it fronts the vLLM model servers,
which expose `/v1/*/render` natively, so render capacity scales with the
serving fleet. The dedicated GPU-less pool remains as an opt-in overlay
under the same Service name.

Adaptation our P/D multi-port shape requires (differs from upstream):
- Upstream selects decode pods on their single serving port. Our decode
  pods' port 8000 belongs to the routing-proxy sidecar, which does not
  serve `/render` - so the precise guide selects **prefill** pods
  (port 8000 = vLLM rank 0), and the p2p guide targets the **vLLM port
  8200 directly** on its model pods.
- Known limitation to weigh: a Service has one targetPort, so on
  multi-port DP pods only rank 0's API server receives render calls -
  render capacity is (pods x 1 process), not (pods x ranks).

## Change 2: precise index tier weights

All precise-producer configs now set the device-tier scoring weights
explicitly, mirroring the approximate (prefix-aware) guide's gpu:cpu
prefix scorer weights of 5:2:

```yaml
indexerConfig:
  kvCacheBackendConfigs:
  - name: gpu
    weight: 1.0
  - name: cpu
    weight: 0.4
```

Library default is gpu 1.0 / cpu 0.8; the blog-precise config pair already
carried 1.0/0.4, which is where the ratio originates. Config parse
validated on live EPPs; a behavioral A/B (does routing prefer a
GPU-resident holder 5:2 over a CPU-only one) has not been run.

## Where the changes live

| surface | ref |
|---|---|
| precise routing guide | `nilig/llm-d` branch `guides/precise-kv-routing-wide-ep`, commits `84e826c8` (render), `a39e835c` (weights), `3b4521e5` (GIE prerequisite) |
| p2p guide (PR llm-d#2067 branch) | commit `9cc1d88c`: render overlays restructured (`render/` = model servers, `render/standalone/` = pool), 11 precise configs weighted |
| benchmark cell manifests + live ConfigMaps | `deploy/manifests` + `agentx-slo-arms` CMs: all precise keys weighted, render manifest replaced |

Compatibility findings folded into the guide: multi-port target pools need
GIE bundle >= v1.5.0-rc.2 (v1.0.x caps `targetPorts` at 1); `appProtocol`
is omitted from the pool manifest so it applies on both CRD generations.

## Validation evidence

- Guide deployed from-branch on two clean namespaces (piggy, then fozzie
  after installing LWS v0.9.0 + GIE v1.5.0-rc.2): wiring gates pass, all
  per-rank KV-event subscriptions connect (32/32 and 24/24), repeated
  6K-token prompt routes back to its holder (11.7K prefix-cache hit
  tokens, 0.71s warm vs 1.23s cold), `/v1/completions/render` returns
  token IDs directly from a prefill pod.
- Render mode A/B, ~6K-token prompts, 2-20 req/s: both modes flat ~500ms -
  below both ceilings, no separation.
- Render mode A/B, ~50K-token prompts (agentic scale), 5-45 req/s: the
  4-replica CPU pool collapses between 15 and 30 req/s (p50 10.4s, past
  the 5s render timeout - the production failure mode), while
  render-on-model-servers held p50 2.5s at 45 req/s. Caveat: arm A's
  15/30 rungs carry queue drain from an aborted earlier run (its heaviest
  rung was its cleanest, which queues cannot do); the per-arm heaviest
  rungs are clean and decide the comparison.

## Review asks

1. The prefill-vs-decode selector adaptation and the p2p guide's
   `targetPort: 8200` - is fronting rank-0 API servers acceptable, or
   should the guides call out the rank-0-only capacity bound more
   prominently (or prefer the standalone pool for multi-port DP)?
2. The 1.0/0.4 weight ratio - agree with mirroring the approximate
   guide's 5:2, or should precise keep the library default 0.8 until a
   behavioral A/B justifies the change?
3. Anything in the GIE version handling (omitting appProtocol vs pinning
   the newer bundle) you would do differently for a public guide.
