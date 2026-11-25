#!/bin/bash
# Copyright © 2026 Zhejiang Runhe Cloud Intelligence Technology Co., Ltd

# =============================================================================
# gen_runtime_port_merge_v0.1.3.sh -- fully automated regeneration of the
# miles-sail v0.1.3 runtime-port patch (self-contained: needs only git,
# python3 and public github access).
#
# Method: a three-way merge of the sglang-miles branch (the miles v0.1.3
# lock, carrying the runtime-port layer) into sglang-for-sail
# release/v0.5.22 (carrying the platform layer); the conflicts are resolved
# byte-exactly per the verified merge tree, the merge tree hash is asserted
# decisively, and a replayable patch is exported:
#   $OUT_DIR/sglang-0001-miles-v0.1.3-runtime-port-ppu-merge.patch
#   (plus the intermediate sglang-0001-miles-v0.1.3-runtime-port.patch)
#
# Refs (all public https, no credentials):
#   base   baa9befa  sglang-for-sail fork point = upstream v0.5.22 (the
#                    merge-base assert anchor)
#   theirs 3a938213  sglang-miles branch (miles v0.1.3 lock)
#   ours   SAIL_COMMIT (default 3ff592d) sglang-for-sail release/v0.5.22,
#          overridable, but the merge-base must still be baa9befa or the
#          script fails loudly
#
# Env (optional): WORKDIR / OUT_DIR / REF_DIR (byte-verify same-name patches)
#   GH_PROXY / SAIL_COMMIT / MERGE_TREE_EXPECT (empty = probe mode)
#   APPLY_CHECK=0 skips the baseline apply-check; CLEANUP=1 removes WORKDIR
# =============================================================================
set -euo pipefail

# ---------- pinned refs (v0.1.3, equivalent of release-lock + merge tree 0701d896) ----------
V522_COMMIT=baa9befa381511cd4d56f83980951e5a45fffc6d
MILES_COMMIT=3a938213c1b349e1a8df0b5fdc57ef36a41c743b
UPSTREAM_REPO=https://github.com/sgl-project/sglang.git
SAIL_REPO=https://github.com/flytiger-eco/sglang-for-sail.git
SAIL_BRANCH=release/v0.5.22
SAIL_COMMIT=${SAIL_COMMIT:-3ff592d03dcdcdab29e28dffed14b5aad846b403}
MERGE_BRANCH=port/sglang-miles-v0.5.22-v0.1.3
# decisive merge-tree assert (measured on port/sglang-miles-v0.1.3 merging
# the release/v0.5.22 tip @ 3ff592d; vs the old pin 2091d33 / tree 31e44373
# the delta is only the MiniMax-M3 MSA 4-file rename, and the merge patch is
# byte-identical). The value must change once sglang-for-sail moves ahead --
# fail loudly to force a conflict re-review and a pin refresh.
MERGE_TREE_EXPECT=${MERGE_TREE_EXPECT-0701d89629d8285a9be8959676514f47b2391945}
MERGE_STAT_EXPECT=${MERGE_STAT_EXPECT-190 files changed, 10432 insertions(+), 3134 deletions(-)}
MERGE_FILES_EXPECT=${MERGE_FILES_EXPECT-190}

# fetch depth: theirs is 51 commits ahead of base, ours 133+; the depth must
# cover every commit ahead or a shallow cut empties the merge-base.
MILES_FETCH_DEPTH=120
SAIL_FETCH_DEPTH=250

RAW_NAME=sglang-0001-miles-v0.1.3-runtime-port.patch
MERGE_NAME=sglang-0001-miles-v0.1.3-runtime-port-ppu-merge.patch

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKDIR=${WORKDIR:-/tmp/portmerge-v013-gen}
OUT_DIR=${OUT_DIR:-$SCRIPT_DIR}
REF_DIR=${REF_DIR:-}
APPLY_CHECK=${APPLY_CHECK:-1}
CLEANUP=${CLEANUP:-0}

if [ -n "${GH_PROXY:-}" ]; then
    GIT_NET=(git -c "http.proxy=$GH_PROXY" -c http.sslVerify=false)
else
    GIT_NET=(git)
fi

die() { echo "FATAL: $*" >&2; exit 1; }
fetch_retry() {
    local i desc="$1"; shift
    for i in 1 2 3; do
        if "$@"; then return 0; fi
        echo "RETRY $i for: $desc" >&2; sleep 10
    done
    die "fetch failed after 3 attempts: $desc"
}

mkdir -p "$OUT_DIR"
echo "== gen_runtime_port_merge_v013 =="
echo "   WORKDIR=$WORKDIR  OUT_DIR=$OUT_DIR  REF_DIR=${REF_DIR:-<none>}"

# ============================================================================
# Phase 1: fresh clone + ref fetch + topology asserts
# ============================================================================
REPO=$WORKDIR/sglang.git
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CLONE_OK=0
for _i in 1 2 3; do
    rm -rf "$REPO"
    if "${GIT_NET[@]}" clone --depth 1 --branch sglang-miles --single-branch \
        "$UPSTREAM_REPO" "$REPO"; then CLONE_OK=1; break; fi
    echo "RETRY $_i for: clone sglang-miles (depth 1)" >&2; sleep 10
done
[ "$CLONE_OK" = "1" ] || die "clone sglang-miles failed after 3 attempts"
cd "$REPO"

git remote add sglang-for-sail "$SAIL_REPO"
fetch_retry "fetch miles SHA (depth $MILES_FETCH_DEPTH)" \
    "${GIT_NET[@]}" fetch --depth "$MILES_FETCH_DEPTH" origin "$MILES_COMMIT"
fetch_retry "fetch sglang-for-sail $SAIL_BRANCH (depth $SAIL_FETCH_DEPTH)" \
    "${GIT_NET[@]}" fetch --depth "$SAIL_FETCH_DEPTH" sglang-for-sail "$SAIL_BRANCH"

git cat-file -e "$MILES_COMMIT^{commit}" || die "miles commit $MILES_COMMIT not fetched"
git cat-file -e "${SAIL_COMMIT}^{commit}" 2>/dev/null \
    || die "sglang-for-sail pin commit $SAIL_COMMIT not in fetched history (raise SAIL_FETCH_DEPTH)"
OURS_COMMIT="$SAIL_COMMIT"
echo "   ours = sglang-for-sail PINNED @ $OURS_COMMIT (branch HEAD $(git rev-parse --short "sglang-for-sail/$SAIL_BRANCH" 2>/dev/null || echo n/a) ignored)"

MB=$(git merge-base "$OURS_COMMIT" "$MILES_COMMIT" || true)
[ "$MB" = "$V522_COMMIT" ] || die "merge-base($OURS_COMMIT, $MILES_COMMIT)=$MB, expected $V522_COMMIT (shallow cut or sglang-for-sail rebased? raise SAIL_FETCH_DEPTH)"
echo "   topology OK: base=$MB miles=+$(git rev-list --count $V522_COMMIT..$MILES_COMMIT) sglang-for-sail=+$(git rev-list --count $V522_COMMIT..$OURS_COMMIT)"

# ============================================================================
# Phase 2: raw patch (git diff baa9befa..3a938213 -- python/sglang/)
# ============================================================================
RAW_OUT=$OUT_DIR/$RAW_NAME
git diff "$V522_COMMIT" "$MILES_COMMIT" -- python/sglang/ > "$RAW_OUT"
RAW_STAT=$(git diff --shortstat "$V522_COMMIT" "$MILES_COMMIT" -- python/sglang/)
echo "$RAW_STAT" | grep -F "190 files changed, 10427 insertions(+), 3122 deletions(-)" >/dev/null \
    || die "raw patch stat drift: $RAW_STAT"
echo "   raw patch: $RAW_STAT -> $RAW_OUT"

if [ -n "$REF_DIR" ] && [ -f "$REF_DIR/$RAW_NAME" ]; then
    cmp -s "$RAW_OUT" "$REF_DIR/$RAW_NAME" \
        && echo "   raw patch: BYTE-IDENTICAL to reference" \
        || die "raw patch differs from $REF_DIR/$RAW_NAME"
fi

# ============================================================================
# Phase 3: three-way merge (worktree @ sglang-for-sail release/v0.5.22 baseline + merge miles)
# ============================================================================
WT=$WORKDIR/portmerge-wt
git worktree prune 2>/dev/null || true
git worktree add --detach "$WT" "$OURS_COMMIT" >/dev/null
cd "$WT"

# committer identity must be configured before the merge (repo-local;
# worktrees share the main repo config)
git config user.name "miles-sail-build"
git config user.email "miles-sail-build@users.noreply.github.com"

git checkout -q -b "$MERGE_BRANCH"

set +e
git merge --no-commit --no-ff "$MILES_COMMIT" >/dev/null 2>&1
MERGE_RC=$?
set -e
if [ "$MERGE_RC" != "0" ] && [ "$MERGE_RC" != "1" ]; then
    die "git merge exit=$MERGE_RC (expected 0/1; 1=conflict). Likely env issue -- re-run with merge output visible"
fi

CONFLICTS=$(git diff --name-only --diff-filter=U | sort)
CONFLICT_COUNT=$(git diff --name-only --diff-filter=U | wc -l)
EXPECTED_CONFLICTS="python/sglang/srt/layers/attention/dsa/dsa_indexer.py
python/sglang/srt/layers/attention/dsa/dsa_topk_backend.py
python/sglang/srt/layers/linear.py
python/sglang/srt/layers/quantization/mxfp4.py
python/sglang/srt/model_executor/model_runner.py
python/sglang/srt/models/deepseek_common/deepseek_weight_loader.py
python/sglang/srt/models/kimi_k3.py"
if [ "$CONFLICTS" != "$EXPECTED_CONFLICTS" ]; then
    echo "== conflict set mismatch ==" >&2
    diff <(echo "$EXPECTED_CONFLICTS") <(echo "$CONFLICTS") >&2 || true
    die "expected 7 conflict files, got $CONFLICT_COUNT (refs drifted?)"
fi
echo "   merge conflicts: $CONFLICT_COUNT files / 12 blocks + 1 whole-file (as expected)"

# ============================================================================
# Phase 4: conflict resolution (embedded resolver, solutions byte-exact
# from the verified merge tree 8aeeb355a4)
# ============================================================================
cat > "$WORKDIR/resolve_conflicts_v013.py" <<'PYEOF'

#!/usr/bin/env python3
"""Resolve the v0.1.3 three-way merge conflicts (7 files / 12 blocks + 1 whole file).

Solutions are taken byte-exact from the verified merge tree 8aeeb355a4
(port/sglang-miles-v0.1.3 merging sglang-for-sail release/v0.5.22 c1ca044f,
merge tree 9fb91132a0):
- 6 files resolved block-by-block in order (keeping both sides, with
  in-block side-order corrections);
- deepseek_weight_loader.py's solution is rearranged outside the conflict
  block boundaries and applied as a whole-file overwrite.
Final check: the 7 files' md5 values equal EXPECT_MD5 (equivalent to the
merge tree assert).
"""
import hashlib
import os
import sys

ROOT = os.environ["PORTMERGE_ROOT"]

EXPECT_MD5 = {'srt/layers/attention/dsa/dsa_indexer.py': 'bd81f6cb12b5a0f60b90c43d66ff2c29', 'srt/layers/attention/dsa/dsa_topk_backend.py': '0aa29b65ae81d109920a95213dd6afd0', 'srt/layers/linear.py': '2a7296bb223ad582b19340dd2a7baae7', 'srt/layers/quantization/mxfp4.py': '376f7ff61bcffab703adff372cf5afc4', 'srt/model_executor/model_runner.py': '40c899b9fabbe11e7a20162feb02e629', 'srt/models/deepseek_common/deepseek_weight_loader.py': '13e7a8a3992e44b3bd4f7fc94e8ccd08', 'srt/models/kimi_k3.py': 'b9588d63c909738d470cdf5df350aac3'}

SOLS = {
    "srt/layers/attention/dsa/dsa_indexer.py": [
    '            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).\n            if _enable_logits_nan_check:\n                _check_logits_nan_in_valid_range(logits, ks, ke)\n            if capture:\n                transformed, raw = metadata.topk_transform(\n                    logits, self.index_topk, ks=ks, return_raw_indices=True\n                )\n                topk_result[:q_offset] = transformed\n                raw_result[:q_offset] = raw\n            else:\n                topk_result[:q_offset] = metadata.topk_transform(\n                    logits, self.index_topk, ks=ks\n                )\n            return topk_result, raw_result\n',
    '            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).\n            if _enable_logits_nan_check:\n                _check_logits_nan_in_valid_range(\n                    logits_chunk, ks[start:end], ke[start:end], row_offset=start\n                )\n            if capture:\n                transformed, raw = metadata.topk_transform(\n                    logits_chunk,\n                    self.index_topk,\n                    ks=ks[start:end],\n                    cu_seqlens_q=cu_seqlens_q_chunk,\n                    ke_offset=lengths_chunk,\n                    batch_idx_list=batch_idx_chunk,\n                    topk_indices_offset_override=topk_offset_chunk,\n                    return_raw_indices=True,\n                )\n                topk_result[start:end] = transformed\n                raw_result[start:end] = raw\n            else:\n                topk_result[start:end] = metadata.topk_transform(\n                    logits_chunk,\n                    self.index_topk,\n                    ks=ks[start:end],\n                    cu_seqlens_q=cu_seqlens_q_chunk,\n                    ke_offset=lengths_chunk,\n                    batch_idx_list=batch_idx_chunk,\n                    topk_indices_offset_override=topk_offset_chunk,\n                )\n',
    '            #! <Note>[phh]:In PR#19148 of the sglang community, a new fusion Kernel has been\n            # added to perform quantization and storage Index_k together .\n            # However, for BF16_INDEXER, set_index_k_scale_buffer is still required\n            if self.bf16_indexer or self.use_int8:\n                # k_fp8: (seq_len, head_dim) fp8_e4m3fn\n                # k_buffer: (num_total_tokens + page_size, head_dim) fp8_e4m3fn\n                # k_scale: (seq_len, head_dim // block_size = 1) fp8_e4m3fn\n                # k_scale_cache: (num_total_tokens + page_size, head_dim // block_size = 1) fp8_e4m3fn\n                if not forward_batch.out_cache_loc.is_contiguous():\n                    forward_batch.out_cache_loc = (\n                        forward_batch.out_cache_loc.contiguous()\n                    )\n                get_token_to_kv_pool().set_index_k_scale_buffer(\n                    layer_id=layer_id,\n                    loc=forward_batch.out_cache_loc,\n                    index_k=k_fp8,\n                    index_k_scale=k_scale,\n                )\n\n        raw_result = None\n',
    '                if (\n                    forward_batch.attn_cp_metadata is not None\n                    and is_dsa_prefill_cp_in_seq_split()\n                ):\n                    kv_len_prev = forward_batch.attn_cp_metadata.kv_len_prev_list[0]\n                    kv_len_next = forward_batch.attn_cp_metadata.kv_len_next_list[0]\n                    actual_seq_q_prev = (\n                        forward_batch.attn_cp_metadata.actual_seq_q_prev_list[0]\n                    )\n                    actual_seq_q_next = (\n                        forward_batch.attn_cp_metadata.actual_seq_q_next_list[0]\n                    )\n\n                    # TODO support mutil-batch\n                    # cp_batch_seq_index_prev = forward_batch.attn_cp_metadata["cp_batch_seq_index_prev"]\n                    # cp_batch_seq_index_next = forward_batch.attn_cp_metadata["cp_batch_seq_index_next"]\n                    # TODO prev, next, combined into a single call\n                    if self.use_fp4:\n                        # FP4: q_fp8 is (q_packed, q_sf) tuple; split both components\n                        q_packed, q_sf = q_fp8\n                        q_packed_prev, q_packed_next = torch.split(\n                            q_packed, (q_packed.shape[0] + 1) // 2, dim=0\n                        )\n                        q_sf_prev, q_sf_next = torch.split(\n                            q_sf, (q_sf.shape[0] + 1) // 2, dim=0\n                        )\n                        q_fp8_prev = (q_packed_prev, q_sf_prev)\n                        q_fp8_next = (q_packed_next, q_sf_next)\n                    else:\n                        q_fp8_prev, q_fp8_next = torch.split(\n                            q_fp8, (q_fp8.shape[0] + 1) // 2, dim=0\n                        )\n                    weights_prev, weights_next = torch.split(\n                        weights, (weights.shape[0] + 1) // 2, dim=0\n                    )\n                    topk_result_prev = self._get_topk_ragged_with_cp(\n                        forward_batch,\n                        layer_id,\n                        q_fp8_prev,\n                        weights_prev,\n                        metadata,\n                        kv_len_prev,\n                        actual_seq_q_prev,\n                    )\n\n                    topk_result_next = self._get_topk_ragged_with_cp(\n                        forward_batch,\n                        layer_id,\n                        q_fp8_next,\n                        weights_next,\n                        metadata,\n                        kv_len_next,\n                        actual_seq_q_next,\n                    )\n                    topk_result = torch.cat([topk_result_prev, topk_result_next], dim=0)\n                    topk_result = _broadcast_indexer_topk_from_rank0(topk_result)\n                    return maybe_capture_indexer_topk(layer_id, topk_result)\n                else:\n                    # In-graph (PCG/BCG) non-CP prefill is handled earlier by the\n                    # graph DSA split-op dispatch, so only the eager path reaches\n                    # here.\n                    assert not in_piecewise_or_breakable_cuda_graph, (\n                        "Internal error: in-graph DSA prefill must go through the "\n                        "graph DSA split-op dispatch"\n                    )\n                    topk_result, raw_result = self._get_topk_ragged(\n                        enable_dual_stream,\n                        forward_batch,\n                        layer_id,\n                        q_fp8,\n                        weights,\n                        metadata,\n                    )\n',
],
    "srt/layers/attention/dsa/dsa_topk_backend.py": [
    "                # Route PAGED path through dsv4's bf16 topk kernel when gate is on\n                # and logits are bf16; falls back to fast_topk_transform_fused otherwise.\n                if (\n                    envs.SGLANG_DSA_USE_DSV4_BF16_TOPK.get()\n                    and logits.dtype == torch.bfloat16\n                ):\n                    return self._topk_transform_dsv4_bf16(\n                        logits=logits,\n                        seq_lens_topk=lengths,\n                        page_table_size_1=page_table_size_1,\n                        cu_seqlens_q_topk=cu_seqlens_q_topk,\n                        topk=topk,\n                        ks=row_starts,\n                    )\n                result = fast_topk_transform_fused(\n",
],
    "srt/layers/linear.py": [
    '            if SGLANG_PROFILE_NVTX:\n                tmp_weight = getattr(self, "weight", None)\n                nvtx_push_range_for_gemm(\n                    "RowParallelLinear", input_parallel, tmp_weight, None, None, bias_\n                )\n            from sglang.srt.layers.quantization.fp8 import Fp8LinearMethod\n\n            is_tuple = isinstance(input_parallel, tuple)\n            is_fp8 = isinstance(self.quant_method, Fp8LinearMethod)\n            k_size = (\n                input_parallel[0].shape[-1] if is_tuple else input_parallel.shape[-1]\n            )\n            if should_use_tp_invariant_row_linear(k_size):\n                if output_tensor is not None:\n                    raise RuntimeError(\n                        "tp-invariant row linear cannot write into a caller-owned "\n                        "output tensor"\n                    )\n                if is_fp8:\n                    raise NotImplementedError(\n                        "FP8 tp-invariant row-linear not yet supported"\n                    )\n                output_parallel = torch.ops.tp_inv_ops.matmul_tp_inv(\n                    input_parallel, self.weight.t(), bias_\n                )\n            elif output_tensor is None:\n',
],
    "srt/layers/quantization/mxfp4.py": [
    '                deinterleave_moe_mxfp4_w13_for_marlin(\n                    layer, reuse_parameter_storage=reuse_parameter_storage\n                )\n            prepare_moe_mxfp4_layer_for_marlin(\n                layer, reuse_parameter_storage=reuse_parameter_storage\n            )\n            runtime_specs = {\n                name: (tuple(getattr(layer, name).shape), getattr(layer, name).dtype)\n                for name in self._marlin_parameter_names(layer)\n            }\n            if reuse_parameter_storage:\n                if runtime_specs != layer._mxfp4_marlin_runtime_parameter_specs:\n                    raise ValueError(\n                        "MXFP4 Marlin in-place reload changed the runtime layout: "\n                        f"{runtime_specs} vs {layer._mxfp4_marlin_runtime_parameter_specs}."\n                    )\n            else:\n                layer._mxfp4_marlin_runtime_parameter_specs = runtime_specs\n            layer._mxfp4_marlin_reload_in_place = False\n            if _is_sail and self.use_deepgemm_mxfp4_w4a16_valu:\n                # DeepGEMM uses uint8 E8M0 scales to select its MXFP4/E2M1 path.\n                for scale_name in ("w13_weight_scale", "w2_weight_scale"):\n                    scale = getattr(layer, scale_name)\n                    setattr(\n                        layer,\n                        scale_name,\n                        Parameter(scale.view(torch.uint8), requires_grad=False),\n                    )\n                del scale\n                # Release stale loader tensors and Marlin conversion buffers\n                # before KV-cache sizing measures available device memory.\n                torch.cuda.empty_cache()\n',
],
    "srt/model_executor/model_runner.py": [
    '        self.prepare_eplb_async_layers()\n        # drafts publish once the spec worker binds the target\'s embed and head (Scheduler.init_memory_pools)\n        if not self.is_draft_worker:\n            self.remote_instance_weight_transporter.maybe_register_and_publish_weight_info(\n                role="target"\n            )\n',
    '                if SGLANG_PROFILE_NVTX:\n                    th_nvtx_range_pop()\n                return ModelRunnerOutput(\n                    logits_output=ret,\n                    can_run_graph=can_run_graph,\n                    graph_num_tokens=self.decode_cuda_graph_runner.bs\n                    * self.decode_cuda_graph_runner.captured_req_width,\n                )\n',
    '            if SGLANG_PROFILE_NVTX:\n                th_nvtx_range_pop()\n\n            return ModelRunnerOutput(\n                logits_output=ret,\n                can_run_graph=can_run_graph,\n                graph_num_tokens=graph_num_tokens,\n            )\n',
],
    "srt/models/kimi_k3.py": [
    '            self._bfa_w, sizes = _merge_weights_as_views(\n                mods, pad_rows_to=pad_rows_to, merged=self._bfa_w\n            )\n            # .data: a second Parameter registration hides f_b_proj.weight from named_parameters()\n            self._bfa_f_b_w = self.f_b_proj.weight.data\n        self._bfa_fa_size, self._bfa_b_size = sizes[-2:]\n',
    '    # Fused runtime module -> checkpoint shard names, so quant configs can\n    # match fused prefixes against per-shard exclude_modules\n    packed_modules_mapping = {\n        "fused_qkv_a_proj_with_mqa": ["q_a_proj", "kv_a_proj_with_mqa"],\n        "gate_up_proj": ["gate_proj", "up_proj"],\n        "qkv_proj": ["q_proj", "k_proj", "v_proj"],\n        "qkv_conv1d": ["q_conv1d", "k_conv1d", "v_conv1d"],\n        "fused_qkvg_proj": ["q_proj", "k_proj", "v_proj", "g_proj"],\n        "fused_qkvbfg_a_proj": [\n            "q_proj",\n            "k_proj",\n            "v_proj",\n            "b_proj",\n            "f_a_proj",\n            "g_a_proj",\n        ],\n        "fused_fg_b_proj": ["f_b_proj", "g_b_proj"],\n    }\n\n    @staticmethod\n    def get_lora_target_module_name(name: str) -> str:\n        parent, _, leaf = name.rpartition(".")\n        if ".experts" in parent:\n            return {"w1": "gate_proj", "w2": "down_proj", "w3": "up_proj"}.get(\n                leaf, name\n            )\n        return name\n',
],
    "srt/models/deepseek_common/deepseek_weight_loader.py": None,  # whole-file; see WHOLE below
}

WHOLE = '# Copyright 2026 SGLang Team\n# Licensed under the Apache License, Version 2.0 (the "License");\n# you may not use this file except in compliance with the License.\n# You may obtain a copy of the License at\n#\n#     http://www.apache.org/licenses/LICENSE-2.0\n#\n# Unless required by applicable law or agreed to in writing, software\n# distributed under the License is distributed on an "AS IS" BASIS,\n# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.\n# See the License for the specific language governing permissions and\n# limitations under the License.\n# ==============================================================================\n\nimport concurrent.futures\nimport logging\nfrom dataclasses import dataclass\nfrom typing import Dict, Iterable, List, Optional, Tuple\n\nimport torch\nimport torch.nn as nn\nimport tqdm\nfrom sgl_kernel import gptq_dequantize\nfrom transformers import PretrainedConfig\n\nfrom sglang.srt.distributed.parallel_state import GroupCoordinator\nfrom sglang.srt.environ import envs\nfrom sglang.srt.layers import deep_gemm_wrapper\nfrom sglang.srt.layers.moe.fused_moe_triton.layer import FusedMoE\nfrom sglang.srt.layers.quantization.base_config import QuantizationConfig\nfrom sglang.srt.layers.quantization.fp8_utils import (\n    block_quant_dequant,\n    block_quant_to_tensor_quant,\n    channel_quant_to_tensor_quant,\n    input_to_float8,\n    inverse_transform_scale_ue8m0,\n    normalize_e4m3fn_to_e4m3fnuz,\n    quant_weight_ue8m0,\n)\nfrom sglang.srt.layers.quantization.int8_utils import (\n    block_dequant as int8_block_dequant,\n)\nfrom sglang.srt.layers.quantization.mxfp8_block_convert import dequant_mxfp8_2d_to_bf16\nfrom sglang.srt.layers.utils import get_layer_id\nfrom sglang.srt.model_loader.utils import (\n    maybe_executor_submit,\n    should_async_load,\n    should_deepgemm_weight_requant_ue8m0,\n)\nfrom sglang.srt.model_loader.weight_utils import (\n    RUNAI_STREAMER_TENSOR_ATTR,\n    default_weight_loader,\n)\nfrom sglang.srt.models.deepseek_common.utils import (\n    _is_cuda,\n    _is_fp8_fnuz,\n    _is_hip,\n    _is_musa,\n    _is_npu,\n    _is_sail,\n    _is_xpu,\n    _use_aiter_gfx95,\n    awq_dequantize_func,\n    enable_nextn_moe_bf16_cast_to_fp8,\n    is_wint4afp8_or_wint4a16_config,\n)\nfrom sglang.srt.utils import (\n    bind_or_assign,\n    get_bool_env_var,\n    is_sail,\n    log_info_on_rank0,\n)\n\nif _use_aiter_gfx95:\n    from sglang.srt.layers.quantization.quark.utils import quark_post_load_weights\n\nlogger = logging.getLogger(__name__)\n\n# Optional quantization for DeepSeek nvfp4 checkpoint\nNVFP4_CKPT_FP8_ATTN_QUANT_MODULES = ["q_b_proj"]\n\n\ndef _clone_if_runai_streamed_tensor(tensor: torch.Tensor) -> torch.Tensor:\n    if getattr(tensor, RUNAI_STREAMER_TENSOR_ATTR, False):\n        return tensor.clone().detach()\n    return tensor\n\n\ndef _get_indexer_weight_block_size(\n    quant_config: Optional[QuantizationConfig],\n) -> List[int]:\n    if quant_config is not None and quant_config.weight_block_size is not None:\n        return quant_config.weight_block_size\n    return [128, 128]\n\n\ndef _dequant_fused_indexer_shard(\n    weight: torch.Tensor,\n    scale: torch.Tensor,\n    quant_config: Optional[QuantizationConfig],\n) -> torch.Tensor:\n    # mxfp8 scales are UE8M0 exponents stored as uint8, not fp32 multipliers\n    if scale.dtype == torch.uint8:\n        return dequant_mxfp8_2d_to_bf16(weight, scale)\n    if scale.numel() == weight.shape[0]:\n        # per-output-channel scale (w8a8 int8 / channelwise fp8)\n        return (weight.float() * scale.float()).to(torch.bfloat16)\n    return block_quant_dequant(\n        weight, scale, _get_indexer_weight_block_size(quant_config), torch.bfloat16\n    )\n\n\ndef _load_fused_indexer_wk(\n    name: str,\n    loaded_weight: torch.Tensor,\n    params_dict: Dict[str, torch.Tensor],\n    pending: Dict[str, Dict[str, torch.Tensor]],\n    quant_config: Optional[QuantizationConfig],\n) -> bool:\n    """Load an indexer wk / weights_proj shard into the fused bf16 wk_weights_proj\n    param: wk fills the top head_dim rows (dequantized from block-fp8 if needed),\n    weights_proj the bottom n_heads rows.\n\n    Returns False when there is no fused param (non-CUDA, or CUDA with\n    SGLANG_DISABLE_DSA_INDEXER_FUSION set, where wk and weights_proj are\n    separate) so the caller falls through to per-tensor loading.\n    """\n    fused_name = name.rsplit(".indexer.", 1)[0] + ".indexer.wk_weights_proj.weight"\n    fused_param = params_dict.get(fused_name)\n    if fused_param is None or fused_param.dtype != torch.bfloat16:\n        return False\n\n    if ".indexer.weights_proj." in name:\n        is_scale = name.endswith(".weight_scale_inv") or name.endswith(".weight_scale")\n        if not is_scale and loaded_weight.dtype not in (\n            torch.float8_e4m3fn,\n            torch.int8,\n        ):\n            w = _clone_if_runai_streamed_tensor(loaded_weight)\n            fused_param.data[-w.shape[0] :].copy_(w)\n            return True\n\n        entry = pending.setdefault(fused_name + ".weights_proj", {})\n        entry["scale" if is_scale else "weight"] = _clone_if_runai_streamed_tensor(\n            loaded_weight\n        )\n        if "weight" in entry and "scale" in entry:\n            pending.pop(fused_name + ".weights_proj")\n            weights_bf16 = _dequant_fused_indexer_shard(\n                entry["weight"], entry["scale"], quant_config\n            )\n            fused_param.data[-weights_bf16.shape[0] :].copy_(weights_bf16)\n        return True\n\n    # wk: a bf16 checkpoint copies straight in; quantized checkpoints (block-fp8\n    # with weight_scale_inv, channelwise int8/fp8 with weight_scale) need dequant.\n    is_scale = name.endswith(".weight_scale_inv") or name.endswith(".weight_scale")\n    if not is_scale and loaded_weight.dtype not in (\n        torch.float8_e4m3fn,\n        torch.int8,\n    ):\n        w = _clone_if_runai_streamed_tensor(loaded_weight)\n        fused_param.data[: w.shape[0]].copy_(w)\n        return True\n\n    entry = pending.setdefault(fused_name, {})\n    entry["scale" if is_scale else "weight"] = _clone_if_runai_streamed_tensor(\n        loaded_weight\n    )\n    if "weight" in entry and "scale" in entry:\n        pending.pop(fused_name)\n        wk_bf16 = _dequant_fused_indexer_shard(\n            entry["weight"], entry["scale"], quant_config\n        )\n        fused_param.data[: wk_bf16.shape[0]].copy_(wk_bf16)\n    return True\n\n\ndef _load_fused_expert_tensor(\n    name: str,\n    loaded_weight: torch.Tensor,\n    params_dict: Dict[str, torch.Tensor],\n) -> bool:\n    mappings = (\n        (".experts.gate_up_proj_scale", ".experts.w13_weight_scale_inv", "w13"),\n        (".experts.down_proj_scale", ".experts.w2_weight_scale_inv", "w2"),\n        (".experts.gate_up_proj", ".experts.w13_weight", "w13"),\n        (".experts.down_proj", ".experts.w2_weight", "w2"),\n    )\n    for source, target, shard_id in mappings:\n        if not name.endswith(source):\n            continue\n        param_name = name[: -len(source)] + target\n        param = params_dict.get(param_name)\n        if param is None:\n            return False\n        weight_loader = param.weight_loader\n        for expert_id, expert_weight in enumerate(loaded_weight):\n            if shard_id == "w13":\n                gate, up = expert_weight.chunk(2, dim=0)\n                weight_loader(\n                    param, gate, param_name, shard_id="w1", expert_id=expert_id\n                )\n                weight_loader(param, up, param_name, shard_id="w3", expert_id=expert_id)\n            else:\n                weight_loader(\n                    param,\n                    expert_weight,\n                    param_name,\n                    shard_id="w2",\n                    expert_id=expert_id,\n                )\n        return True\n    return False\n\n\n@dataclass(frozen=True)\nclass NextNEnabledConfig:\n    num_nextn_layers: int\n    nextn_layer_id: int\n    nextn_layer_prefix: str\n    nextn_spec_weight_names: List[str]\n\n\n@dataclass(frozen=True)\nclass NextNDisabledConfig:\n    pass\n\n\n"""Union type for NextN configuration, including enabled and disabled configurations."""\nNextNConfig = NextNEnabledConfig | NextNDisabledConfig\n\n\nclass DeepseekV2WeightLoaderMixin:\n    """Mixin for loading weights in DeepSeek V2/V3 models."""\n\n    model: nn.Module\n    config: PretrainedConfig\n    quant_config: Optional[QuantizationConfig]\n    pp_group: GroupCoordinator\n    num_fused_shared_experts: int\n\n    def do_load_weights(\n        self,\n        weights: Iterable[Tuple[str, torch.Tensor]],\n        is_nextn: bool = False,\n    ):\n        """Load model weights from checkpoint.\n\n        Args:\n            weights: Iterable of (weight_name, weight_tensor) pairs\n            is_nextn: Whether loading NextN speculative decoding weights\n        """\n        nextn_conf = self._initialize_nextn_conf(is_nextn)\n\n        weights = self._maybe_quant_weights_to_fp8_ue8m0(\n            weights, NVFP4_CKPT_FP8_ATTN_QUANT_MODULES, nextn_conf\n        )\n\n        stacked_params_mapping = [\n            # (param_name, shard_name, shard_id)\n            ("gate_up_proj", "gate_proj", 0),\n            ("gate_up_proj", "up_proj", 1),\n        ]\n\n        # Params for weights, fp8 weight scales, fp8 activation scales\n        # (param_name, weight_name, expert_id, shard_id)\n        expert_params_mapping = FusedMoE.make_expert_params_mapping(\n            ckpt_gate_proj_name="gate_proj",\n            ckpt_down_proj_name="down_proj",\n            ckpt_up_proj_name="up_proj",\n            num_experts=self.config.n_routed_experts + self.num_fused_shared_experts,\n        )\n        # Params for special naming rules in mixed-precision models, for example:\n        # model.layers.xx.mlp.experts.xx.w1.input_scale. For details,\n        # see https://huggingface.co/Barrrrry/DeepSeek-R1-W4AFP8/blob/main.\n        if is_wint4afp8_or_wint4a16_config(self.quant_config):\n            expert_params_mapping += FusedMoE.make_expert_input_scale_params_mapping(\n                num_experts=self.config.n_routed_experts\n            )\n\n        # Fuse q_a_proj and kv_a_proj_with_mqa along output dimension when q_lora_rank is not None\n        fuse_qkv_a_proj = hasattr(self.config, "q_lora_rank") and (\n            self.config.q_lora_rank is not None\n        )\n        cached_a_proj = {} if fuse_qkv_a_proj else None\n\n        pending_indexer_wk: Dict[str, Dict[str, torch.Tensor]] = {}\n\n        if self.num_fused_shared_experts > 0:\n            assert self.num_fused_shared_experts == 1\n            log_info_on_rank0(logger, "Shared experts fusion optimization enabled.")\n\n        with concurrent.futures.ThreadPoolExecutor() as executor:\n            futures = []\n            params_dict = dict(self.named_parameters())\n            indexer_present_prefixes = {\n                n.rsplit(".indexer.", 1)[0] for n in params_dict if ".indexer." in n\n            }\n            weight_names = []\n\n            for name, loaded_weight in weights:\n                use_async_loading = should_async_load(loaded_weight)\n                layer_id = get_layer_id(name)\n                if (\n                    layer_id is not None\n                    and hasattr(self.model, "start_layer")\n                    and (\n                        layer_id < self.model.start_layer\n                        or layer_id >= self.model.end_layer\n                    )\n                ):\n                    continue\n                if self.num_fused_shared_experts > 0 and "mlp.shared_experts" in name:\n                    name = name.replace(\n                        "mlp.shared_experts",\n                        f"mlp.experts.{self.config.n_routed_experts}",\n                    )\n\n                weight_names.append(name)\n\n                match nextn_conf:\n                    case NextNEnabledConfig(\n                        nextn_layer_prefix=layer_prefix,\n                        nextn_spec_weight_names=spec_weight_names,\n                    ):\n                        if not name.startswith(layer_prefix):\n                            continue\n\n                        # Use shared head and embed weights from target model\n                        if "shared_head.head" in name or "embed_tokens" in name:\n                            continue\n\n                        # Transform name: NextN-specific → "model.*", decoder → "model.decoder.*"\n                        if any(s in name for s in spec_weight_names):\n                            name = name.replace(layer_prefix, "model")\n                        else:\n                            name = name.replace(layer_prefix, "model.decoder")\n                    case NextNDisabledConfig():\n                        if hasattr(self.config, "num_nextn_predict_layers"):\n                            num_nextn_layers = self.config.num_nextn_predict_layers\n                            if num_nextn_layers > 0 and name.startswith("model.layers"):\n                                name_list = name.split(".")\n                                if (\n                                    len(name_list) >= 3\n                                    and int(name_list[2])\n                                    >= self.config.num_hidden_layers\n                                ):\n                                    continue\n\n                if _load_fused_expert_tensor(name, loaded_weight, params_dict):\n                    continue\n\n                if "rotary_emb.inv_freq" in name:\n                    continue\n\n                if ".indexer." in name and (\n                    name.rsplit(".indexer.", 1)[0] not in indexer_present_prefixes\n                ):\n                    continue\n\n                # CUDA fuses wk + weights_proj into one bf16 wk_weights_proj; the\n                # helper returns True once it has consumed the shard.\n                if (\n                    ".indexer.wk." in name or ".indexer.weights_proj." in name\n                ) and _load_fused_indexer_wk(\n                    name,\n                    loaded_weight,\n                    params_dict,\n                    pending_indexer_wk,\n                    self.quant_config,\n                ):\n                    continue\n\n                for param_name, weight_name, shard_id in stacked_params_mapping:\n                    # Skip non-stacked layers and experts (experts handled below).\n                    if weight_name not in name:\n                        continue\n                    if _is_npu:\n                        name = name.replace("weight_packed", "weight")\n                    # We have mlp.experts[0].gate_proj in the checkpoint.\n                    # Since we handle the experts below in expert_params_mapping,\n                    # we need to skip here BEFORE we update the name, otherwise\n                    # name will be updated to mlp.experts[0].gate_up_proj, which\n                    # will then be updated below in expert_params_mapping\n                    # for mlp.experts[0].gate_gate_up_proj, which breaks load.\n                    if ("mlp.experts." in name) and name not in params_dict:\n                        continue\n                    name = name.replace(weight_name, param_name)\n                    # Skip loading extra bias for GPTQ models.\n                    if name.endswith(".bias") and name not in params_dict:\n                        continue\n                    param = params_dict[name]\n                    weight_loader = param.weight_loader\n                    maybe_executor_submit(\n                        executor=executor,\n                        futures=futures,\n                        use_async=use_async_loading,\n                        func=weight_loader,\n                        func_args=(param, loaded_weight, shard_id),\n                    )\n                    break\n                else:\n                    for mapping in expert_params_mapping:\n                        param_name, weight_name, expert_id, shard_id = mapping\n                        if weight_name not in name:\n                            continue\n                        if _is_npu:\n                            name = name.replace("weight_packed", "weight")\n                        name = name.replace(weight_name, param_name)\n                        if name not in params_dict:\n                            continue\n                        param = params_dict[name]\n                        weight_loader = param.weight_loader\n                        maybe_executor_submit(\n                            executor=executor,\n                            futures=futures,\n                            use_async=use_async_loading,\n                            func=weight_loader,\n                            func_args=(\n                                param,\n                                loaded_weight,\n                                name,\n                            ),\n                            func_kwargs={\n                                "shard_id": shard_id,\n                                "expert_id": expert_id,\n                            },\n                        )\n                        break\n                    else:\n                        # Skip loading extra bias for GPTQ models.\n                        if name.endswith(".bias") and name not in params_dict:\n                            continue\n                        # The last PP stage also owns an embedding for its NextN draft.\n                        if ".embed_tokens." in name and name not in params_dict:\n                            continue\n                        # Skip loading norm if not last rank in pipeline parallelism\n                        if ".norm." in name and not self.pp_group.is_last_rank:\n                            continue\n                        if fuse_qkv_a_proj and (\n                            "q_a_proj" in name or "kv_a_proj_with_mqa" in name\n                        ):\n                            # Skip loading g_idx for GPTQ models.\n                            if name.endswith(".g_idx"):\n                                continue\n\n                            cached_a_proj[name] = _clone_if_runai_streamed_tensor(\n                                loaded_weight\n                            )\n                            q_a_proj_name = (\n                                name\n                                if "q_a_proj" in name\n                                else name.replace("kv_a_proj_with_mqa", "q_a_proj")\n                            )\n                            kv_a_proj_name = (\n                                name\n                                if "kv_a_proj_with_mqa" in name\n                                else name.replace("q_a_proj", "kv_a_proj_with_mqa")\n                            )\n\n                            # When both q_a_proj and kv_a_proj_with_mqa has been cached, load the fused weight to parameter\n                            if (\n                                q_a_proj_name in cached_a_proj\n                                and kv_a_proj_name in cached_a_proj\n                            ):\n                                q_a_proj_weight = cached_a_proj[q_a_proj_name]\n                                kv_a_proj_weight = cached_a_proj[kv_a_proj_name]\n\n                                if q_a_proj_weight.shape == torch.Size(\n                                    []\n                                ) and kv_a_proj_weight.shape == torch.Size([]):\n                                    fused_weight = q_a_proj_weight\n                                else:\n                                    cat_dim = 0\n                                    if self.quant_config is not None and (\n                                        self.quant_config.get_name() == "awq"\n                                        or self.quant_config.get_name() == "awq_marlin"\n                                        or self.quant_config.get_name() == "moe_wna16"\n                                        or self.quant_config.get_name() == "gptq"\n                                        or self.quant_config.get_name() == "gptq_marlin"\n                                    ):\n                                        cat_dim = 1\n\n                                    fused_weight = torch.cat(\n                                        [q_a_proj_weight, kv_a_proj_weight], dim=cat_dim\n                                    )\n\n                                param_name = (\n                                    name.replace(\n                                        "q_a_proj", "fused_qkv_a_proj_with_mqa"\n                                    )\n                                    if "q_a_proj" in name\n                                    else name.replace(\n                                        "kv_a_proj_with_mqa",\n                                        "fused_qkv_a_proj_with_mqa",\n                                    )\n                                )\n                                param = params_dict[param_name]\n\n                                weight_loader = getattr(\n                                    param, "weight_loader", default_weight_loader\n                                )\n                                maybe_executor_submit(\n                                    executor=executor,\n                                    futures=futures,\n                                    use_async=use_async_loading,\n                                    func=weight_loader,\n                                    func_args=(param, fused_weight),\n                                )\n                                cached_a_proj.pop(q_a_proj_name)\n                                cached_a_proj.pop(kv_a_proj_name)\n                        else:\n                            if (\n                                "k_scale" in name or "v_scale" in name\n                            ) and name not in params_dict:\n                                # modelopt attn kv scale is named differently\n                                for scale in ["k_scale", "v_scale"]:\n                                    if scale in name:\n                                        name = name.replace(\n                                            f"{scale[0]}_proj", "attn_mqa"\n                                        )\n                                        break\n                            if name not in params_dict:\n                                # modelopt ckpt contains not needed weights for MTP module:\n                                # model.decoder.self_attn.attn_mqa.v_scale and\n                                # model.decoder.self_attn.attn_mqa.k_scale\n                                logger.warning(f"{name} not found in params_dict.")\n                                continue\n                            param = params_dict[name]\n                            weight_loader = getattr(\n                                param, "weight_loader", default_weight_loader\n                            )\n                            maybe_executor_submit(\n                                executor=executor,\n                                futures=futures,\n                                use_async=use_async_loading,\n                                func=weight_loader,\n                                func_args=(param, loaded_weight),\n                            )\n\n            # Wait for all tasks to complete and raise any exceptions.\n            for future in concurrent.futures.as_completed(futures):\n                future.result()\n\n        self.post_load_weights(is_nextn=is_nextn, weight_names=weight_names)\n\n    def _initialize_nextn_conf(self, is_nextn: bool) -> NextNConfig:\n        """\n        Initialize the nextn configuration.\n\n        Raises:\n            ValueError: If num_nextn_predict_layers is not in the config.\n            AssertionError: If num_nextn_predict_layers is not equal to 1.\n        """\n        if not is_nextn:\n            return NextNDisabledConfig()\n\n        if not hasattr(self.config, "num_nextn_predict_layers"):\n            raise ValueError("num_nextn_predict_layers is not in the config")\n\n        num_nextn_layers = self.config.num_nextn_predict_layers\n        assert num_nextn_layers == 1, "Only 1 nextn layer is supported"\n\n        # compatible with old design\n        nextn_layer_id = (\n            0 if self.config.num_hidden_layers == 1 else self.config.num_hidden_layers\n        )\n\n        return NextNEnabledConfig(\n            num_nextn_layers=num_nextn_layers,\n            nextn_layer_id=nextn_layer_id,\n            nextn_layer_prefix=f"model.layers.{nextn_layer_id}",\n            nextn_spec_weight_names=[\n                "shared_head.norm",\n                "eh_proj",\n                "enorm",\n                "hnorm",\n            ],\n        )\n\n    def post_load_weights(\n        self,\n        is_nextn: bool = False,\n        weight_names: Optional[Iterable[str]] = None,\n    ) -> None:\n        """Post-process weights after loading.\n\n        Handles kv_b_proj weight processing including:\n        - AWQ dequantization\n        - FP8/INT8 requantization and block-wise to tensor-wise conversion\n        - Splitting weights into w_kc and w_vc components for MLA\n\n        Args:\n            is_nextn: Whether processing NextN weights\n            weight_names: Optional list of loaded weight names to determine which layers to process\n        """\n        if is_nextn:\n            layer_ids = [self.config.num_hidden_layers]\n        else:\n            if weight_names is None:\n                layer_ids = range(self.model.start_layer, self.model.end_layer)\n            else:\n                layer_ids = set()\n                for name in weight_names:\n                    if "kv_b_proj" in name:\n                        layer_id = int(name.split(".")[2])\n                        if self.model.start_layer <= layer_id < self.model.end_layer:\n                            layer_ids.add(layer_id)\n\n        for layer_id in layer_ids:\n            self_attn = (\n                self.model.layers[layer_id].self_attn\n                if not is_nextn\n                else self.model.decoder.self_attn\n            )\n\n            if not hasattr(self_attn, "kv_b_proj"):\n                continue\n\n            if hasattr(self_attn.kv_b_proj, "qweight"):\n                # awq compatible, dequantize the weight if supported\n                if is_sail() and (\n                    self.quant_config.get_name()\n                    in [\n                        "gptq",\n                        "gptq_marlin",\n                    ]\n                    or (\n                        self.quant_config.get_name() == "moe_wna16"\n                        and self.quant_config.linear_quant_method == "gptq"\n                    )\n                ):\n                    w = None\n                    w = gptq_dequantize(\n                        self_attn.kv_b_proj.qweight,\n                        self_attn.kv_b_proj.scales,\n                        self_attn.kv_b_proj.qzeros,\n                    ).T\n                    assert w is not None\n                else:\n                    awq_dequantize_f = awq_dequantize_func()\n                    if awq_dequantize_f is not None:\n                        w = awq_dequantize_f(\n                            self_attn.kv_b_proj.qweight,\n                            self_attn.kv_b_proj.scales,\n                            self_attn.kv_b_proj.qzeros,\n                        ).T\n                    else:\n                        raise ValueError(\n                            "AWQ dequantize function is not supported for the current device"\n                        )\n            else:\n                w = self_attn.kv_b_proj.weight\n\n            # NOTE(HandH1998): Since `bmm_fp8` only supports per-tensor scale, we have to requantize `self_attn.kv_b_proj`.\n            # This may affect the accuracy of fp8 model.\n            # Fix deepseek v3 blockwise bmm by using deep_gemm\n            use_deep_gemm_bmm = False\n\n            if w.dtype in (\n                torch.float8_e4m3fn,\n                torch.float8_e4m3fnuz,\n            ):\n                # For mixed quantization (experts int4, linear fp8), use linear_fp8_config\n                selected_quant_config = getattr(\n                    self.quant_config, "linear_fp8_config", None\n                )\n                if selected_quant_config is None:\n                    selected_quant_config = self.quant_config\n                weight_block_size = (\n                    selected_quant_config.weight_block_size\n                    if selected_quant_config is not None\n                    else None\n                )\n                if weight_block_size is not None:\n                    assert hasattr(self_attn.kv_b_proj, "weight_scale_inv") or hasattr(\n                        self_attn.kv_b_proj, "weight_scale"\n                    )\n                    weight_scale = (\n                        self_attn.kv_b_proj.weight_scale\n                        if hasattr(self_attn.kv_b_proj, "weight_scale")\n                        else self_attn.kv_b_proj.weight_scale_inv\n                    )\n                    is_ue8m0_uint8 = (\n                        weight_scale.format_ue8m0 and weight_scale.dtype == torch.uint8\n                    )\n                    if _is_fp8_fnuz and not is_ue8m0_uint8:\n                        weight, weight_scale, _ = normalize_e4m3fn_to_e4m3fnuz(\n                            weight=w,\n                            weight_scale=weight_scale,\n                            input_scale=None,\n                        )\n                    else:\n                        weight = w\n\n                    # In multiple weight loading scenarios (e.g. RL), we need to inverse the scale of the weights after the requantization happened at the first loading.\n                    if is_ue8m0_uint8:\n                        weight_scale = (weight_scale.to(torch.int32) << 23).view(\n                            torch.float32\n                        )\n                    elif (\n                        should_deepgemm_weight_requant_ue8m0(\n                            weight_block_size=(\n                                self.quant_config.weight_block_size\n                                if self.quant_config is not None\n                                else None\n                            )\n                        )\n                        and weight_scale.format_ue8m0\n                    ):\n                        weight_scale = inverse_transform_scale_ue8m0(\n                            weight_scale, mn=weight.shape[-2]\n                        )\n\n                    if (\n                        (_is_cuda or _is_musa or _is_xpu)\n                        and weight_block_size[0] == 128\n                        and weight_block_size[1] == 128\n                    ):\n                        if (\n                            deep_gemm_wrapper.ENABLE_JIT_DEEPGEMM\n                            and not deep_gemm_wrapper.DEEPGEMM_BLACKWELL\n                            and get_bool_env_var("SGL_USE_DEEPGEMM_BMM", "false")\n                        ):\n                            block_scale = weight_scale\n                            use_deep_gemm_bmm = True\n                        else:\n                            w = block_quant_dequant(\n                                weight,\n                                weight_scale,\n                                weight_block_size,\n                                torch.bfloat16,\n                            )\n                    else:\n                        w, scale = block_quant_to_tensor_quant(\n                            weight, weight_scale, weight_block_size\n                        )\n                        self_attn.w_scale = scale\n                else:\n                    if _is_fp8_fnuz:\n                        weight, weight_scale, _ = normalize_e4m3fn_to_e4m3fnuz(\n                            weight=w,\n                            weight_scale=self_attn.kv_b_proj.weight_scale,\n                            input_scale=None,\n                        )\n                    else:\n                        weight = w\n                        weight_scale = self_attn.kv_b_proj.weight_scale\n                        # Per-channel scale is 1D [out]; reshape to [out, 1] so it\n                        # broadcasts correctly against weight [out, in].\n                        if weight_scale.dim() == 1:\n                            weight_scale = weight_scale.view(-1, 1)\n\n                    if _is_sail:\n                        # dequant channel-wise fp8 to bf16\n                        w = w.to(torch.bfloat16) * weight_scale.to(torch.bfloat16)\n                    else:\n                        w, scale = channel_quant_to_tensor_quant(weight, weight_scale)\n                        self_attn.w_scale = scale\n\n            if w.dtype == torch.int8:\n                # only enter block quant path when block size is not None\n                # otherwise will return non dequant weight in some mix-quant-config like w4a8\n                if getattr(self.quant_config, "weight_block_size", None) is not None:\n                    # block-wise int8 need it\n                    weight_block_size = self.quant_config.weight_block_size\n                    assert hasattr(self_attn.kv_b_proj, "weight_scale_inv")\n                    weight = w\n                    weight_scale = self_attn.kv_b_proj.weight_scale_inv\n                    w = int8_block_dequant(weight, weight_scale, weight_block_size).to(\n                        torch.bfloat16\n                    )\n                else:\n                    # channel-wise int8 need it\n                    w = w.to(torch.bfloat16) * self_attn.kv_b_proj.weight_scale.to(\n                        torch.bfloat16\n                    )\n\n            # GLM ships kv_b_proj as bf16, which falls back to torch.bmm. Quantize to\n            # per-tensor e4m3fn (not fnuz) to match forward_mla_rocm\'s dtype gate.\n            if (\n                _use_aiter_gfx95\n                and self.config.architectures\n                and self.config.architectures[0] == "GlmMoeDsaForCausalLM"\n                and w.dtype == torch.bfloat16\n            ):\n                w, self_attn.w_scale = input_to_float8(w, dtype=torch.float8_e4m3fn)\n\n            w_kc, w_vc = w.unflatten(\n                0, (-1, self_attn.qk_nope_head_dim + self_attn.v_head_dim)\n            ).split([self_attn.qk_nope_head_dim, self_attn.v_head_dim], dim=1)\n\n            if (\n                _use_aiter_gfx95\n                and self.quant_config is not None\n                and self.quant_config.get_name() == "quark"\n                and self.config.architectures\n                and self.config.architectures[0]\n                == "DeepseekV3ForCausalLM"  # Avoid processing other models like GlmMoeDsaForCausalLM\n                and w.dtype not in (torch.float8_e4m3fn, torch.float8_e4m3fnuz)\n            ):\n                w_kc, self_attn.w_scale_k, w_vc, self_attn.w_scale_v = (\n                    quark_post_load_weights(self_attn, w, "mxfp4")\n                )\n\n            if not use_deep_gemm_bmm:\n                self_attn.w_kc = bind_or_assign(\n                    self_attn.w_kc, w_kc.transpose(1, 2).contiguous().transpose(1, 2)\n                )\n                w_vc = w_vc.contiguous().transpose(1, 2)\n                if _is_npu:\n                    w_vc = w_vc.contiguous()\n                self_attn.w_vc = bind_or_assign(self_attn.w_vc, w_vc)\n                if (\n                    hasattr(self_attn.kv_b_proj, "weight_scale")\n                    and self_attn.w_scale is None\n                ):\n                    self_attn.w_scale = bind_or_assign(\n                        self_attn.w_scale, self_attn.kv_b_proj.weight_scale\n                    )\n                    if _is_hip:\n                        self_attn.w_scale *= 2.0\n                # XXX (MUSA): Remove this after adding FP8 support in bmm kernel on MUSA\n                if _is_musa and w.dtype == torch.float8_e4m3fn:\n                    self_attn.w_kc = (\n                        self_attn.w_kc.to(torch.bfloat16) * self_attn.w_scale\n                    )\n                    self_attn.w_vc = (\n                        self_attn.w_vc.to(torch.bfloat16) * self_attn.w_scale\n                    )\n            else:\n                num_tiles_k = self_attn.qk_nope_head_dim // weight_block_size[1]\n                num_tiles_n = self_attn.v_head_dim // weight_block_size[0]\n                ws_kc, ws_vc = block_scale.unflatten(\n                    0, (-1, (num_tiles_k + num_tiles_n))\n                ).split([num_tiles_k, num_tiles_n], dim=1)\n                self_attn.w_scale_k = bind_or_assign(\n                    self_attn.w_scale_k, ws_kc.transpose(1, 2).contiguous()\n                )\n                self_attn.w_scale_v = bind_or_assign(\n                    self_attn.w_scale_v, ws_vc.contiguous()\n                )\n                self_attn.w_kc = bind_or_assign(\n                    self_attn.w_kc, w_kc.transpose(1, 2).contiguous()\n                )\n                self_attn.w_vc = bind_or_assign(self_attn.w_vc, w_vc.contiguous())\n                self_attn.use_deep_gemm_bmm = True\n\n    @classmethod\n    def generate_weight_name_filter(cls, logical_experts_map: Dict[int, List[int]]):\n        """\n        Generates a filter function that tests whether the (layer_id, expert_id)\n        indicated by a param name lies in the `logical_experts` map\n        Args:\n            logical_experts_map: a map of layer_id to expert_ids, specifying a list of expert_ids by a specific layer_id.\n\n        Returns:\n            A function (name: str) -> bool\n        """\n        import re\n\n        # Regex pattern to extract layer_id and expert_id from weight name\n        pattern = re.compile(r"layers\\.(\\d+)\\.mlp\\.experts\\.(\\d+)\\.")\n\n        def weight_name_filter(name: str) -> bool:\n            match = pattern.search(name)\n            if match:\n                layer_id, expert = int(match.group(1)), int(match.group(2))\n                # First check if layer_id exists, then check if expert is in the list\n                return (\n                    layer_id in logical_experts_map\n                    and expert in logical_experts_map[layer_id]\n                )\n            return False\n\n        return weight_name_filter\n\n    def _maybe_quant_weights_to_fp8_ue8m0(\n        self,\n        weights,\n        attn_quant_modules,\n        nextn_conf: NextNConfig,\n    ):\n        """Optionally quantize weights to FP8 UE8M0 format for DeepSeek nvfp4 checkpoints.\n\n        Args:\n            weights: Iterable of (name, tensor) weight pairs\n            attn_quant_modules: List of attention module names to quantize\n            nextn_conf: NextN configuration\n\n        Returns:\n            Original weights iterator if no quantization needed,\n            otherwise list of (name, tensor) pairs with quantized weights\n        """\n        weight_block_size = [128, 128]\n        partial_names = []\n\n        match nextn_conf:\n            case NextNEnabledConfig(nextn_layer_id=layer_id):\n                if envs.SGLANG_NVFP4_CKPT_FP8_GEMM_IN_ATTN.get():\n                    for stem in attn_quant_modules:\n                        partial_names.append(\n                            f"model.layers.{layer_id}.self_attn.{stem}"\n                        )\n\n                if enable_nextn_moe_bf16_cast_to_fp8(self.quant_config):\n                    expert_sub_names = ["shared_experts"] + [\n                        f"experts.{i}" for i in range(self.config.n_routed_experts)\n                    ]\n                    for expert_sub_name in expert_sub_names:\n                        for stem in ["gate_proj", "up_proj", "down_proj"]:\n                            partial_names.append(\n                                f"model.layers.{layer_id}.mlp.{expert_sub_name}.{stem}"\n                            )\n\n            case NextNDisabledConfig():\n                if envs.SGLANG_NVFP4_CKPT_FP8_GEMM_IN_ATTN.get():\n                    for layer_id in range(self.config.num_hidden_layers):\n                        for stem in attn_quant_modules:\n                            partial_names.append(\n                                f"model.layers.{layer_id}.self_attn.{stem}"\n                            )\n\n        # Early return if no quantization needed - avoid materializing all weights into memory\n        if not partial_names:\n            return weights\n\n        # Only materialize weights dict when quantization is actually needed\n        weights_dict = dict(weights)\n\n        for partial_name in tqdm.tqdm(partial_names, desc="quant weights to fp8 ue8m0"):\n            original_weight = weights_dict[f"{partial_name}.weight"]\n            out_w, out_s = quant_weight_ue8m0(\n                original_weight, weight_block_size=weight_block_size\n            )\n            weights_dict[f"{partial_name}.weight"] = out_w\n            weights_dict[f"{partial_name}.weight_scale_inv"] = out_s\n\n        if isinstance(\n            nextn_conf, NextNEnabledConfig\n        ) and enable_nextn_moe_bf16_cast_to_fp8(self.quant_config):\n            self._mark_nextn_moe_weights_as_ue8m0()\n\n        return list(weights_dict.items())\n\n    def _mark_nextn_moe_weights_as_ue8m0(self):\n        """Mark NextN MoE weight scales as UE8M0 format to avoid requantization."""\n        experts = self.model.decoder.mlp.experts\n        w13_scale = (\n            experts.w13_weight_scale_inv\n            if hasattr(experts, "w13_weight_scale_inv")\n            else experts.w13_weight_scale\n        )\n        w2_scale = (\n            experts.w2_weight_scale_inv\n            if hasattr(experts, "w2_weight_scale_inv")\n            else experts.w2_weight_scale\n        )\n        w13_scale.format_ue8m0 = True\n        w2_scale.format_ue8m0 = True\n'


def resolve(path, solutions):
    p = f"{ROOT}/{path}"
    lines = open(p).read().splitlines(keepends=True)
    spans = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("<<<<<<<"):
            s = i
            mid = next(j for j in range(i, len(lines)) if lines[j].startswith("======="))
            e = next(j for j in range(mid, len(lines)) if lines[j].startswith(">>>>>>>"))
            spans.append((s, e + 1))
            i = e + 1
        else:
            i += 1
    assert len(spans) == len(solutions), f"{path}: {len(spans)} blocks, expected {len(solutions)}"
    out = []
    idx = 0
    for (s, e), sol in zip(spans, solutions):
        out.extend(lines[idx:s])
        out.extend(sol.splitlines(keepends=True))
        idx = e
    out.extend(lines[idx:])
    open(p, "w").write("".join(out))
    print(f"OK {path}: {len(spans)} blocks resolved")


def main():
    for path, sols in SOLS.items():
        if sols is None:
            p = f"{ROOT}/{path}"
            open(p, "w").write(WHOLE)
            print(f"OK {path}: whole-file rewritten")
        else:
            resolve(path, sols)
    bad = [f for f, exp in EXPECT_MD5.items()
           if hashlib.md5(open(f"{ROOT}/{f}", "rb").read()).hexdigest() != exp]
    assert not bad, f"resolved md5 mismatch: {bad}"
    print("MD5-OK: 7 files match verified merge tree 8aeeb355a4")


if __name__ == "__main__":
    main()
PYEOF

PORTMERGE_ROOT=$WT/python/sglang python3 "$WORKDIR/resolve_conflicts_v013.py"

# syntax check for the 7 files (the local python may predate the source
# syntax: an ours-original parse failure is an environment limitation, but
# an original that parses while the merged file fails is a merge-introduced
# syntax break)
SAIL_COMMIT_REF="$OURS_COMMIT" python3 - <<'PYAST'
import ast, os, subprocess
base = "python/sglang/"
files = [
    "srt/layers/attention/dsa/dsa_indexer.py",
    "srt/layers/attention/dsa/dsa_topk_backend.py",
    "srt/layers/linear.py",
    "srt/layers/quantization/mxfp4.py",
    "srt/model_executor/model_runner.py",
    "srt/models/deepseek_common/deepseek_weight_loader.py",
    "srt/models/kimi_k3.py",
]
ref = os.environ["SAIL_COMMIT_REF"]
ok, skip = 0, 0
for f in files:
    try:
        ast.parse(open(base + f).read())
        ok += 1
    except SyntaxError:
        orig = subprocess.run(["git", "show", f"{ref}:{base}{f}"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True)
        try:
            ast.parse(orig.stdout)
            print(f"AST-FAIL (merge-introduced): {f}")
            raise SystemExit(1)
        except SyntaxError:
            skip += 1
            print(f"AST-SKIP (pre-existing env limitation): {f}")
print(f"AST-OK: {ok} files parsed, {skip} skipped (env limitation)")
PYAST

# ============================================================================
# Phase 5: merge commit + decisive tree hash assert
# ============================================================================
git add -A
git commit -q -m "Merge sglang-miles 3a938213c1 (v0.1.3 runtime-port) into sglang-for-sail release/v0.5.22"

TREE=$(git rev-parse "HEAD^{tree}")
if [ -n "$MERGE_TREE_EXPECT" ]; then
    [ "$TREE" = "$MERGE_TREE_EXPECT" ] \
        || die "merge tree mismatch: got $TREE, expected $MERGE_TREE_EXPECT"
    echo "   merge tree: $TREE == expected (decisive byte-level assert PASSED)"
else
    echo "   merge tree (probe mode, pin this as MERGE_TREE_EXPECT): $TREE"
fi

# ============================================================================
# Phase 6: merge patch export
# ============================================================================
MERGE_OUT=$OUT_DIR/$MERGE_NAME
git diff "$OURS_COMMIT"..HEAD -- python/sglang/ > "$MERGE_OUT"
MERGE_STAT=$(git diff --shortstat "$OURS_COMMIT"..HEAD -- python/sglang/)
MERGE_FILES=$(git diff --name-only "$OURS_COMMIT"..HEAD -- python/sglang/ | wc -l)
if [ -n "${MERGE_STAT_EXPECT:-}" ] && [ -n "${MERGE_FILES_EXPECT:-}" ]; then
    echo "$MERGE_STAT" | grep -F "$MERGE_STAT_EXPECT" >/dev/null \
        || die "merge patch stat drift: $MERGE_STAT (expected $MERGE_STAT_EXPECT)"
    [ "$MERGE_FILES" = "$MERGE_FILES_EXPECT" ] \
        || die "merge patch files=$MERGE_FILES, expected $MERGE_FILES_EXPECT"
    echo "   merge patch: $MERGE_STAT (assert PASSED) -> $MERGE_OUT"
else
    echo "   merge patch (probe mode): $MERGE_STAT / files=$MERGE_FILES -> $MERGE_OUT"
fi

if [ -n "$REF_DIR" ] && [ -f "$REF_DIR/$MERGE_NAME" ]; then
    cmp -s "$MERGE_OUT" "$REF_DIR/$MERGE_NAME" \
        && echo "   merge patch: BYTE-IDENTICAL to reference" \
        || die "merge patch differs from $REF_DIR/$MERGE_NAME"
fi

# ============================================================================
# Phase 7: apply-check on the clean baseline
# ============================================================================
if [ "$APPLY_CHECK" = "1" ]; then
    WT_CHECK=$WORKDIR/applycheck-wt
    git worktree remove --force "$WT_CHECK" 2>/dev/null || true
    git worktree prune
    git worktree add --detach "$WT_CHECK" "$OURS_COMMIT" >/dev/null
    git -C "$WT_CHECK" apply --check "$MERGE_OUT" \
        && echo "   apply-check: PASS (clean apply to sglang-for-sail $SAIL_BRANCH @ $OURS_COMMIT)" \
        || die "apply-check FAILED on clean sglang-for-sail baseline"
    git worktree remove --force "$WT_CHECK"
    git worktree prune
fi

if [ "$CLEANUP" = "1" ]; then
    cd "$REPO" 2>/dev/null || true
    git worktree remove --force "$WT" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    rm -rf "$WORKDIR"
    echo "   workdir cleaned (CLEANUP=1)"
fi

echo "== DONE =="
echo "   raw   : $RAW_OUT"
echo "   merge : $MERGE_OUT"
if [ "$CLEANUP" != "1" ]; then
    echo "   worktree (kept for inspection): $WT"
fi
