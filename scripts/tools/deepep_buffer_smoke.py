#!/usr/bin/env python3
"""DeepEP Buffer construction smoke test.

Reproduces the minimal failing site of the qwen35 E2E training crash on the
810E test cluster: the deep_ep Buffer constructor (deep_ep/buffers/legacy.py
-> _C.Buffer -> csrc/legacy/buffer.hpp), before any dispatch/combine traffic
runs. This isolates the deep_ep version variable from the full training
warm-up (model load, weight sync, rollout generation).

The buffer sizes mirror what Megatron's fused_a2a.get_buffer computes for the
training run: the max of the dispatch/combine config size hints for the given
hidden bytes and group size.

Launch with torchrun, e.g.:

    torchrun --nproc-per-node 8 scripts/tools/deepep_buffer_smoke.py --hidden-size 2048
"""

import argparse
import importlib.metadata as im
import os

import torch
import torch.distributed as dist
from deep_ep import Buffer


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hidden-size", type=int, default=2048, help="model hidden size (default: Qwen3.5-35B)")
    parser.add_argument("--dtype-bytes", type=int, default=2, help="bytes per activation element (bf16 = 2)")
    parser.add_argument("--num-nvl-bytes", type=int, default=0, help="override NVL buffer size (0 = compute)")
    parser.add_argument("--num-rdma-bytes", type=int, default=0, help="override RDMA buffer size (0 = compute)")
    return parser.parse_args()


def compute_buffer_sizes(hidden_bytes: int, group_size: int) -> tuple[int, int]:
    """Compute buffer sizes the same way Megatron's fused_a2a.get_buffer does."""
    configs = [Buffer.get_dispatch_config(group_size)]
    combine_config = getattr(Buffer, "get_combine_config", None)
    if combine_config is not None:
        configs.append(combine_config(group_size))
    num_nvl_bytes = 0
    num_rdma_bytes = 0
    for config in configs:
        num_nvl_bytes = max(config.get_nvl_buffer_size_hint(hidden_bytes, group_size), num_nvl_bytes)
        num_rdma_bytes = max(config.get_rdma_buffer_size_hint(hidden_bytes, group_size), num_rdma_bytes)
    return num_nvl_bytes, num_rdma_bytes


def main() -> None:
    """Run the smoke test on every rank."""
    args = parse_args()
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    torch.cuda.set_device(rank % torch.cuda.device_count())
    dist.init_process_group(backend="gloo")

    deep_ep_version = im.version("deep_ep")
    hidden_bytes = args.hidden_size * args.dtype_bytes
    num_nvl_bytes, num_rdma_bytes = compute_buffer_sizes(hidden_bytes, world_size)
    if args.num_nvl_bytes:
        num_nvl_bytes = args.num_nvl_bytes
    if args.num_rdma_bytes:
        num_rdma_bytes = args.num_rdma_bytes
    if rank == 0:
        print(
            f"[deepep-smoke] deep_ep={deep_ep_version} world_size={world_size} "
            f"hidden_bytes={hidden_bytes} num_nvl_bytes={num_nvl_bytes} num_rdma_bytes={num_rdma_bytes}"
        )

    # The crash site: deep_ep/buffers/legacy.py -> _C.Buffer(...) ->
    # csrc/legacy/buffer.hpp NVLink buffer allocation. A driver rejection
    # here aborts the process with hggcErrorInvalidValue.
    buffer = Buffer(dist.group.WORLD, num_nvl_bytes, num_rdma_bytes)
    if rank == 0:
        print(f"[deepep-smoke] Buffer constructed OK: nvl={buffer.num_nvl_bytes} rdma={buffer.num_rdma_bytes}")

    dist.barrier()
    print(f"[deepep-smoke] rank {rank}: PASS")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
