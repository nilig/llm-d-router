# WVA installation and benchmark log

## Scope

- Cluster context: `kermit_US-EAST-01A`
- Namespace: `nilig-wva-benchmark`
- Initial workload: optimized-baseline `Qwen/Qwen3-32B`, vLLM, TP=2, two static replicas
- Purpose: establish the two-replica saturation point before installing WVA
- WVA source: `ev-shindin/llm-scaler`, branch `feat/wva-external-scaler`, commit `ff81a30866cc2148da21c4cb5ca8723f074b0f55`

### Waldorf continuation

- Cluster context: `waldorf_US-EAST-04A`
- Namespace: `nilig-wva-benchmark`
- KEDA: existing shared installation, version `2.18.1`
- Prometheus: `https://prometheus-operated.llm-d-nightly-wva-monitoring.svc.cluster.local:9090`
- WVA image: `ghcr.io/ev-shindin/llm-scaler:main`, resolved digest `sha256:456aebd2d54f2debf4e001f8abe6d72240b0556a8d5739097ba21e7b92a3afcd`
- ScaledObject bounds: two to six replicas, two H200 GPUs per replica

## Observations and issues

### The guide has no safe cluster-context parameter and the Makefile overrides `PATH`

- The installer invokes `kubectl` without a context parameter and relies on the global kubeconfig current context.
- A temporary `kubectl` wrapper pinned to Waldorf was placed first on `PATH`, but the Makefile prepends `/opt/homebrew/bin`, silently bypassing the wrapper.
- As a result, the first Waldorf preflight and prerequisite retries actually ran against the globally current Kermit context. They reapplied Kermit's existing partial prerequisites and installed no controller or KEDA.
- A temporary kubeconfig whose current context is Waldorf was required to run the guide safely without changing the user's global context.
- Impact: an operator working across clusters can get a successful-looking preflight for the wrong cluster and mutate it. The guide should accept a context/kubeconfig parameter, print the current context prominently, and avoid overriding caller `PATH` order.

### Waldorf requires a provider-specific H200 selector that WVA cannot resolve

- Kermit's NVIDIA nodes use `nvidia.com/gpu.product=NVIDIA-H200`; Waldorf uses `gpu.nvidia.com/model=H200`.
- Applying the Kermit benchmark overlay unchanged would leave pods pending, so a Waldorf-specific scheduling overlay was required.
- WVA recognizes `nvidia.com/gpu.product` and `cloud.google.com/gke-accelerator`, but not CoreWeave's `gpu.nvidia.com/model` key.
- The controller therefore reports four unattributed GPUs and emits `AcceleratorNotResolved`, even though all model pods run on H200 nodes.
- Replica scaling works with the shipped no-limiter configuration. Enabling `gpu-inventory` would make this unresolved accelerator block scale-up.
- Impact: GPU-aware limiting and accelerator-keyed metrics are not usable on this CoreWeave label shape without adding the provider label alias in WVA.

### Prometheus discovery is inconsistent between preflight, setup and final verification

- Waldorf preflight correctly discovered `https://prometheus-operated.llm-d-nightly-wva-monitoring.svc.cluster.local:9090` and said no override was needed.
- `setup-prereqs` then announced that WVA would scrape `https://kube-prometheus-stack-prometheus.workload-variant-autoscaler-monitoring.svc.cluster.local:9090`; that namespace does not exist.
- The controller was installed with an explicit `PROMETHEUS_URL` override and validated the correct API successfully with an `up` query.
- Final verification nevertheless warned `Prometheus is not ready`, while the final summary claimed Prometheus was deployed in the nonexistent default namespace.
- Impact: the same run presents three conflicting states. The controller works only because the preflight-verified URL was passed explicitly.

### The controller's startup probes can restart a healthy-starting process

- The new controller initialized Prometheus and its managers successfully, but its one-second liveness/readiness timeouts fired during startup.
- Kubernetes restarted it once. The installer's first 60-second rollout wait timed out and warned that the controller was not ready; the following verification wait found it Ready and returned success.
- Impact: installation is noisy and adds a restart even on a healthy deployment. The probes need a startup probe or a less aggressive timeout.

### The default WVA image is a floating `main` tag

- The source under test is pinned to commit `ff81a30866cc2148da21c4cb5ca8723f074b0f55`, but the guide installed `ghcr.io/ev-shindin/llm-scaler:main` by default.
- The live image resolved to digest `sha256:456aebd2d54f2debf4e001f8abe6d72240b0556a8d5739097ba21e7b92a3afcd`.
- Impact: checking out the same source commit later does not reproduce the same controller unless the image digest is also recorded or explicitly supplied.

### KEDA 2.18.1 accepts the WVA external scaler

- The branch installer pins KEDA chart `2.19.0`, while Waldorf provides `2.18.1`.
- The generated ScaledObject became `Ready=True` and `Active=True`; KEDA created an HPA with a live external metric and the requested two-to-six replica bounds.
- Impact: no compatibility issue has appeared in the external-push path so far. This validates basic actuation, not every KEDA feature or scale-to-zero.

### The smoke-test description and implementation do not match

- The namespace guide describes decode-heavy load at 10 requests/s for five minutes.
- The script defaults to symmetric traffic at 15 requests/s, with approximately 1,024 prompt and 1,024 output tokens.
- The script dispatched 4,117 requests instead of the nominal 4,500 for 15 requests/s over 300 seconds.
- It reports only dispatched requests. It does not count successful responses or HTTP errors, and `curl` is not passed `--fail`, although the result text tells the operator to confirm that error count is zero.
- Impact: the smoke test proves replica actuation, but cannot prove request correctness or provide a reliable achieved request rate.

### Waldorf smoke actuation is correct but dominated by model cold start

- Load began at approximately `08:54:13Z`.
- WVA first chose `2 -> 3` at `08:55:08Z`, about 55 seconds after load began, at utilization `0.967` against the `0.85` scale-up threshold.
- KEDA created the third pod at `08:55:20Z`, about 12 seconds after the WVA decision.
- The third Qwen3-32B TP=2 pod became Ready at `08:57:51Z`, 151 seconds after creation and 163 seconds after the WVA decision.
- With only two Ready replicas, utilization reached approximately `1.14`. With three Ready replicas it settled around `0.65` to `0.81`, and WVA correctly held at three.
- WVA began recommending `3 -> 2` at `09:00:08Z` after load and in-flight work drained. KEDA scaled down at `09:05:05Z`, 297 seconds later, matching the 300-second HPA stabilization window.
- Impact: the control decision and KEDA actuation are fast compared with the 2.5-minute model startup. Without warm capacity or Fast Model Actuation, most of a five-minute burst is served at the saturated pre-scale capacity.

### The restricted execution environment blocked Kubernetes DNS access

- After the Waldorf smoke test completed, Kubernetes reads made inside the restricted execution environment failed to resolve the API hostname. The environment exposed no macOS DNS configuration and blocked the Go resolver's UDP request to `192.168.68.1:53`.
- Running the same read-only `kubectl` request on the host network resolved the Waldorf endpoint and returned Kubernetes `v1.35.7` successfully.
- Impact: this was a benchmark-operator environment issue, not a Waldorf, CoreWeave DNS, WVA, or KEDA failure. Subsequent Kubernetes operations for this test must use host-network execution.

### Waldorf had no deployable TP2 capacity at the staged-run checkpoint

- Immediately before the staged benchmark, Waldorf had one free H200 in aggregate and zero nodes with the two free H200s required by one additional TP2 replica.
- Two pods in the exact `cw-hpc-verification` namespace held one full H200 node each: `hpc-verification-nhc-v3-gd91fda-xjbhl` on `gd91fda` and `hpc-verification-nhc-v3-gf49e9c-xyajb` on `gf49e9c`, eight GPUs per pod.
- A separate two-GPU pod was Pending in `default`. No verification workload was evicted.
- Impact: the two existing replicas remain healthy, but a scale-up test cannot measure autoscaler actuation until at least one whole TP2 placement is available. This is a point-in-time capacity constraint, not an autoscaler failure.
- Resolution: the short-lived verification pods rotated and a nightly workload released capacity before launch. The final scan found 17 free H200s and three nodes with at least two free GPUs. The two-to-six-replica benchmark fit without deleting any verification pod.

### The staged concurrency ramp validates actuation but exposes unsafe scale-down

- WVA and KEDA scaled the standard TP Deployment from two to six replicas and returned it to two.
- WVA first recommended six to five at `11:37:12Z`; HPA applied it at `11:42:12Z`, exactly matching the configured 300-second scale-down stabilization.
- The live Deployment uses the default `terminationGracePeriodSeconds: 30` and has no `preStop` drain hook.
- Stage 4 recorded 39 `ClientPayloadError` failures. The failures form four groups aligned with the four pod removals, and each group ended approximately 25 to 30 seconds after its corresponding reduction.
- Impact: supported replica actuation works, but long streaming responses are truncated during scale-down unless the serving deployment removes the endpoint and drains in-flight requests before process termination.

### Large result collection can invalidate a successful workload run

- All five load stages completed in 24 minutes 24 seconds and report generation completed successfully after another 6.5 minutes.
- The harness result directory was 5.1 GiB, dominated by a 4.8 GiB per-request lifecycle file that embeds complete prompts and streaming responses.
- The runner used a single `kubectl cp` stream for about 8.2 minutes. It failed near completion with `websocket: close 1006 (abnormal closure): unexpected EOF`, marked the treatment failed, and deleted the harness pod during cleanup.
- Compact per-stage reports, telemetry and plots were copied successfully. The local per-request file contains 7,115 of 7,392 request objects and ends mid-response.
- Impact: the benchmark result status reports failure even though the workload and report generation completed. Summary artifacts should be copied first, raw payload collection should be optional, and a failed transfer should be resumable before cleanup.

### Run-only monitoring cannot populate replica lifecycle reports

- Prometheus captured the EPP Ready-replica series correctly, including the two-to-six-to-two transition.
- The benchmark's Kubernetes controller discovery used generated-stack labels, found no controllers, and produced empty `replica_status` and `pod_startup_times` reports.
- Result collection also reported no model-serving or EPP pods even though both were healthy.
- Impact: time-series graphs exist, but startup and replica lifecycle summaries are unusable for an independently deployed optimized-baseline stack. The runner needs explicit workload/EPP selectors or discovery from the supplied endpoint and scale target.

### The controlled benchmark confirms benefit but not cost efficiency

- The same 7,392-request concurrency ramp was run with fixed two replicas, WVA two to six, and fixed six warm replicas.
- WVA completed the load in 24m 23s, versus 36m 02s for fixed two and 16m 36s for fixed six.
- Relative to fixed two, WVA increased output-token throughput by 54.6% and reduced median TTFT by 90.8%.
- Fixed two had 17 EPP queue-TTL failures at concurrency 384. WVA avoided saturation failures, but its four scale-down removals truncated 39 streams. Fixed six had zero failures.
- During the load window, fixed two used approximately 144 GPU-minutes, WVA 252, and fixed six 199. WVA produced fewer successful output tokens per GPU-minute than either fixed control.
- Impact: supported actuation and a clear saturation benefit are validated. Cold start, the 300-second downscale window, and unsafe stream termination prevent the tested policy from improving both performance and resource efficiency.

### Model startup can hang without a Kubernetes failure signal

- Pinning the control to six replicas scheduled four new TP2 pods immediately.
- Three became Ready, while one remained Running with zero restarts at `Loading model from scratch...` for more than 10 minutes.
- Its image was already present, port 8000 never opened, and the startup probe accumulated 21 connection-refused failures. Recycling only that benchmark pod produced a Ready replacement.
- Impact: the Deployment and autoscaler see allocated Running capacity before it is usable. Startup variance needs to be part of scale-out testing, and a 60-minute startup-probe budget can leave expensive stuck capacity undetected for too long.

### Compact reports and streamed collection avoid the bulk-copy failure

- The fixed controls set `report.request_lifecycle.per_request: false` and used `--fast-collect`.
- Collected results were 55 MiB and 46 MiB, versus 4.9 GiB locally for the truncated autoscaled copy.
- Each control transferred more than 450 files in about three seconds and the runner exited successfully.
- Report generation still took approximately six minutes and provided no intermediate progress output.
- Impact: compact output plus compressed streaming is an effective workaround for result collection. Report aggregation remains a significant post-load cost and is difficult to distinguish from a hang from runner output alone.

### WVA preflight cannot discover the optimized-baseline Deployment

- The live Deployment and pod template both carry `llm-d.ai/role=decode`, one of the guide's documented discovery markers.
- `NAMESPACE=nilig-wva-benchmark make check-prereqs` nevertheless reports that the namespace has no llm-d model servers and exits 2.
- Reproducing its jq predicate directly returns `string and boolean cannot be added`.
- Cause: six jq predicates construct `.key + "=" + (.value|tostring) as $kv` without parenthesizing the string before the `as` binding.
- Impact: the unmodified guide cannot pass preflight or reliably discover the optimized-baseline workload it explicitly describes as supported.
- Workaround for this test: apply a local, uncommitted installer-script patch changing each expression to `(.key + "=" + (.value|tostring)) as $kv`. The controller image is unchanged.

### EPP Helm upgrade does not restart the pod after plugin configuration changes

- Helm revision 2 updated the optimized-baseline EPP ConfigMap with flow control, but the Deployment pod template has no configuration checksum annotation.
- The original EPP pod remained running and exported no flow-control metrics until `kubectl rollout restart deployment/optimized-baseline-epp` was run explicitly.
- Impact: the guide prerequisite remains unsatisfied after a successful Helm upgrade unless the operator knows to restart EPP manually.

### The documented prerequisite command does not install missing KEDA by default

- The guide states that KEDA is installed when the cluster has none and instructs `NAMESPACE=... make setup-prereqs` with no additional variable.
- On Kubernetes, the implementation defaults `KEDA_HELM_INSTALL=false`, skips Helm, and expects cluster-managed KEDA.
- The command applied WVA namespace and cluster RBAC, token Secret, and ServiceMonitor, then exited 2 because KEDA is absent.
- The failed `kubectl get crd scaledobjects.keda.sh` command substitution exits under `set -e` before the script reports its intended explanatory error.
- Impact: the documented command leaves a partial prerequisite installation and no actionable final error. The required retry is `KEDA_HELM_INSTALL=true make setup-prereqs`, but that variable is not listed in the namespace guide's configuration table.

### Prometheus auto-detection reports inconsistent endpoints across phases

- `make check-prereqs` correctly resolved `https://prometheus-operated.llm-d-monitoring.svc.cluster.local:9090` and said no override was needed.
- `make setup-prereqs` detected the same existing monitoring release but then said WVA would scrape `https://kube-prometheus-stack-prometheus.workload-variant-autoscaler-monitoring.svc.cluster.local:9090`, whose namespace does not exist.
- Impact: following the no-override advice risks a healthy controller configured against a nonexistent Prometheus endpoint. This test passes the preflight-verified URL explicitly on installation.

### Autoscaling ceiling is constrained by point-in-time capacity

- The pre-install scan found 11 free H200 GPUs across three partially occupied nodes, with no pending GPU requests.
- The two-replica baseline already consumes four H200 GPUs. Six total replicas require eight additional GPUs and fit the current free capacity; eight replicas do not fit without reclaiming verification capacity.
- Impact: this test caps the workload at six replicas and does not evict any `cw-hpc-verification` pod.

### Capacity changed materially between planning and execution

- Planning scan: 63 free H200 GPUs and six completely free eight-GPU nodes.
- Pre-launch scan: 13 free H200 GPUs across three partially occupied nodes.
- Another 48 H200 GPUs are occupied by workloads in the exact `cw-hpc-verification` namespace and are reclaimable, but they have not been evicted.
- There are no pending GPU requests.
- Impact: the four-GPU static calibration remains deployable. The later 16-GPU autoscaling range must be rechecked immediately before launch and may require explicit verification-workload eviction approval.

### Fresh namespace does not contain the required model credential

- `llm-d-hf-token` was absent from the new namespace.
- Reused the standard secret from the user's existing `nilig-p2p` namespace without printing its data.
- Impact: expected for a fresh namespace, but it is an extra cross-namespace setup step not performed by the optimized-baseline guide.

### KEDA is not installed on Kermit

- The router, InferencePool, HTTPRoute and ServiceMonitor CRDs are installed.
- `scaledobjects.keda.sh` is absent.
- Impact: none for the static saturation calibration. The WVA cluster-admin prerequisite step must install KEDA before the autoscaling treatment.

### The optimized-baseline manifest needs a benchmark-specific capacity patch

- The guide defaults to eight replicas, TP=2 and 16 GPUs total.
- It does not constrain the NVIDIA GPU product.
- A benchmark-only overlay changes the initial replica count to two and adds `nvidia.com/gpu.product: NVIDIA-H200`.
- Impact: applying the guide verbatim would have exceeded currently free non-verification capacity and would not have guaranteed H200 placement.

### Existing benchmark checkout is not reproducible for this run

- `/Users/niliguy/github.com/llm-d-benchmark` is a dirty checkout on `feat/p2p-guide-profile` with CLI version `0.7.0`.
- It was left untouched.
- An isolated v0.7.8 checkout at commit `00e1516e76cfe3872044188df38a31c63f7cff9a` is used as the benchmark source.

### The v0.7.8 benchmark source defaults to a v0.7.0 harness image

- `config/templates/values/defaults.yaml` in the v0.7.8 checkout pins `images.benchmark.tag` to `v0.7.0`.
- Impact: running the v0.7.8 host-side source without an override can mix release versions between the local runner and the in-cluster harness.
- Mitigation for this run: pass `--set images.benchmark.tag=v0.7.8` explicitly and verify the harness pod image before load begins.

### The documented `--set` positioning is easy to misapply

- Placing `--set images.benchmark.tag=v0.7.8` with the other global options caused argparse to consume it as an abbreviation of `--specification_file`, then reject the value as a command.
- The invocation succeeds only when `--set` is placed after the `run` subcommand, despite README text describing it as a global option.
- Impact: the first dry-run attempt failed before rendering. The parser's abbreviation behavior obscures the actual ordering error.

### `--dry-run` still performs external validation

- The dry run rendered all 39 templates successfully and confirmed the harness image override.
- It then invoked `helmfile`, attempted to add an external Helm repository, and checked Kubernetes API reachability.
- On the Waldorf render it logged a failed `helmfile template` command, then continued and printed `Run complete` with no failure status. It also retried a data-access pod lookup five times even though dry-run mode intentionally created no pod.
- Impact: `--dry-run` is not an offline render-only operation, and command failures are reported inconsistently. A caller can receive a successful exit after a logged rendering error, while a network-restricted run can fail after already producing a usable plan.

### Release identification remains `0.7.0` in the v0.7.8 checkout

- The pinned v0.7.8 checkout reports `Using Package: "llmdbenchmark:0.7.0"`.
- Impact: logs alone do not make it clear which tagged source is running; the exact Git commit must be recorded separately.

### Run-only setup performs unrelated artifact resolution

- Before launching the harness, `run` resolved the latest WVA image and the llm-d infrastructure and modelservice chart versions.
- Impact: a load-only operation depends on unrelated registries and Helm repositories, adding latency and additional external failure modes.

### Kermit is reported as an unrecognized platform

- Resource auto-detection correctly found NVIDIA H200 GPUs and RDMA, but platform detection matched none of the predefined cluster types.
- The harness receives `LLMDBENCH_CLUSTER_TYPE=unrecognized`.
- Impact: no failure in this run, but any platform-specific defaults or diagnostics are unavailable.

### The harness does not reuse the existing Hugging Face token secret

- The runner reported no Hugging Face token and did not mount `llm-d-hf-token` into the benchmark harness.
- The harness fetched Qwen tokenizer metadata unauthenticated and emitted a Hub rate-limit warning.
- Impact: public models work, but repeated runs add network dependency and can hit anonymous rate limits even when the namespace already has the expected model secret.

### The published warm-up overloads the two-replica calibration stack

- The guide profile begins with 15 requests/s for 50 seconds before the measured 3-to-60 requests/s ladder.
- During that warm-up Prometheus reported 407 running requests, 343 waiting requests, 750 EPP requests in flight, and aggregate KV-cache utilization of 1.999 across two replicas, effectively 100% on both.
- Impact: the baseline is saturated before the measured ladder begins. This profile is sized for the guide's eight-replica deployment and is inefficient as-is for a two-replica saturation search.

### The full guide ladder cannot complete within the selected runner timeout

- Observed stage wall times were 217 seconds for warm-up, 34 seconds at 3 requests/s, 56 seconds at 10 requests/s, 69 seconds at 15 requests/s, and 175 seconds at 20 requests/s.
- Later guide stages submit approximately 1,500 requests each with 1,000 output tokens, while the run was configured with a 1,800-second harness wait timeout.
- Impact: the guide-as-written run on two replicas would exceed the orchestration timeout and consume GPU time without yielding a complete report.
- The guide run was intentionally stopped after the 20 requests/s stage. A bounded profile retains the same traffic shape and narrows the rate ladder to 2, 3, 4, 5, 6, 8, and 10 requests/s.

### Interrupting the runner does not clean up cleanly

- Sending Ctrl-C while the runner waited for the harness produced a full Python `KeyboardInterrupt` traceback and left the harness pod running.
- The exact pod `inference-perf-7b00bhw7` had to be deleted explicitly to prevent it from starting the next stage.
- Impact: interruption is noisy and can leave active load behind unless the operator performs manual Kubernetes cleanup.

### Run-only result capture misses the deployed model and EPP logs

- Result collection searched for model and EPP labels derived from the generated benchmark stack name `qwen-qwe-fb93eeef-wen3-32b`.
- The existing guide deployment uses `optimized-baseline` labels, so the runner reported no model-serving or EPP pods and wrote empty component log files.
- Impact: `--monitoring` captures time-series metrics but not the server and router logs needed to correlate errors in a run-only benchmark against an independently deployed stack.

### Report conversion assumes standup artifacts and broader RBAC

- For every stage, in-pod conversion tried to read the absent `llm-d-benchmark-standup-parameters` ConfigMap and `/standup/ev.yaml`.
- It also tried to list cluster nodes using `system:serviceaccount:nilig-wva-benchmark:inference-perf-runner`, which correctly received a 403 from its namespace-scoped Role.
- Impact: conversion still succeeds, but repeats a large error block per stage and cannot populate accelerator metadata in run-only mode.

### `--analyze` completes only partially in the reused local environment

- The runner reported that the `inference-perf` CLI was not on `PATH` and skipped its analysis command.
- Matplotlib was unavailable, so per-request and session plots were skipped.
- Impact: lifecycle JSON, benchmark-report YAML, and embedded telemetry are complete, but requesting `--analyze` does not guarantee plots or all analyzer outputs unless additional local dependencies are installed.

### The console output-length aggregate is misleading

- The harness was configured with `output_len: 1000`, `ignore_eos: true`, and the authoritative `output_tokens` aggregate reports exactly 1,000 tokens for every request.
- The console's separate `Output Mean` column reports values above 1,000 and maxima of 8,200 in some stage JSON fields.
- Impact: readers can incorrectly conclude that the generator violated the requested output length. The report should label the metric source or use `output_tokens` consistently.

### Post-run cleanup retains benchmark infrastructure

- The runner deletes the harness pod and transient profile and script ConfigMaps.
- It retains the bound 20 Gi `workload-pvc`, the continuously running `access-to-harness-data-workload-pvc` pod, `llm-d-benchmark-harness` Service, preprocessing and run-parameter ConfigMaps, and the `inference-perf-runner` ServiceAccount, Role, and RoleBinding.
- Impact: repeat runs start faster and results remain accessible, but the cleanup message does not describe the persistent namespace footprint. Operators need an explicit teardown path when the benchmark is finished.

### Prometheus service requires HTTPS

- The initial direct validation request used HTTP and received `Client sent an HTTP request to an HTTPS server`.
- Retrying the same query over HTTPS succeeded.
- Impact: this is not a deployment failure, but tooling or documentation that assumes a plain HTTP Prometheus service will fail against Kermit's monitoring installation.

### vLLM logs warnings for build metadata environment variables

- vLLM `v0.23.0` reports `VLLM_BUILD_COMMIT`, `VLLM_BUILD_PIPELINE`, `VLLM_BUILD_URL`, and `VLLM_IMAGE_TAG` as unrecognized `VLLM_*` environment variables.
- Impact: startup and serving are unaffected; the warnings add noise and can look like configuration errors during installation review.

## Timeline

- Started with a read-only Kermit capacity scan before namespace creation.
- Verified that `nilig-wva-benchmark` did not already exist and that the current identity can create namespaces.
- Created namespace `nilig-wva-benchmark`; it became Active immediately.
- Compared `nilig-p2p` and `nilig-agentx-slo` metadata. Neither carries a custom ownership label, so none was invented for the new namespace.
- Copied `llm-d-hf-token` from `nilig-p2p` into the new namespace without exposing its contents.
- Installed standalone router chart `v0.9.0`, digest `sha256:8150c84045d59e6e91991daf810322140e116d5e02d244d96cbfc2b3000825cd`, with EPP monitoring enabled. Helm completed in about 17 seconds.
- Deployed two vLLM `v0.23.0` Qwen3-32B replicas with TP=2 and two H200 requests each, plus the model-server PodMonitor.
- Both model pods scheduled immediately on different H200 nodes. The image was already cached.
- One transient EPP readiness timeout appeared during initial startup; EPP became healthy without intervention.
- Both model replicas became Ready, and `/v1/models` through the EPP returned `Qwen/Qwen3-32B`.
- Prometheus reports `up=1` for the EPP and both model-server targets in `nilig-wva-benchmark`.
- The benchmark dry run rendered 39 of 39 templates and confirmed `ghcr.io/llm-d/llm-d-benchmark:v0.7.8` in the harness pod manifest.
- The real harness pod pulled the confirmed v0.7.8 image, verified the model through EPP, and started the published workload.
- The guide run completed warm-up and the 3, 10, 15, and 20 requests/s stages before being stopped during an idle interval.
- The bounded profile completed successfully: 1,770 of 1,770 requests succeeded, 190 result files were collected, and the runner cleaned up the harness pod and ConfigMaps.
- After the run, both model replicas remained Ready and the EPP remained healthy.
- On Waldorf, the smoke load scaled two to three to two; the third replica took approximately 2.5 minutes to become Ready.
- The staged concurrency ramp submitted 7,392 requests across concurrency 32, 64, 256, 384 and 64. It reached six replicas and returned to two.
- The staged reports recorded 7,353 successes and 39 scale-down stream truncations. No failures occurred in stages 0 through 3.
- The final Waldorf state has two Ready model replicas, a healthy EPP and WVA controller, and a Ready and Active KEDA ScaledObject.
