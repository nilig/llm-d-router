#!/bin/bash
# collect.sh <expdir> <outdir>
set -u
D=/requests/$1
OUT=$2
SP=/private/tmp/claude-501/-Users-niliguy-github-com-llm-d-router/157fda50-ea95-416f-aaf6-9e3afa6c3eb8/scratchpad
K="kubectl --context kermit_US-EAST-01A -n nilig-p2p exec access-to-harness-data-workload-pvc --"
for i in $(seq 1 90); do
  $K test -f $D/summary_lifecycle_metrics.json 2>/dev/null && break
  sleep 20
done
mkdir -p $SP/$OUT
for f in summary_lifecycle_metrics.json run_metadata.yaml stage_0_lifecycle_metrics.json stage_1_lifecycle_metrics.json stage_2_lifecycle_metrics.json stage_3_lifecycle_metrics.json stage_4_lifecycle_metrics.json stage_5_lifecycle_metrics.json stage_6_lifecycle_metrics.json stage_7_lifecycle_metrics.json; do
  $K cat $D/$f > $SP/$OUT/$f 2>/dev/null
done
echo "collected into $OUT:"; grep -E 'harness_rc|harness_delta' $SP/$OUT/run_metadata.yaml
