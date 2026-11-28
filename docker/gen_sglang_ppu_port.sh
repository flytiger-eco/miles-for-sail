#!/usr/bin/env bash
set -euo pipefail

repo=$1
baseline=$2
sail_commit=$3
miles_commit=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" diff --quiet
git -C "$repo" diff --cached --quiet

fetch_ref() {
    local remote=$1 revision=$2 attempt
    for attempt in 1 2 3; do
        if git -C "$repo" -c http.version=HTTP/1.1 fetch --no-tags --depth 1 "$remote" "$revision"; then
            test "$(git -C "$repo" rev-parse 'FETCH_HEAD^{commit}')" = "$revision"
            return
        fi
        sleep "$((attempt * 2))"
    done
    return 1
}

fetch_ref origin "$baseline"
fetch_ref https://github.com/flytiger-eco/sglang-for-sail.git "$sail_commit"

delta=$(mktemp)
trap 'rm -f "$delta"' EXIT
git -C "$repo" diff --binary --full-index "$baseline" "$sail_commit" -- python/sglang > "$delta"
test -s "$delta"
if ! git -C "$repo" apply --index --3way "$delta"; then
    test -n "$(git -C "$repo" diff --name-only --diff-filter=U)"
    python3 - "$repo" <<'PY'
import hashlib
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
rules = {
    "kernels/ops/attention/flash_mla_interface.py": ("ours",),
    "srt/arg_groups/serving_hook.py": ("both",),
    "srt/distributed/device_communicators/triton_symm_mem_ag.py": ("ours",),
    "srt/entrypoints/openai/serving_chat.py": ("ours",),
    "srt/function_call/core_types.py": ("both",),
    "srt/layers/attention/dsa/dsa_indexer_metadata.py": ("both",),
    "srt/layers/linear.py": ("linear",),
    "srt/model_executor/model_runner.py": ("publish", "profile", "profile"),
}
reviewed_blocks = {
    "srt/layers/attention/dsa/dsa_indexer.py": (
        ("d2bff13d3a4337ffcb04edda47fe84f6c4b3ffc0eced02a091e9fc58be878662", "        else:\n            self._mask_init_and_local_tokens(logits, seqlens_32)\n            result = metadata.topk_transform(\n                logits, self.index_topk, return_raw_indices=capture\n            )\n            if capture:\n                topk_result, raw_result = result\n            else:\n                topk_result = result\n"),
        ("481e89e92ae6d009a304f499072896d897ebf3069f18e398a08adca339ad86f2", "            self._mask_init_and_local_tokens(logits, seq_lens_expanded, score_ks)\n\n            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).\n            if (\n                _enable_logits_nan_check\n                and not torch.cuda.is_current_stream_capturing()\n            ):\n                _check_logits_nan_in_valid_range(logits, score_ks, score_ke)\n            result = metadata.topk_transform(\n                logits,\n                self.index_topk,\n                ks=score_ks,\n                ke_offset=ke - ks if compressed_logits else None,\n                return_raw_indices=capture,\n            )\n            if capture:\n                topk_result[:q_offset], raw_result[:q_offset] = result\n            else:\n                topk_result[:q_offset] = result\n            return topk_result, raw_result\n"),
        ("4f13d2813b36df57f4df6969b992c4286754bab129462eaadcff56760f5ae2f5", "            # [NaN-GUARD] Gated by SGLANG_BF16_TOPK_DEBUG (default off).\n            if (\n                _enable_logits_nan_check\n                and not torch.cuda.is_current_stream_capturing()\n            ):\n                _check_logits_nan_in_valid_range(\n                    logits_chunk,\n                    score_ks[start:end],\n                    score_ke[start:end],\n                    row_offset=start,\n                )\n\n            result = metadata.topk_transform(\n                logits_chunk,\n                self.index_topk,\n                ks=score_ks[start:end],\n                cu_seqlens_q=cu_seqlens_q_chunk,\n                ke_offset=(ke - ks)[start:end] if compressed_logits else lengths_chunk,\n                batch_idx_list=batch_idx_chunk,\n                topk_indices_offset_override=topk_offset_chunk,\n                return_raw_indices=capture,\n            )\n            rows = slice(start - dst_base, end - dst_base)\n            if capture:\n                dst[rows], raw_dst[rows] = result\n            else:\n                dst[rows] = result\n            # Release scratch before allocating the next chunk or gathering top-k.\n            del logits_chunk\n            start = end\n\n        if tp_split is not None:\n            # Rank order == row order, so the gather rebuilds rows [0, q_offset).\n            group, _, _, sizes = tp_split\n            group.all_gatherv(dst, sizes=sizes, output=topk_result[:q_offset])\n            if capture:\n                group.all_gatherv(raw_dst, sizes=sizes, output=raw_result[:q_offset])\n        return topk_result, raw_result\n"),
        ("40535d1cd8d7a87ef0b42a5f74422ed30f8963e6652721ef351eea70bb102332", "        capture = get_global_indexer_capturer() is not None\n        raw_result = None\n        if dsa_shards_index_k() and (\n            forward_batch.forward_mode.is_decode_or_idle()\n            or forward_batch.forward_mode.is_target_verify()\n        ):\n            # Widened slots of every visible position; verify rows pass their\n            # per-row (causal) global lengths.\n            raw_topk_result = dcp_all_visible(\n                seq_lens_expanded,\n                metadata.get_page_table_64(),\n                self.index_topk,\n                get_token_to_kv_pool().page_size,\n            )\n            if capture:\n                positions = torch.arange(self.index_topk, device=seq_lens_expanded.device, dtype=torch.int32)\n                raw_result = torch.where(positions < seq_lens_expanded[:, None], positions, -1)\n        else:\n            dummy_logits = torch.zeros(\n                seq_lens_expanded.shape[0],\n                self.index_topk,\n                dtype=torch.float32,\n                device=x_meta.device,\n            )\n            if get_global_indexer_capturer() is not None:\n                raw_topk_result, raw_result = metadata.topk_transform(\n                    dummy_logits, self.index_topk, return_raw_indices=True\n                )\n            else:\n                raw_topk_result = metadata.topk_transform(dummy_logits, self.index_topk)\n                raw_result = None\n"),
        ("032b11c333b8915af3ce221b21f44c88934ade3eb7bc76bd9c6d0852f107e589", "            #! <Note>[phh]:In PR#19148 of the sglang community, a new fusion Kernel has been\n            # added to perform quantization and storage Index_k together .\n            # However, for BF16_INDEXER, set_index_k_scale_buffer is still required\n            if self.bf16_indexer or self.use_int8:\n                # k_fp8: (seq_len, head_dim) fp8_e4m3fn\n                # k_buffer: (num_total_tokens + page_size, head_dim) fp8_e4m3fn\n                # k_scale: (seq_len, head_dim // block_size = 1) fp8_e4m3fn\n                # k_scale_cache: (num_total_tokens + page_size, head_dim // block_size = 1) fp8_e4m3fn\n                if not forward_batch.out_cache_loc.is_contiguous():\n                    forward_batch.out_cache_loc = (\n                        forward_batch.out_cache_loc.contiguous()\n                    )\n                get_token_to_kv_pool().set_index_k_scale_buffer(\n                    layer_id=layer_id,\n                    loc=forward_batch.out_cache_loc,\n                    index_k=k_fp8,\n                    index_k_scale=k_scale,\n                )\n\n        raw_result = None\n"),
        ("933392a8b8c95135ea2a0f52e6c70e8d47e7a66697bc2eb1ad973c7c2e48b888", "            if (\n                forward_batch.forward_mode.is_decode_or_idle()\n                or forward_batch.forward_mode.is_target_verify()\n                or forward_batch.forward_mode.is_draft_extend_v2()\n            ):\n                topk_result, raw_result = self._get_topk_paged(\n                    forward_batch, layer_id, q_fp8, weights, metadata\n                )\n            else:\n                if (\n                    forward_batch.attn_cp_metadata is not None\n                    and is_dsa_prefill_cp_in_seq_split()\n                ):\n                    kv_len_prev = forward_batch.attn_cp_metadata.kv_len_prev_list[0]\n                    kv_len_next = forward_batch.attn_cp_metadata.kv_len_next_list[0]\n                    actual_seq_q_prev = (\n                        forward_batch.attn_cp_metadata.actual_seq_q_prev_list[0]\n                    )\n                    actual_seq_q_next = (\n                        forward_batch.attn_cp_metadata.actual_seq_q_next_list[0]\n                    )\n\n                    # TODO support mutil-batch\n                    # cp_batch_seq_index_prev = forward_batch.attn_cp_metadata[\"cp_batch_seq_index_prev\"]\n                    # cp_batch_seq_index_next = forward_batch.attn_cp_metadata[\"cp_batch_seq_index_next\"]\n                    # TODO prev, next, combined into a single call\n                    if self.use_fp4:\n                        # FP4: q_fp8 is (q_packed, q_sf) tuple; split both components\n                        q_packed, q_sf = q_fp8\n                        q_packed_prev, q_packed_next = torch.split(\n                            q_packed, (q_packed.shape[0] + 1) // 2, dim=0\n                        )\n                        q_sf_prev, q_sf_next = torch.split(\n                            q_sf, (q_sf.shape[0] + 1) // 2, dim=0\n                        )\n                        q_fp8_prev = (q_packed_prev, q_sf_prev)\n                        q_fp8_next = (q_packed_next, q_sf_next)\n                    else:\n                        q_fp8_prev, q_fp8_next = torch.split(\n                            q_fp8, (q_fp8.shape[0] + 1) // 2, dim=0\n                        )\n                    weights_prev, weights_next = torch.split(\n                        weights, (weights.shape[0] + 1) // 2, dim=0\n                    )\n                    topk_result_prev, raw_prev = self._get_topk_ragged_with_cp(\n                        forward_batch,\n                        layer_id,\n                        q_fp8_prev,\n                        weights_prev,\n                        metadata,\n                        kv_len_prev,\n                        actual_seq_q_prev,\n                    )\n\n                    topk_result_next, raw_next = self._get_topk_ragged_with_cp(\n                        forward_batch,\n                        layer_id,\n                        q_fp8_next,\n                        weights_next,\n                        metadata,\n                        kv_len_next,\n                        actual_seq_q_next,\n                    )\n                    topk_result = torch.cat([topk_result_prev, topk_result_next], dim=0)\n                    topk_result = _broadcast_indexer_topk_from_rank0(topk_result)\n                    raw_result = torch.cat([raw_prev, raw_next], dim=0) if raw_prev is not None else None\n                    if raw_result is not None:\n                        raw_result = _broadcast_indexer_topk_from_rank0(raw_result)\n                    return self._capture_and_return(layer_id, topk_result, raw_result)\n                else:\n                    # In-graph (PCG/BCG) non-CP prefill is handled earlier by the\n                    # graph DSA split-op dispatch, so only the eager path reaches\n                    # here.\n                    assert not in_piecewise_or_breakable_cuda_graph, (\n                        \"Internal error: in-graph DSA prefill must go through the \"\n                        \"graph DSA split-op dispatch\"\n                    )\n                    topk_result, raw_result = self._get_topk_ragged(\n                        enable_dual_stream,\n                        forward_batch,\n                        layer_id,\n                        q_fp8,\n                        weights,\n                        metadata,\n                    )\n"),
    ),
    "srt/layers/attention/dsa/dsa_topk_backend.py": (
        ("f617539477d11ae84c7f1ddd4df8253102ca1a27d40bd98d7d85cacce5f4f676", "        packed_extend_topk: bool = False,\n        return_raw_indices: bool = False,\n"),
        ("d8ba775eaa0c711a52c35a0b94c4aa11952b8e58179a1271bdc1c3d685e77f37", "            if is_sail() and logits.dtype == torch.bfloat16:\n                logits = _sail_topk_fp32(logits)\n            result = _topk_transform_v2_paged(logits, lengths, topk, attn_metadata)\n            return (result, raw_indices) if return_raw_indices else result\n"),
        ("70672b359cc0d1de27ead7bde1676b09062fdede53d3d4526b01bfc5fb3db58d", "            result = _topk_transform_v2_ragged(\n                logits,\n                lengths,\n                topk,\n                topk_indices_offset,\n                row_starts,\n                attn_metadata=attn_metadata,\n"),
        ("9485f9d11d58389e5bb414bcdd4275eb9c204324b05e4eafa42893e5c48fd229", "                # Route PAGED path through dsv4's bf16 topk kernel when gate is on\n                # and logits are bf16; falls back to fast_topk_transform_fused otherwise.\n                if (\n                    is_sail()\n                    and envs.SGLANG_DSA_USE_DSV4_BF16_TOPK.get()\n                    and logits.dtype == torch.bfloat16\n                ):\n                    result = self._topk_transform_dsv4_bf16(\n                        logits=logits,\n                        seq_lens_topk=lengths,\n                        page_table_size_1=page_table_size_1,\n                        cu_seqlens_q_topk=cu_seqlens_q_topk,\n                        topk=topk,\n                        ks=row_starts,\n                    )\n                    return (result, raw_indices) if return_raw_indices else result\n                if is_sail() and logits.dtype == torch.bfloat16:\n                    logits = _sail_topk_fp32(logits)\n                result = fast_topk_transform_fused(\n"),
        ("7cb1c355477dd432a2300823a07a29e5ec69995bc17262b73bee779d51a555b0", "                # fast_topk_transform_ragged_fused requires fp32 scores. An fp8 KV\n                # store makes the indexer emit bf16 logits (it previously saw fp32\n                # from the bf16 KV path), which fails inside sgl_kernel with\n                # \"expected scalar type Float but found BFloat16\".\n                # bf16 -> fp32 is value preserving, so the selected indices are\n                # unchanged; this restores the pre-fp8 dtype instead of changing\n                # the selection semantics.\n                if is_sail() and logits.dtype == torch.bfloat16:\n                    score = _sail_topk_fp32(logits)\n                else:\n                    score = logits if logits.dtype == torch.float32 else logits.float()\n                result = fast_topk_transform_ragged_fused(\n                    score=score,\n"),
    ),
    "srt/layers/quantization/mxfp4.py": (
        ("a617e911a33e5a5cc7000567cbcd208d187b40bd96a5d1243f5204ddcee7e70c", "                deinterleave_moe_mxfp4_w13_for_marlin(\n                    layer, reuse_parameter_storage=reuse_parameter_storage\n                )\n            prepare_moe_mxfp4_layer_for_marlin(\n                layer, reuse_parameter_storage=reuse_parameter_storage\n            )\n            if _is_sail and self.use_deepgemm_mxfp4_w4a16_valu:\n                # DeepGEMM uses uint8 E8M0 scales to select its MXFP4/E2M1 path.\n                for scale_name in (\"w13_weight_scale\", \"w2_weight_scale\"):\n                    scale = getattr(layer, scale_name)\n                    if scale.dtype == torch.uint8:\n                        continue\n                    setattr(\n                        layer,\n                        scale_name,\n                        Parameter(scale.view(torch.uint8), requires_grad=False),\n                    )\n                del scale\n                # Release stale loader tensors and Marlin conversion buffers\n                # before KV-cache sizing measures available device memory.\n                torch.cuda.empty_cache()\n            runtime_specs = {\n                name: (tuple(getattr(layer, name).shape), getattr(layer, name).dtype)\n                for name in self._marlin_parameter_names(layer)\n            }\n            if reuse_parameter_storage:\n                if runtime_specs != layer._mxfp4_marlin_runtime_parameter_specs:\n                    raise ValueError(\n                        \"MXFP4 Marlin in-place reload changed the runtime layout: \"\n                        f\"{runtime_specs} vs {layer._mxfp4_marlin_runtime_parameter_specs}.\"\n                    )\n            else:\n                layer._mxfp4_marlin_runtime_parameter_specs = runtime_specs\n            layer._mxfp4_marlin_reload_in_place = False\n"),
    ),
    "srt/models/deepseek_common/deepseek_weight_loader.py": (
        ("1d654e1b55a2973f92655e8d6ba082d88230ce9229408e542fd1585f27456118", "def _dequant_fused_indexer_shard(\n"),
        ("1decb3250894af759f056076207358f246f667eb1b627c2a523fcd3ed9d547d9", "    \"\"\"Dequantize one indexer shard to bf16, per the scale's granularity.\"\"\"\n    # mxfp8 scales are UE8M0 exponents stored as uint8, not fp32 multipliers\n    if scale.dtype == torch.uint8:\n        return dequant_mxfp8_2d_to_bf16(weight, scale)\n    if scale.numel() == weight.shape[0]:\n        # per-output-channel scale (w8a8 int8 / channelwise fp8)\n        return (weight.float() * scale.float()).to(torch.bfloat16)\n    block_size = _get_indexer_weight_block_size(quant_config)\n    return block_quant_dequant(weight, scale, block_size, torch.bfloat16)\n"),
        ("a076253286d2604a4d3846f7ef2ec30ea2ee6270800cfdc853ff295cf6062af2", "            weights_bf16 = _dequant_fused_indexer_shard(\n"),
        ("985db2092b57bef9446c453ce018beae21122a3f2d7e62125c189e6e3a3435b9", "        wk_bf16 = _dequant_fused_indexer_shard(\n            entry[\"weight\"], entry[\"scale\"], quant_config\n        )\n"),
    ),
    "srt/models/kimi_k3.py": (
        ("33e6102a7f70ef16299e668a3bc1e7e37b48db4d576bd878d26e55c6e89eae42", "        gate_up, router_logits, routed_input = self._fused_front(hidden_states)\n        gate_up_proj = self.shared_experts.gate_up_proj\n        if getattr(gate_up_proj, \"lora_active\", False):\n            # the merged front GEMM read the base shared weight through the wrapper; add its delta\n            gate_up = gate_up_proj.apply_lora(gate_up.contiguous(), hidden_states)\n"),
        ("f3907f88434bc5ec525392c9470e5a67e0089dca1cf4c4a840c55e2966b6fb5f", "            self._bfa_w, sizes = _merge_weights_as_views(\n                mods, pad_rows_to=pad_rows_to, merged=self._bfa_w\n            )\n            # .data: a second Parameter registration hides f_b_proj.weight from named_parameters()\n            self._bfa_f_b_w = self.f_b_proj.weight.data\n        self._bfa_fa_size, self._bfa_b_size = sizes[-2:]\n"),
        ("02a2e913396b3eb858cfc0ec603dab22aa07272a6e890af43b7b04502dcf4359", "    # Fused runtime module -> checkpoint shard names, so quant configs can\n    # match fused prefixes against per-shard exclude_modules\n    packed_modules_mapping = {\n        \"fused_qkv_a_proj_with_mqa\": [\"q_a_proj\", \"kv_a_proj_with_mqa\"],\n        \"gate_up_proj\": [\"gate_proj\", \"up_proj\"],\n        \"qkv_proj\": [\"q_proj\", \"k_proj\", \"v_proj\"],\n        \"qkv_conv1d\": [\"q_conv1d\", \"k_conv1d\", \"v_conv1d\"],\n        \"fused_qkvg_proj\": [\"q_proj\", \"k_proj\", \"v_proj\", \"g_proj\"],\n        \"fused_qkvbfg_a_proj\": [\n            \"q_proj\",\n            \"k_proj\",\n            \"v_proj\",\n            \"b_proj\",\n            \"f_a_proj\",\n            \"g_a_proj\",\n        ],\n        \"fused_fg_b_proj\": [\"f_b_proj\", \"g_b_proj\"],\n    }\n\n    @staticmethod\n    def get_lora_target_module_name(name: str) -> str:\n        parent, _, leaf = name.rpartition(\".\")\n        if \".experts\" in parent:\n            return {\"w1\": \"gate_proj\", \"w2\": \"down_proj\", \"w3\": \"up_proj\"}.get(\n                leaf, name\n            )\n        return name\n"),
    ),
}
rules.update(reviewed_blocks)
pattern = re.compile(r"^<<<<<<< ours\n(.*?)^=======\n(.*?)^>>>>>>> theirs\n", re.M | re.S)
unmerged = subprocess.check_output(
    ["git", "-C", root, "diff", "--name-only", "--diff-filter=U", "-z"]
).decode().split("\0")

def resolve_block(match, action):
    ours, theirs = match.groups()
    if isinstance(action, tuple):
        expected, replacement = action
        if hashlib.sha256(match[0].encode()).hexdigest() != expected:
            raise ValueError("Locked conflict changed; review the replacement")
        return replacement
    if action == "ours":
        return ours
    if action == "both":
        return ours + theirs
    if action == "linear":
        prefix, suffix = theirs.rsplit("            if output_tensor is None:\n", 1)
        if suffix or "nvtx_push_range_for_gemm" not in prefix or "should_use_tp_invariant_row_linear" not in ours:
            raise ValueError("Unexpected row-parallel linear conflict")
        return prefix + ours
    if action == "publish":
        prepare = "        self.prepare_eplb_async_layers()\n"
        if not theirs.startswith(prepare) or 'role="target"' not in ours:
            raise ValueError("Unexpected weight publication conflict")
        return prepare + ours
    if action == "profile":
        prefix, _ = theirs.split("return ModelRunnerOutput", 1)
        indent = re.match(r"^ *", ours)[0]
        if "th_nvtx_range_pop()" not in prefix or "graph_num_tokens=" not in ours:
            raise ValueError("Unexpected model-runner profiling conflict")
        return prefix.rstrip() + "\n" + indent + ours.lstrip(" ")
    raise ValueError(f"Unexpected resolution action: {action}")

for suffix, actions in rules.items():
    relative = f"python/sglang/{suffix}"
    if relative not in unmerged:
        continue
    source = root / relative
    original = source.read_text()
    blocks = iter(actions)
    resolved, count = pattern.subn(
        lambda match: resolve_block(match, next(blocks, None)),
        original,
    )
    if count != len(actions) or re.search(r"^(<<<<<<<|=======|>>>>>>>)", resolved, re.M):
        raise SystemExit(f"Unexpected conflict markers in {relative}")
    if suffix.endswith("/dsa_indexer.py"):
        before = "        if dcp_size > 1:\n            # block_tables and seqlens_32_2d"
        after = "                metadata.attn_metadata.topk_v2_plan,\n            )\n        else:\n            self._mask_init_and_local_tokens(logits, seqlens_32)"
        if resolved.count(before) != 1 or resolved.count(after) != 1:
            raise ValueError("Unexpected DCP decode top-k context")
        start = resolved.index(before)
        stop = resolved.index(after, start)
        prefix = resolved[start:stop]
        if prefix.count("topk_result = dcp_global_topk(") != 1:
            raise ValueError("Unexpected DCP dispatch")
        resolved = (
            resolved[:start]
            + "        capture = get_global_indexer_capturer() is not None\n        raw_result = None\n"
            + prefix.replace("topk_result = dcp_global_topk(", "result = dcp_global_topk(")
            + resolved[stop:].replace(
                after,
                after.replace(
                    "            )\n        else:",
                    "                return_raw_indices=capture,\n            )\n"
                    "            if capture:\n                topk_result, raw_result = result\n"
                    "            else:\n                topk_result = result\n        else:",
                ),
                1,
            )
        )
    compile(resolved, relative, "exec")
    source.write_text(resolved)
    subprocess.run(["git", "-C", root, "add", "--", relative], check=True)
PY
    git -C "$repo" diff --name-only --diff-filter=U >&2
    test -z "$(git -C "$repo" diff --name-only --diff-filter=U)"
fi
# CuTe DSL dual GEMM targets NVIDIA kernels. Keep the normal projection on SAIL.
python3 - "$repo" <<'PY_PORT'
import sys
from pathlib import Path

path = Path(sys.argv[1]) / "python/sglang/srt/layers/dual_gemm.py"
source = path.read_text()
for old, new in (
    ("from sglang.srt.utils import is_cuda", "from sglang.srt.utils import is_cuda, is_sail"),
    ("if not is_cuda():", "if not is_cuda() or is_sail():"),
):
    if source.count(old) != 1:
        raise SystemExit(f"Unexpected SGLang dual GEMM source: {old}")
    source = source.replace(old, new)
compile(source, str(path), "exec")
path.write_text(source)
PY_PORT
git -C "$repo" add -- python/sglang/srt/layers/dual_gemm.py
# The PPU image can use Triton when the default FA3 extension is unavailable.
python3 - "$repo" <<'PY_ATTN'
import sys
from pathlib import Path

path = Path(sys.argv[1]) / "python/sglang/srt/arg_groups/overrides.py"
source = path.read_text()
for old, new in (
    ("import json\n", "from importlib.util import find_spec\nimport json\n"),
    (
        "        logger.info(\n"
        '            f"Attention backend not specified. Use {backend} backend by default."',
        '        if is_sail() and backend == "fa3" and find_spec("flash_attn_interface") is None:\n'
        '            backend = "triton"\n'
        "        logger.info(\n"
        '            f"Attention backend not specified. Use {backend} backend by default."',
    ),
):
    if source.count(old) != 1:
        raise SystemExit(f"Unexpected SGLang attention default source: {old}")
    source = source.replace(old, new)
compile(source, str(path), "exec")
path.write_text(source)
path = Path(sys.argv[1]) / "python/sglang/srt/speculative/eagle_worker_v2.py"
source = path.read_text()
old = (
    "            from sglang.srt.layers.attention.flashmla_backend import FlashMLABackend\n\n"
    "            graph_supported_backend_types.append(FlashMLABackend)"
)
new = (
    "            from importlib.util import find_spec\n\n"
    '            if find_spec("sgl_flash_mla") is not None or find_spec("flash_mla") is not None:\n'
    "                from sglang.srt.layers.attention.flashmla_backend import FlashMLABackend\n\n"
    "                graph_supported_backend_types.append(FlashMLABackend)"
)
if source.count(old) != 1:
    raise SystemExit("Unexpected SGLang EAGLE FlashMLA registration")
source = source.replace(old, new)
compile(source, str(path), "exec")
path.write_text(source)
PY_ATTN
git -C "$repo" add -- python/sglang/srt/arg_groups/overrides.py python/sglang/srt/speculative/eagle_worker_v2.py
test "$(git -C "$repo" rev-parse HEAD)" = "$miles_commit"
git -C "$repo" diff --cached --stat
