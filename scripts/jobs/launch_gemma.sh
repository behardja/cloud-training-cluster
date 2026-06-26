#!/usr/bin/env bash
# =============================================================================
# Launch the Gemma training recipe on the VTC login node (PDF Step 4.6).
# =============================================================================
# Run this ON the login node after SSHing in. It stages the training code from
# the code-transfer bucket and kicks off the recipe named in cluster_config.yaml.
# GPU clusters launch via NeMo-Run (Slurm); TPU clusters via a JAX/MaxText recipe
# (GKE, Preview). Pass the values from your config as flags or env vars.
#
# Usage (GPU example):
#   launch_gemma.sh --accelerator gpu \
#       --bucket gs://<project>-vtc-temp \
#       --recipe recipes/pretrain/gemma4_4b_pt.py \
#       --slurm-type hcc-a4 \
#       --data-dir /gcs/your-bucket/dataset
set -euo pipefail

ACCEL="gpu"
BUCKET=""
RECIPE=""
SLURM_TYPE="hcc-a4"
DATA_DIR=""
WORK_DIR="${HOME}/my_training_run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accelerator) ACCEL="$2"; shift 2;;
    --bucket)      BUCKET="$2"; shift 2;;
    --recipe)      RECIPE="$2"; shift 2;;
    --slurm-type)  SLURM_TYPE="$2"; shift 2;;
    --data-dir)    DATA_DIR="$2"; shift 2;;
    --work-dir)    WORK_DIR="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -n "$BUCKET" && -n "$RECIPE" && -n "$DATA_DIR" ]] || {
  echo "ERROR: --bucket, --recipe and --data-dir are required" >&2; exit 2; }

mkdir -p "$WORK_DIR"

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
elif [[ "$ACCEL" == "tpu" ]]; then
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
else
  echo "==> '${ACCEL}' is not a training fabric (cpu fallback?). Skipping launch." >&2
  echo "    The cpu profile is for plumbing validation only — run scripts/jobs/cpu_smoke_test.sh."
  exit 0
fi

echo "==> submitted. Monitor with: squeue ; sinfo ; sacct   (logs in ${WORK_DIR})"
