#!/bin/bash
# run_arm.sh <tag> - prime, launch benchmark, print experiment id
set -u
TAG=$1
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/157fda50-ea95-416f-aaf6-9e3afa6c3eb8/scratchpad
K="kubectl --context kermit_US-EAST-01A -n nilig-p2p"
$K run prime-$TAG --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c \
 'for i in 1 2 3; do curl -s --max-time 60 -X POST http://pd-disaggregation-epp:80/v1/completions -H "Content-Type: application/json" -d "{\"model\":\"openai/gpt-oss-120b\",\"prompt\":\"prime\",\"max_tokens\":4}" -o /dev/null -w "%{http_code} "; done' >/dev/null 2>&1
mkdir -p $SP/$TAG-results
cd /Users/niliguy/github.com/llm-d-benchmark
nohup ./.venv/bin/llmdbenchmark --workspace $SP/$TAG-results --spec guides/pd-disaggregation run \
  --endpoint-url "http://pd-disaggregation-epp.nilig-p2p.svc.cluster.local:80" \
  --gateway-class epponly --model "openai/gpt-oss-120b" --namespace nilig-p2p \
  --harness inference-perf --workload-file-path "$SP/tiered-eviction-seeded.yaml.in" \
  --wait-timeout 7200 --monitoring > $SP/$TAG-run.log 2>&1 &
for i in $(seq 1 40); do
  grep -qE 'Deployed pod' $SP/$TAG-run.log 2>/dev/null && break
  sleep 15
done
grep -oE "experiment=[a-z0-9-]+" $SP/$TAG-run.log | tail -1
