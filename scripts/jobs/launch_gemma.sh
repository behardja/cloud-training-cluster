#!/usr/bin/env bash
# =============================================================================
# Launch the Gemma training recipe on the VTC login node (PDF Step 4.6).
# =============================================================================
# Run this ON the login node after SSHing in. GPU clusters launch via NeMo-Run
# (Slurm); TPU clusters via a JAX/MaxText recipe (GKE, Preview).
#
# Two modes:
#   real  : stage your NeMo/MaxText tree from the bucket, train on --data-dir.
#   mock  : --mock-data — run the REAL training code on RANDOM tokens (NeMo
#           MockDataModule). The "SparkPi" of the training stack: it exercises
#           the model + optimizer + parallelism end-to-end but learns nothing.
#           No bucket, no dataset, no external recipe needed (GPU).
#
# Usage:
#   # real GPU run
#   launch_gemma.sh --accelerator gpu --bucket gs://<project>-vtc-temp \
#       --recipe recipes/pretrain/gemma4_4b_pt.py --slurm-type hcc-a4 \
#       --data-dir /gcs/your-bucket/dataset
#   # mock smoke test (no data)
#   launch_gemma.sh --accelerator gpu --mock-data --nodes 1 --gpus-per-node 8
set -euo pipefail

ACCEL="gpu"
BUCKET=""
RECIPE=""
SLURM_TYPE="hcc-a4"
DATA_DIR=""
WORK_DIR="${HOME}/my_training_run"
MOCK=0
GPU_TEST=0
NODES=1
GPUS=8
STEPS=20
PARTITION="a3h100"                                          # Slurm partition = winning profile name
TEST_IMAGE="pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime"  # public PyTorch image for --gpu-test

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accelerator)   ACCEL="$2"; shift 2;;
    --bucket)        BUCKET="$2"; shift 2;;
    --recipe)        RECIPE="$2"; shift 2;;
    --slurm-type)    SLURM_TYPE="$2"; shift 2;;
    --data-dir)      DATA_DIR="$2"; shift 2;;
    --work-dir)      WORK_DIR="$2"; shift 2;;
    --mock-data)     MOCK=1; shift;;
    --gpu-test)      GPU_TEST=1; shift;;
    --nodes)         NODES="$2"; shift 2;;
    --gpus-per-node) GPUS="$2"; shift 2;;
    --steps)         STEPS="$2"; shift 2;;
    --partition)     PARTITION="$2"; shift 2;;
    --test-image)    TEST_IMAGE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$WORK_DIR"

# CPU profile carries no training fabric — it's for plumbing validation only.
if [[ "$ACCEL" != "gpu" && "$ACCEL" != "tpu" ]]; then
  echo "==> '${ACCEL}' is not a training fabric (cpu fallback?). Skipping launch." >&2
  echo "    The cpu profile validates plumbing only — run scripts/jobs/cpu_smoke_test.sh."
  exit 0
fi

# =============================================================================
# GPU TEST — framework-free multi-GPU smoke test, the reliable "SparkPi".
# Runs bf16 matmul + NCCL all-reduce on all GPUs inside a public PyTorch
# container, submitted to the Slurm partition. No NeMo/dataset needed.
# =============================================================================
if [[ "$GPU_TEST" -eq 1 ]]; then
  TEST_RECIPE="${SCRIPT_DIR}/gpu_burn.py"
  [[ -f "$TEST_RECIPE" ]] || { echo "ERROR: gpu_burn.py must sit next to this script" >&2; exit 2; }
  echo "==> GPU TEST: bf16 matmul + NCCL all-reduce on ${GPUS} GPU(s)"
  echo "    partition='${PARTITION}'  container='${TEST_IMAGE}'  (first run pulls the image — a few min)"
  srun --partition="${PARTITION}" --nodes="${NODES}" --ntasks-per-node=1 \
       --gpus-per-node="${GPUS}" --time=00:15:00 \
       --container-image="${TEST_IMAGE}" --container-mounts="${HOME}:${HOME}" \
       bash -lc "cd '${HOME}' && torchrun --standalone --nproc_per_node=${GPUS} gpu_burn.py"
  echo "==> GPU test finished (see output above)."
  exit $?
fi

# =============================================================================
# MOCK MODE — real training code, random tokens (no dataset / no bucket on GPU)
# NOTE: NeMo is NOT on the login node; real NeMo runs inside the GEAP prebuilt
# container via vertex-oss-training run.py. This bare-python path is a stub kept
# for reference — use --gpu-test for a runnable GPU smoke test today.
# =============================================================================
if [[ "$MOCK" -eq 1 ]]; then
  if [[ "$ACCEL" == "gpu" ]]; then
    # Prefer the canonical recipe if it was staged next to this script;
    # otherwise write a self-contained copy so single-file staging still works.
    MOCK_RECIPE="${SCRIPT_DIR}/gemma_mock_pretrain.py"
    if [[ ! -f "$MOCK_RECIPE" ]]; then
      MOCK_RECIPE="${WORK_DIR}/gemma_mock_pretrain.py"
      cat > "$MOCK_RECIPE" <<'PYEOF'
#!/usr/bin/env python3
"""Gemma mock-data smoke test (NeMo) — real training code on random tokens."""
import argparse
import nemo_run as run
from nemo.collections import llm


def build_recipe(nodes, gpus, steps, work_dir):
    recipe = llm.gemma2_2b.pretrain_recipe(
        dir=work_dir, name="gemma_mock",
        num_nodes=nodes, num_gpus_per_node=gpus,
    )
    # the dummy workload: random tokens instead of a real corpus
    recipe.data = run.Config(
        llm.MockDataModule,
        seq_length=4096, global_batch_size=8, micro_batch_size=1,
    )
    recipe.trainer.max_steps = steps
    recipe.trainer.val_check_interval = steps
    recipe.trainer.limit_val_batches = 2
    recipe.log.ckpt = None
    return recipe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=1)
    ap.add_argument("--gpus-per-node", type=int, default=8)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--work-dir", default="./gemma_mock_run")
    a = ap.parse_args()
    recipe = build_recipe(a.nodes, a.gpus_per_node, a.steps, a.work_dir)
    run.run(recipe, executor=run.LocalExecutor(ntasks_per_node=a.gpus_per_node))


if __name__ == "__main__":
    main()
PYEOF
    fi
    echo "==> MOCK: training Gemma on random tokens (NeMo MockDataModule) — proves the GPU path, learns nothing"
    python3 "$MOCK_RECIPE" --nodes "$NODES" --gpus-per-node "$GPUS" --steps "$STEPS" --work-dir "$WORK_DIR"
  else
    # TPU: MaxText ships a synthetic-data mode (dataset_type=synthetic).
    [[ -n "$BUCKET" && -n "$RECIPE" ]] || {
      echo "ERROR: --bucket and --recipe are required for a tpu mock run" >&2; exit 2; }
    echo "==> staging MaxText from ${BUCKET}/maxtext"
    mkdir -p "${HOME}/maxtext"; gsutil -m cp -r "${BUCKET}/maxtext/*" "${HOME}/maxtext/"; cd "${HOME}/maxtext"
    echo "==> MOCK: Gemma on TPU via MaxText synthetic data"
    python3 MaxText/train.py "${RECIPE}" base_output_directory="${WORK_DIR}" dataset_type=synthetic
  fi
  echo "==> mock job submitted. Monitor: squeue ; sinfo ; sacct   (logs in ${WORK_DIR})"
  exit 0
fi

# =============================================================================
# REAL MODE — train on a real dataset staged to the code-transfer bucket
# =============================================================================
[[ -n "$BUCKET" && -n "$RECIPE" && -n "$DATA_DIR" ]] || {
  echo "ERROR: --bucket, --recipe and --data-dir are required (or use --mock-data)" >&2; exit 2; }

if [[ "$ACCEL" == "gpu" ]]; then
  # NeMo-Run on Slurm. The nemo/ tree is staged to the code-transfer bucket
  # first (see README "Stage training code"), then pulled onto the login node.
  echo "==> staging NeMo recipes from ${BUCKET}/nemo"
  mkdir -p "${HOME}/nemo"
  gsutil -m cp -r "${BUCKET}/nemo/*" "${HOME}/nemo/"
  cd "${HOME}/nemo"
  echo "==> launching Gemma (${RECIPE}) on Slurm via NeMo-Run"
  python3 run.py -e slurm \
    --slurm-type "${SLURM_TYPE}" \
    -d "${WORK_DIR}" \
    -s "${RECIPE}" \
    --data-dir "${DATA_DIR}"
else
  # JAX/MaxText on the GKE orchestrator (Preview). The exact launcher depends on
  # the MaxText image you stage; this is the canonical training entrypoint.
  echo "==> staging MaxText from ${BUCKET}/maxtext"
  mkdir -p "${HOME}/maxtext"
  gsutil -m cp -r "${BUCKET}/maxtext/*" "${HOME}/maxtext/"
  cd "${HOME}/maxtext"
  echo "==> launching Gemma (${RECIPE}) on TPU via MaxText"
  python3 MaxText/train.py "${RECIPE}" \
    base_output_directory="${WORK_DIR}" \
    dataset_path="${DATA_DIR}"
fi

echo "==> submitted. Monitor with: squeue ; sinfo ; sacct   (logs in ${WORK_DIR})"
