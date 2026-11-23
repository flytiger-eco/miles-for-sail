#!/bin/bash
# Copyright © 2026 Zhejiang Runhe Cloud Intelligence Technology Co., Ltd

# =============================================================================
# gen_runtime_port_merge_v012.sh -- fully automated regeneration of the
# miles-sail v0.1.2 runtime-port patch (self-contained: needs only git,
# python3 and public github access).
#
# Phases: 1 fetch three refs + topology asserts  2 raw patch (v0.5.21..miles)
#   3 three-way merge on sglang-for-sail tag 0.5.21+v0.1.0  4 resolve the 13
#   conflict blocks  5 merge-tree hash assert  6 export the merge patch
#   7 apply-check on the clean baseline
# Refs: base = sglang v0.5.21 e00930c5 / theirs = sglang-miles b84bec57 /
#   ours = sglang-for-sail tag 0.5.21+v0.1.0 @ 9bb44378 (versioned release pin)
# Env (optional): WORKDIR / OUT_DIR / REF_DIR / GH_PROXY (git fetch/clone proxy)
#   MERGE_TREE_EXPECT (empty = probe mode) / APPLY_CHECK (default 1) /
#   CLEANUP (default 0; set to 1 in the docker build layer)
# Outputs: $OUT_DIR/sglang-0001-miles-v0.1.2-runtime-port.patch (raw)
#          $OUT_DIR/sglang-0001-miles-v0.1.2-runtime-port-ppu-merge.patch
# =============================================================================
set -euo pipefail

# ---------- pinned refs (v0.1.2, equivalent of release-lock + merge tree d457c50b) ----------
V521_COMMIT=e00930c5489053f26d86b179cee0d087f846acbb
MILES_COMMIT=b84bec5761a6cdc8b1df86b9b89ead80a7a9bb02
UPSTREAM_REPO=https://github.com/sgl-project/sglang.git
SAIL_REPO=https://github.com/flytiger-eco/sglang-for-sail.git
# ours = the versioned release tag (naming: <sglang ver>+<port ver>): the
# v0.5.21 branch HEAD keeps moving, which changes the merge tree and forces a
# manual conflict re-review, so the tag is pinned as the stable release point.
SAIL_TAG=0.5.21+v0.1.0
SAIL_TAG_COMMIT=9bb44378927e89ec1c4fff3824e0eb31acd7f8d5
MERGE_BRANCH=port/sglang-miles-v0.5.21-v0.1.2
# decisive merge-tree assert (measured on tag 0.5.21+v0.1.0 @ 9bb44378; the
# value must change when the ours baseline moves).
MERGE_TREE_EXPECT=${MERGE_TREE_EXPECT:-bf73b2474cac6a86c602eddc44e1ff67d18deac0}
MERGE_STAT_EXPECT=${MERGE_STAT_EXPECT:-176 files changed, 8550 insertions(+), 1904 deletions(-)}
MERGE_FILES_EXPECT=${MERGE_FILES_EXPECT:-176}

# fetch depth must cover every commit ahead of the v0.5.21 tag (174 for
# sglang-for-sail, 37 for miles), else a shallow cut empties merge-base.
MILES_FETCH_DEPTH=60
SAIL_FETCH_DEPTH=250

RAW_NAME=sglang-0001-miles-v0.1.2-runtime-port.patch
MERGE_NAME=sglang-0001-miles-v0.1.2-runtime-port-ppu-merge.patch

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKDIR=${WORKDIR:-/tmp/portmerge-v012-gen}
OUT_DIR=${OUT_DIR:-$SCRIPT_DIR/../patches}
REF_DIR=${REF_DIR:-}
APPLY_CHECK=${APPLY_CHECK:-1}
CLEANUP=${CLEANUP:-0}

# public https: under MITM proxies inject it via GH_PROXY (git fetch/clone only)
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
echo "== gen_runtime_port_merge_v012 =="
echo "   WORKDIR=$WORKDIR  OUT_DIR=$OUT_DIR  REF_DIR=${REF_DIR:-<none>}"

# ============================================================================
# Phase 1: fresh clone + three-ref fetch + topology asserts
# ============================================================================
REPO=$WORKDIR/sglang.git
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# clone gets its own retry loop (not fetch_retry): a GnuTLS drop can leave a
# half-cloned dir behind; clear it before each retry or the next clone fails.
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
fetch_retry "fetch v0.5.21 tag" \
    "${GIT_NET[@]}" fetch --depth 1 origin tag v0.5.21
fetch_retry "fetch sglang-for-sail tag $SAIL_TAG (depth $SAIL_FETCH_DEPTH)" \
    "${GIT_NET[@]}" fetch --depth "$SAIL_FETCH_DEPTH" sglang-for-sail "tag" "$SAIL_TAG"

V=$(git rev-parse "v0.5.21^{commit}")
[ "$V" = "$V521_COMMIT" ] || die "v0.5.21 tag moved: $V != $V521_COMMIT"
git cat-file -e "$MILES_COMMIT^{commit}" || die "miles commit $MILES_COMMIT not fetched"
# ours defaults to the versioned release tag (tag moves are caught by the
# rev-parse assert above); SAIL_COMMIT is an explicit override that must be
# reachable in the fetched history (the Dockerfile passes SAIL_PIN too).
OURS_COMMIT=$(git rev-parse "${SAIL_TAG}^{commit}")
[ "$OURS_COMMIT" = "$SAIL_TAG_COMMIT" ] \
    || die "sglang-for-sail tag $SAIL_TAG moved: $OURS_COMMIT != $SAIL_TAG_COMMIT (retag detected -- review & re-pin)"
if [ -n "${SAIL_COMMIT:-}" ] && [ "$SAIL_COMMIT" != "$OURS_COMMIT" ]; then
    git cat-file -e "${SAIL_COMMIT}^{commit}" 2>/dev/null \
        || die "sglang-for-sail pin commit $SAIL_COMMIT not in fetched history (raise SAIL_FETCH_DEPTH)"
    OURS_COMMIT="$SAIL_COMMIT"
    echo "   ours = sglang-for-sail OVERRIDE @ $OURS_COMMIT (tag $SAIL_TAG ignored)"
else
    echo "   ours = sglang-for-sail tag $SAIL_TAG @ $OURS_COMMIT (versioned release pin)"
fi

MB=$(git merge-base "$OURS_COMMIT" "$MILES_COMMIT" || true)
[ "$MB" = "$V521_COMMIT" ] || die "merge-base($OURS_COMMIT, $MILES_COMMIT)=$MB, expected $V521_COMMIT (shallow cut or sglang-for-sail rebased? raise SAIL_FETCH_DEPTH)"
echo "   topology OK: base=$MB miles=+$(git rev-list --count $V521_COMMIT..$MILES_COMMIT) sglang-for-sail=+$(git rev-list --count $V521_COMMIT..$OURS_COMMIT)"

# ============================================================================
# Phase 2: raw patch (git diff v0.5.21..b84bec57 -- python/sglang/)
# ============================================================================
RAW_OUT=$OUT_DIR/$RAW_NAME
git diff "$V521_COMMIT" "$MILES_COMMIT" -- python/sglang/ > "$RAW_OUT"
RAW_STAT=$(git diff --shortstat "$V521_COMMIT" "$MILES_COMMIT" -- python/sglang/)
echo "$RAW_STAT" | grep -F "176 files changed, 8536 insertions(+), 1902 deletions(-)" >/dev/null \
    || die "raw patch stat drift: $RAW_STAT"
RAW_FILES=$(git diff --name-only "$V521_COMMIT" "$MILES_COMMIT" -- python/sglang/ | wc -l)
[ "$RAW_FILES" = "176" ] || die "raw patch files=$RAW_FILES, expected 176"
echo "   raw patch: $RAW_STAT -> $RAW_OUT"

if [ -n "$REF_DIR" ] && [ -f "$REF_DIR/$RAW_NAME" ]; then
    cmp -s "$RAW_OUT" "$REF_DIR/$RAW_NAME" \
        && echo "   raw patch: BYTE-IDENTICAL to reference" \
        || die "raw patch differs from $REF_DIR/$RAW_NAME"
fi

# ============================================================================
# Phase 3: three-way merge (worktree @ sglang-for-sail v0.5.21 baseline + merge miles)
# ============================================================================
WT=$WORKDIR/portmerge-wt
git worktree prune 2>/dev/null || true
git worktree add --detach "$WT" "$OURS_COMMIT" >/dev/null
cd "$WT"

# committer identity must be configured before MERGE (repo-local; the worktree
# shares the main repo config); git merge --no-commit still prepares the merge
# commit and dies with exit 128 without an identity.
git config user.name "miles-sail-build"
git config user.email "miles-sail-build@users.noreply.github.com"

git checkout -q -b "$MERGE_BRANCH"

# merge exit codes: 1 = conflict (expected); 0/other = unexpected (0 is caught
# by the conflict-set assert below; others are env fatals -- fail loudly).
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
python/sglang/srt/models/deepseek_nextn.py
python/sglang/srt/models/glm4_moe_nextn.py
python/sglang/srt/models/kimi_k3.py"
if [ "$CONFLICTS" != "$EXPECTED_CONFLICTS" ]; then
    echo "== conflict set mismatch ==" >&2
    diff <(echo "$EXPECTED_CONFLICTS") <(echo "$CONFLICTS") >&2 || true
    die "expected 8 conflict files, got $CONFLICT_COUNT (refs drifted?)"
fi
echo "   merge conflicts: $CONFLICT_COUNT files / 13 blocks (as expected)"

# ============================================================================
# Phase 4: conflict resolution (embedded resolver, per-file block replacement, keep both sides)
# ============================================================================
cat > "$WORKDIR/resolve_conflicts_v012.py" <<'PYEOF'
#!/usr/bin/env python3
"""Resolve the 13 conflict blocks of the v0.1.2 three-way merge (keep both
sides). ours = sglang-for-sail tag 0.5.21+v0.1.0 @ 9bb44378 (release pin),
theirs = sglang-miles b84bec57 (v0.5.21 + 37 commits). Embedded deployment:
ROOT comes from the PORTMERGE_ROOT env var; otherwise identical to the
standalone resolver."""
import os
import sys

ROOT = os.environ.get("PORTMERGE_ROOT", "/tmp/portmerge-v012/python/sglang")


def resolve(path, solutions):
    with open(path) as f:
        lines = f.readlines()
    out, idx, i = [], 0, 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.startswith("<<<<<<< HEAD"):
            j = i + 1
            while j < n and not lines[j].startswith("======="):
                j += 1
            assert j < n, f"{path} block{idx}: no ======="
            j += 1
            while j < n and not lines[j].startswith(">>>>>>>"):
                j += 1
            assert j < n, f"{path} block{idx}: no >>>>>>>"
            j += 1
            out.append(solutions[idx])
            idx += 1
            i = j
        else:
            out.append(line)
            i += 1
    assert idx == len(solutions), f"{path}: {idx} blocks, expected {len(solutions)}"
    rem = [l for l in out if l.startswith(("<<<<<<<", "=======", ">>>>>>>"))]
    assert not rem, f"{path}: markers remain: {rem[:3]}"
    with open(path, "w") as f:
        f.writelines(out)
    print(f"OK {path}: {idx} blocks resolved")


# ============ dsa_indexer.py (4 blocks) ============

DSA_B1 = """
            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).
            if _enable_logits_nan_check:
                _check_logits_nan_in_valid_range(logits, ks, ke)
            if capture:
                transformed, raw = metadata.topk_transform(
                    logits, self.index_topk, ks=ks, return_raw_indices=True
                )
                topk_result[:q_offset] = transformed
                raw_result[:q_offset] = raw
            else:
                topk_result[:q_offset] = metadata.topk_transform(
                    logits, self.index_topk, ks=ks
                )
            return topk_result, raw_result
"""

DSA_B2 = """
            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).
            if _enable_logits_nan_check:
                _check_logits_nan_in_valid_range(
                    logits_chunk, ks[start:end], ke[start:end], row_offset=start
                )

            if capture:
                transformed, raw = metadata.topk_transform(
                    logits_chunk,
                    self.index_topk,
                    ks=ks[start:end],
                    cu_seqlens_q=cu_seqlens_q_chunk,
                    ke_offset=lengths_chunk,
                    batch_idx_list=batch_idx_chunk,
                    topk_indices_offset_override=topk_offset_chunk,
                    return_raw_indices=True,
                )
                topk_result[start:end] = transformed
                raw_result[start:end] = raw
            else:
                topk_result[start:end] = metadata.topk_transform(
                    logits_chunk,
                    self.index_topk,
                    ks=ks[start:end],
                    cu_seqlens_q=cu_seqlens_q_chunk,
                    ke_offset=lengths_chunk,
                    batch_idx_list=batch_idx_chunk,
                    topk_indices_offset_override=topk_offset_chunk,
                )
"""

DSA_B3 = """
            #! <Note>[phh]:In PR#19148 of the sglang community, a new fusion Kernel has been
            # added to perform quantization and storage Index_k together .
            # However, for BF16_INDEXER, set_index_k_scale_buffer is still required
            if self.bf16_indexer or self.use_int8:
                # k_fp8: (seq_len, head_dim) fp8_e4m3fn
                # k_buffer: (num_total_tokens + page_size, head_dim) fp8_e4m3fn
                # k_scale: (seq_len, head_dim // block_size = 1) fp8_e4m3fn
                # k_scale_cache: (num_total_tokens + page_size, head_dim // block_size = 1) fp8_e4m3fn
                if not forward_batch.out_cache_loc.is_contiguous():
                    forward_batch.out_cache_loc = (
                        forward_batch.out_cache_loc.contiguous()
                    )
                get_token_to_kv_pool().set_index_k_scale_buffer(
                    layer_id=layer_id,
                    loc=forward_batch.out_cache_loc,
                    index_k=k_fp8,
                    index_k_scale=k_scale,
                )

        raw_result = None
"""

DSA_B4 = """
                if (
                    forward_batch.attn_cp_metadata is not None
                    and is_dsa_prefill_cp_in_seq_split()
                ):
                    kv_len_prev = forward_batch.attn_cp_metadata.kv_len_prev_list[0]
                    kv_len_next = forward_batch.attn_cp_metadata.kv_len_next_list[0]
                    actual_seq_q_prev = (
                        forward_batch.attn_cp_metadata.actual_seq_q_prev_list[0]
                    )
                    actual_seq_q_next = (
                        forward_batch.attn_cp_metadata.actual_seq_q_next_list[0]
                    )

                    # TODO support mutil-batch
                    # cp_batch_seq_index_prev = forward_batch.attn_cp_metadata["cp_batch_seq_index_prev"]
                    # cp_batch_seq_index_next = forward_batch.attn_cp_metadata["cp_batch_seq_index_next"]
                    # TODO prev, next, combined into a single call
                    if self.use_fp4:
                        # FP4: q_fp8 is (q_packed, q_sf) tuple; split both components
                        q_packed, q_sf = q_fp8
                        q_packed_prev, q_packed_next = torch.split(
                            q_packed, (q_packed.shape[0] + 1) // 2, dim=0
                        )
                        q_sf_prev, q_sf_next = torch.split(
                            q_sf, (q_sf.shape[0] + 1) // 2, dim=0
                        )
                        q_fp8_prev = (q_packed_prev, q_sf_prev)
                        q_fp8_next = (q_packed_next, q_sf_next)
                    else:
                        q_fp8_prev, q_fp8_next = torch.split(
                            q_fp8, (q_fp8.shape[0] + 1) // 2, dim=0
                        )
                    weights_prev, weights_next = torch.split(
                        weights, (weights.shape[0] + 1) // 2, dim=0
                    )
                    topk_result_prev = self._get_topk_ragged_with_cp(
                        forward_batch,
                        layer_id,
                        q_fp8_prev,
                        weights_prev,
                        metadata,
                        kv_len_prev,
                        actual_seq_q_prev,
                    )

                    topk_result_next = self._get_topk_ragged_with_cp(
                        forward_batch,
                        layer_id,
                        q_fp8_next,
                        weights_next,
                        metadata,
                        kv_len_next,
                        actual_seq_q_next,
                    )
                    topk_result = torch.cat([topk_result_prev, topk_result_next], dim=0)
                    topk_result = _broadcast_indexer_topk_from_rank0(topk_result)
                    return self._capture_and_return(layer_id, topk_result, None)
                else:
                    # In-graph (PCG/BCG) non-CP prefill is handled earlier by the
                    # graph DSA split-op dispatch, so only the eager path reaches
                    # here.
                    assert not in_piecewise_or_breakable_cuda_graph, (
                        "Internal error: in-graph DSA prefill must go through the "
                        "graph DSA split-op dispatch"
                    )
                    topk_result, raw_result = self._get_topk_ragged(
                        enable_dual_stream,
                        forward_batch,
                        layer_id,
                        q_fp8,
                        weights,
                        metadata,
                    )
"""

# ============ dsa_topk_backend.py (1 block) ============

TOPK_B1 = """
                # Route PAGED path through dsv4's bf16 topk kernel when gate is on
                # and logits are bf16; falls back to fast_topk_transform_fused otherwise.
                if (
                    envs.SGLANG_DSA_USE_DSV4_BF16_TOPK.get()
                    and logits.dtype == torch.bfloat16
                ):
                    result = self._topk_transform_dsv4_bf16(
                        logits=logits,
                        seq_lens_topk=lengths,
                        page_table_size_1=page_table_size_1,
                        cu_seqlens_q_topk=cu_seqlens_q_topk,
                        topk=topk,
                        ks=row_starts,
                    )
                    return (result, raw_indices) if return_raw_indices else result
                result = fast_topk_transform_fused(
"""

# ============ glm4_moe_nextn.py (1 block) ============

GLM_B1 = """from sglang.srt.models.utils import WeightsMapper
from sglang.srt.runtime_context import get_exec, get_parallel, get_spec
"""

# ============ model_runner.py (2 blocks) ============

MR_B1 = """
                if SGLANG_PROFILE_NVTX:
                    th_nvtx_range_pop()
                return ModelRunnerOutput(
                    logits_output=ret,
                    can_run_graph=can_run_graph,
                    graph_num_tokens=self.decode_cuda_graph_runner.bs
                    * self.decode_cuda_graph_runner.captured_req_width,
                )
"""

MR_B2 = """
            if SGLANG_PROFILE_NVTX:
                th_nvtx_range_pop()

            return ModelRunnerOutput(
                logits_output=ret,
                can_run_graph=can_run_graph,
                graph_num_tokens=graph_num_tokens,
            )
"""

# ============ linear.py (1 block) ============

LIN_B1 = """
            if SGLANG_PROFILE_NVTX:
                tmp_weight = getattr(self, "weight", None)
                nvtx_push_range_for_gemm(
                    "RowParallelLinear", input_parallel, tmp_weight, None, None, bias_
                )
            from sglang.srt.layers.quantization.fp8 import Fp8LinearMethod

            is_tuple = isinstance(input_parallel, tuple)
            is_fp8 = isinstance(self.quant_method, Fp8LinearMethod)
            k_size = (
                input_parallel[0].shape[-1] if is_tuple else input_parallel.shape[-1]
            )
            if should_use_tp_invariant_row_linear(k_size):
                if output_tensor is not None:
                    raise RuntimeError(
                        "tp-invariant row linear cannot write into a caller-owned "
                        "output tensor"
                    )
                if is_fp8:
                    raise NotImplementedError(
                        "FP8 tp-invariant row-linear not yet supported"
                    )
                output_parallel = torch.ops.tp_inv_ops.matmul_tp_inv(
                    input_parallel, self.weight.t(), bias_
                )
            elif output_tensor is None:
"""

# ============ mxfp4.py (1 block) ============

MXFP4_B1 = """
                deinterleave_moe_mxfp4_w13_for_marlin(
                    layer, reuse_parameter_storage=reuse_parameter_storage
                )
            prepare_moe_mxfp4_layer_for_marlin(
                layer, reuse_parameter_storage=reuse_parameter_storage
            )
            runtime_specs = {
                name: (tuple(getattr(layer, name).shape), getattr(layer, name).dtype)
                for name in self._marlin_parameter_names(layer)
            }
            if reuse_parameter_storage:
                if runtime_specs != layer._mxfp4_marlin_runtime_parameter_specs:
                    raise ValueError(
                        "MXFP4 Marlin in-place reload changed the runtime layout: "
                        f"{runtime_specs} vs {layer._mxfp4_marlin_runtime_parameter_specs}."
                    )
            else:
                layer._mxfp4_marlin_runtime_parameter_specs = runtime_specs
            layer._mxfp4_marlin_reload_in_place = False
            if _is_ppu and self.use_deepgemm_mxfp4_w4a16_valu:
                # DeepGEMM uses uint8 E8M0 scales to select its MXFP4/E2M1 path.
                for scale_name in ("w13_weight_scale", "w2_weight_scale"):
                    scale = getattr(layer, scale_name)
                    setattr(
                        layer,
                        scale_name,
                        Parameter(scale.view(torch.uint8), requires_grad=False),
                    )
                del scale
                # Release stale loader tensors and Marlin conversion buffers
                # before KV-cache sizing measures available device memory.
                torch.cuda.empty_cache()
"""

# ============ kimi_k3.py (2 blocks) ============

K3_B1 = """
            # Only plain bf16/fp16 dense weights are merged: quantized or
            # mixed-dtype checkpoints keep the unfused path so the
            # quant_method (scales, packed layouts, etc.) is respected.
            dtypes = {m.weight.dtype for m in [*mods, self.f_b_proj]}
            if len(dtypes) != 1 or next(iter(dtypes)) not in (
                torch.bfloat16,
                torch.float16,
            ):
                return
            self._bfa_w, sizes = _merge_weights_as_views(
                mods, pad_rows_to=pad_rows_to, merged=self._bfa_w
            )
            # .data: a second Parameter registration hides f_b_proj.weight from named_parameters()
            self._bfa_f_b_w = self.f_b_proj.weight.data
        self._bfa_fa_size, self._bfa_b_size = sizes[-2:]
"""

K3_B2 = """
    # Fused runtime module -> checkpoint shard names, so quant configs can
    # match fused prefixes against per-shard exclude_modules
    packed_modules_mapping = {
        "fused_qkv_a_proj_with_mqa": ["q_a_proj", "kv_a_proj_with_mqa"],
        "gate_up_proj": ["gate_proj", "up_proj"],
        "qkv_proj": ["q_proj", "k_proj", "v_proj"],
        "qkv_conv1d": ["q_conv1d", "k_conv1d", "v_conv1d"],
        "fused_qkvg_proj": ["q_proj", "k_proj", "v_proj", "g_proj"],
        "fused_qkvbfg_a_proj": [
            "q_proj",
            "k_proj",
            "v_proj",
            "b_proj",
            "f_a_proj",
            "g_a_proj",
        ],
        "fused_fg_b_proj": ["f_b_proj", "g_b_proj"],
    }

    @staticmethod
    def get_lora_target_module_name(name: str) -> str:
        parent, _, leaf = name.rpartition(".")
        if ".experts" in parent:
            return {"w1": "gate_proj", "w2": "down_proj", "w3": "up_proj"}.get(
                leaf, name
            )
        return name
"""

# ============ deepseek_nextn.py (1 block, v2 addition: sglang-for-sail DSA CP vs miles loader) ============

DSNEXTN_B1 = """
        self.use_dsa = is_deepseek_dsa(config)
        self.dsa_enable_prefill_cp = is_dsa_enable_prefill_cp()
        if self.dsa_enable_prefill_cp:
            self.cp_rank = get_parallel().attn_cp_rank
            self.cp_size = get_parallel().attn_cp_size
        else:
            self.cp_rank = None
            self.cp_size = None
        self.init_unified_loader_mappings()
"""


def main():
    resolve(f"{ROOT}/srt/models/deepseek_nextn.py", [DSNEXTN_B1])
    resolve(f"{ROOT}/srt/layers/attention/dsa/dsa_indexer.py", [DSA_B1, DSA_B2, DSA_B3, DSA_B4])
    resolve(f"{ROOT}/srt/layers/attention/dsa/dsa_topk_backend.py", [TOPK_B1])
    resolve(f"{ROOT}/srt/models/glm4_moe_nextn.py", [GLM_B1])
    resolve(f"{ROOT}/srt/model_executor/model_runner.py", [MR_B1, MR_B2])
    resolve(f"{ROOT}/srt/layers/linear.py", [LIN_B1])
    resolve(f"{ROOT}/srt/layers/quantization/mxfp4.py", [MXFP4_B1])
    resolve(f"{ROOT}/srt/models/kimi_k3.py", [K3_B1, K3_B2])
    print("ALL RESOLVED: 8 files, 13 blocks")


if __name__ == "__main__":
    main()
PYEOF

PORTMERGE_ROOT=$WT/python/sglang python3 "$WORKDIR/resolve_conflicts_v012.py"

# syntax check of the 8 files (ast.parse all green, as in the OP-06 flow)
SAIL_OURS_REF="$SAIL_TAG" python3 - <<'PYAST'
import ast, os, subprocess
base = "python/sglang/"
files = [
    "srt/layers/attention/dsa/dsa_indexer.py",
    "srt/layers/attention/dsa/dsa_topk_backend.py",
    "srt/models/deepseek_nextn.py",
    "srt/models/glm4_moe_nextn.py",
    "srt/model_executor/model_runner.py",
    "srt/layers/linear.py",
    "srt/layers/quantization/mxfp4.py",
    "srt/models/kimi_k3.py",
]
ref = os.environ["SAIL_OURS_REF"]
ok, skip = 0, 0
for f in files:
    try:
        ast.parse(open(base + f).read())
        ok += 1
    except SyntaxError:
        # The local python may predate the source syntax (e.g. 3.12 nested
        # f-string quotes): if the ours original also fails to parse it is a
        # pre-existing env limitation (skip); merge-introduced breaks die.
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
# (committer identity was configured before the Phase 3 merge)
git add -A
git commit -q -m "Merge sglang-miles b84bec57 (v0.1.2 runtime-port) into sglang-for-sail 0.5.21+v0.1.0"

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
    echo "   pin as MERGE_STAT_EXPECT / MERGE_FILES_EXPECT after review"
fi

if [ -n "$REF_DIR" ] && [ -f "$REF_DIR/$MERGE_NAME" ]; then
    cmp -s "$MERGE_OUT" "$REF_DIR/$MERGE_NAME" \
        && echo "   merge patch: BYTE-IDENTICAL to reference" \
        || die "merge patch differs from $REF_DIR/$MERGE_NAME"
fi

# ============================================================================
# Phase 7: apply-check on the clean platform baseline
# ============================================================================
if [ "$APPLY_CHECK" = "1" ]; then
    WT_CHECK=$WORKDIR/applycheck-wt
    git worktree remove --force "$WT_CHECK" 2>/dev/null || true
    git worktree prune
    git worktree add --detach "$WT_CHECK" "$OURS_COMMIT" >/dev/null
    git -C "$WT_CHECK" apply --check "$MERGE_OUT" \
        && echo "   apply-check: PASS (clean apply to sglang-for-sail $SAIL_TAG @ $OURS_COMMIT)" \
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
