FROM vllm/vllm-openai:nightly-6f91edf96d3f3272945809c04702380053bff4de
# vllm PR #50302 (open) ported to this base: unify block-table width
# (128-token alignment) between the block tables and the DSA indexer's
# expanded buffer. Runtime files only; the PR's model-runner hunks target
# a newer tree layout whose code paths do not exist in this base (its
# alignment lives in block_table.py, patched here).
COPY patched/vllm/v1/attention/backend.py /usr/local/lib/python3.12/dist-packages/vllm/v1/attention/backend.py
COPY patched/vllm/v1/attention/backends/mla/indexer.py /usr/local/lib/python3.12/dist-packages/vllm/v1/attention/backends/mla/indexer.py
COPY patched/vllm/v1/worker/block_table.py /usr/local/lib/python3.12/dist-packages/vllm/v1/worker/block_table.py
COPY patched/vllm/v1/worker/utils.py /usr/local/lib/python3.12/dist-packages/vllm/v1/worker/utils.py
