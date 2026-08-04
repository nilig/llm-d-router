# Wide-fork twin runs: exact configuration

## Router (EPP)
- image: quay.io/niliguy/llm-d-router-endpoint-picker:kv-source-endpoint-92e5de82@sha256:5a019a80...
- flags: --config-file /config/<arm>.yaml --v=5
- arms: byte-identical copies of ecrncevi-dev configmaps
  wide-ep-lws-epp-token-precise      -> spill-off (baseline)
  wide-ep-lws-epp-token-precise-p2p  -> spill-on  (p2p)
  (only the render URL host differs by namespace; diff between arms = the five
   p2p-source-producer lines, minCachedTokenDelta: 12288)

## Engines
- vllm image: quay.io/niliguy/vllm-openai:nightly-6f91edf9-pr50302
- model zai-org/GLM-5.2-FP8, max-model-len 120000, block-size 64, fp8 KV, MTP on
- topology: 2 prefill pods (DP8 each, 16 ranks) + 2 decode pods (DP8 each)
- prefill: PREFILL_GPU_MEM_UTIL=0.935, max-num-batched-tokens 2048,
  OFFLOADING_MODE=p2p-tiered, KV_OFFLOAD_CPU_BYTES=21474836480 (20 GiB/rank)
- decode: MAX_TOKENS_PER_NODE=32, 100 GiB/rank tier,
  sidecar llm-d-router-disagg-sidecar:kv-source-endpoint-92e5de82 --enable-p2p-pull

## Workload
- corpus semianalysisai/cc-traces-weka-062126 (pinned)
- windows: trace 631738ac... group 0 (W=43, prefix 40,320 tok) and
  trace 21cde366... group 5 (W=44, prefix 40,640 tok); full recorded timing
- aiperf (agentx-v0 image):
  aiperf profile --model zai-org/GLM-5.2-FP8 --tokenizer same \
    --url http://<epp>:8081 --endpoint-type chat --streaming \
    --input-file <window>/trace.json --custom-dataset-type weka_trace \
    --fixed-schedule --extra-inputs ignore_eos:true \
    --use-server-token-count --no-gpu-telemetry
- protocol: EPP restarted before each arm (cold index); prefill pods restarted
  between run pairs (cold caches); TTFT coverage and fleet stability asserted
  per arm; pulls verified against engine counters, not the stream alone

## Arm YAMLs
```yaml
# spill-off.yaml (baseline)
apiVersion: llm-d.ai/v1alpha1
kind: EndpointPickerConfig
plugins:
- type: disagg-headers-handler
- type: always-disagg-pd-decider
- type: disagg-profile-handler
  parameters:
    deciderPluginName: always-disagg-pd-decider
- type: prefill-filter
- type: decode-filter
- type: token-producer
  parameters:
    modelName: zai-org/GLM-5.2-FP8
    vllm:
      url: http://glm-5-2-render:8000
- type: endpoint-notification-source
- type: precise-prefix-cache-producer
  parameters:
    indexerConfig:
      kvBlockIndexConfig:
        inMemoryConfig:
          podCacheSize: 128
    tokenProcessorConfig:
      blockSize: 64
    kvEventsConfig:
      topicFilter: "kv@"
      discoverPods: true
      podDiscoveryConfig:
        socketPort: 5557
- type: inflight-load-producer
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
- type: prefix-cache-affinity-filter
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
    inFlightLoadProducerName: inflight-load-producer
    peakPrefillThroughput: 3585
- type: token-load-scorer
- type: active-request-scorer
- type: max-score-picker
dataLayer:
  sources:
  - pluginRef: endpoint-notification-source
    extractors:
    - pluginRef: precise-prefix-cache-producer
schedulingProfiles:
- name: prefill
  plugins:
  - pluginRef: prefill-filter
  - pluginRef: prefix-cache-affinity-filter
  - pluginRef: token-load-scorer
  - pluginRef: max-score-picker
- name: decode
  plugins:
  - pluginRef: decode-filter
  - pluginRef: active-request-scorer
  - pluginRef: max-score-picker
```
```yaml
# spill-on.yaml = baseline + these five lines
- type: p2p-source-producer
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
    prefillProfileName: prefill
    minCachedTokenDelta: 12288
```
