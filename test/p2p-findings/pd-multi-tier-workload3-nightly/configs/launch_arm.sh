#!/bin/bash
# launch_arm.sh <armfile-suffix> <tag> - deploy, hard-gate 16 ready, purge launchers, run
set -u
ARM=$1; TAG=$2
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/157fda50-ea95-416f-aaf6-9e3afa6c3eb8/scratchpad
K="kubectl --context kermit_US-EAST-01A -n nilig-p2p"
bash $SP/deploy_arm.sh $ARM
n=$($K get pods -l llm-d.ai/guide=pd-disaggregation --no-headers 2>/dev/null | grep -cE " ([12])/\1 +Running")
if [ "$n" != "16" ]; then echo "GATE_FAILED ready=$n - NOT launching"; exit 1; fi
$K delete pods -l app=llmdbench-harness-launcher --ignore-not-found >/dev/null 2>&1
$K get pods --no-headers 2>/dev/null | awk '/^inference-perf-/ {print $1}' | xargs -r $K delete pod --ignore-not-found >/dev/null 2>&1
bash $SP/run_arm.sh $TAG
grep -oE "Deployed pod 'inference-perf-[a-z0-9]+'" $SP/$TAG-run.log | tail -1
