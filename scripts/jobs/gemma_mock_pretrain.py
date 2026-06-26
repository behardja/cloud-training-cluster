#!/usr/bin/env python3
"""
Level-2 smoke test — run the REAL Gemma pre-training code on RANDOM tokens.

This is the "SparkPi" of the training stack: it builds the actual Gemma model
and runs real forward/backward/optimizer steps across the GPUs, but the data is
synthetic noise from NeMo's MockDataModule, so it learns nothing. Use it to
prove the GPU + NeMo + Slurm path works end-to-end (and to measure throughput)
before wiring a real dataset.

  workload type : pre-training (next-token prediction) — shape only, not a real run
  data          : random tokens (NeMo MockDataModule), no dataset on disk
  output        : throwaway weights — do not keep

Requires NeMo 2.0 in the environment (cluster image / staged nemo tree).
Invoked by scripts/jobs/launch_gemma.sh --mock-data.
"""
import argparse

import nemo_run as run
from nemo.collections import llm


def build_recipe(nodes, gpus, steps, work_dir):
    # A small Gemma config keeps the smoke test cheap. The exact recipe symbol
    # depends on the NeMo version / Gemma generation (e.g. llm.gemma2_2b);
    # swap to the size your cluster image ships.
    recipe = llm.gemma2_2b.pretrain_recipe(
        dir=work_dir,
        name="gemma_mock",
        num_nodes=nodes,
        num_gpus_per_node=gpus,
    )

    # ---- the dummy workload: random tokens instead of a real corpus ----
    # Same code path as a real pretrain (next-token prediction over packed
    # sequences); only the bytes are noise, so the weights are meaningless.
    recipe.data = run.Config(
        llm.MockDataModule,
        seq_length=4096,
        global_batch_size=8,
        micro_batch_size=1,
    )

    # Short run, and don't persist useless checkpoints.
    recipe.trainer.max_steps = steps
    recipe.trainer.val_check_interval = steps
    recipe.trainer.limit_val_batches = 2
    recipe.log.ckpt = None
    return recipe


def main():
    ap = argparse.ArgumentParser(description="Gemma mock-data smoke test (NeMo).")
    ap.add_argument("--nodes", type=int, default=1)
    ap.add_argument("--gpus-per-node", type=int, default=8)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--work-dir", default="./gemma_mock_run")
    args = ap.parse_args()

    recipe = build_recipe(args.nodes, args.gpus_per_node, args.steps, args.work_dir)

    # Run on this node's GPUs (NeMo-Run wraps torchrun). For a true multi-node
    # Slurm submission, swap LocalExecutor -> run.SlurmExecutor(...).
    run.run(recipe, executor=run.LocalExecutor(ntasks_per_node=args.gpus_per_node))


if __name__ == "__main__":
    main()
