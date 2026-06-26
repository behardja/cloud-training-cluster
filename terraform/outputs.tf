output "project_id" {
  value       = local.project_id
  description = "Resolved project (from var or configs/cluster_config.yaml)."
}

output "region" {
  value = local.region
}

output "filestore_instance" {
  value       = google_filestore_instance.home.name
  description = "Shared /home Filestore instance backing the cluster."
}

output "code_transfer_bucket" {
  value       = "gs://${google_storage_bucket.code_transfer.name}"
  description = "Stage training recipes here, then pull onto the login node."
}

output "fallback_chain" {
  value       = [for p in local.cfg.fallback_chain : p.name]
  description = "Hardware profiles create_cluster.sh tries, in order."
}

output "next_steps" {
  value = <<-EOT
    Supporting infra is up in ${local.project_id}/${local.region}.
    Fallback chain: ${join(" -> ", [for p in local.cfg.fallback_chain : p.name])}
    Next:
      1. (if create_cluster=false) create it: terraform apply -var create_cluster=true
         or run scripts/create_cluster.sh --config ../configs/cluster_config.yaml
      2. Find the login node IP (Vertex AI > Training > Model Development Clusters)
         and SSH in:  gcloud compute ssh <cluster-id>-login-001 --zone ${local.zone}
      3. Validate Slurm (sinfo / squeue) then launch Gemma — see notebooks/02-run-training.ipynb
         GPU smoke test (no dataset): bash launch_gemma.sh --accelerator gpu --mock-data
      4. TPU profiles are Preview (GKE orchestrator) and need allowlisting — see README.
  EOT
}
