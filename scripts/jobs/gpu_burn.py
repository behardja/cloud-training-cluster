#!/usr/bin/env python3
"""Real multi-GPU smoke test — bf16 matmul TFLOP/s per GPU + NCCL all-reduce.

The "SparkPi" of GPU training: it does genuine compute (big bf16 matmuls, what a
transformer is mostly made of) on every GPU and a collective all-reduce across
all ranks (the gradient-sync primitive of distributed training). Proves the
H100s + NCCL work end-to-end, with no NeMo/framework dependency.

Launch on the worker via Slurm + container:
  srun --partition=a3h100 --gpus-per-node=8 --container-image=<pytorch> \
       bash -lc "torchrun --standalone --nproc_per_node=8 gpu_burn.py"
"""
import os
import time

import torch
import torch.distributed as dist


def main():
    rank = int(os.environ.get("RANK", 0))
    local = int(os.environ.get("LOCAL_RANK", 0))
    world = int(os.environ.get("WORLD_SIZE", 1))

    dist.init_process_group("nccl")
    torch.cuda.set_device(local)
    dev = torch.device(f"cuda:{local}")
    name = torch.cuda.get_device_name(local)

    # bf16 matmul throughput
    n = 8192
    a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
    b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
    for _ in range(3):  # warmup
        c = a @ b
    torch.cuda.synchronize()
    iters = 30
    t0 = time.time()
    for _ in range(iters):
        c = a @ b
    torch.cuda.synchronize()
    dt = (time.time() - t0) / iters
    tflops = (2 * n ** 3) / dt / 1e12

    # NCCL all-reduce across every rank (the gradient-sync primitive)
    x = torch.full((1,), rank + 1, device=dev, dtype=torch.float32)
    dist.all_reduce(x, op=dist.ReduceOp.SUM)
    expected = world * (world + 1) // 2

    print(f"[rank {rank}/{world}] {name} cuda:{local} | "
          f"bf16 matmul ~{tflops:,.0f} TFLOP/s | allreduce={int(x.item())} (expect {expected})",
          flush=True)
    dist.barrier()
    if rank == 0:
        ok = int(x.item()) == expected
        print(f"\n{'OK' if ok else 'FAIL'}: {world} GPUs ran real bf16 compute + NCCL all-reduce.",
              flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
