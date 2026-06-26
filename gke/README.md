# Submit VTC from GKE (planned)

A future *origin* for driving GE Agent Platform Training Clusters from **inside Kubernetes**
via **Workload Identity** (no keys), reusing this repo's shared `configs/` and `scripts/`: a pod
runs the same `create_cluster.sh`, so only the IAM / Workload-Identity binding is new.

Status: **future work** — see the main [README → Future work](../README.md#future-work). The
implementation (a thin Terraform Workload-Identity binding, a one-shot Kubernetes Job, and a
submit-from-GKE notebook) will land in a later iteration.
