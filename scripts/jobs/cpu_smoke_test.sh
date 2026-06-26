#!/bin/bash
# Slurm smoke test (PDF Step 3.7). Copy this to the login node and submit with
# `sbatch cpu_smoke_test.sh`, then read cpu_test_<job_id>.out. It proves the
# scheduler can place a job on a worker and write back to the shared /home.
#
# NOTE: --partition must match the WINNING profile's name (= its Slurm partition
# id). On a cpu fallback that's `cpu`; on the a4b200 profile it's `a4b200`.
#SBATCH --job-name=smoke_test
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --output=cpu_test_%j.out

echo "Hello from $(hostname)"
sleep 30
echo "Job finished"
