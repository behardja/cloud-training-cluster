// The cluster itself. There is no native Terraform resource for VTC
// (modelDevelopmentClusters is a v1beta1 Preview API), so we drive the shared
// create/delete scripts via a null_resource. This keeps the hardware FALLBACK
// logic in one place — scripts/create_cluster.sh — used identically by the
// notebook path. Gated behind var.create_cluster so a first apply provisions
// only the supporting infra (APIs/PSA/Filestore/bucket).
//
// Requires gcloud (authenticated) + python3/PyYAML wherever `terraform apply`
// runs, since the script calls the Vertex AI REST API directly.

resource "null_resource" "cluster" {
  count = var.create_cluster ? 1 : 0

  // Re-run the create if the config, the resolved id, or the profile subset
  // changes. The cluster spec is hashed via the config file contents.
  triggers = {
    config_sha = filesha256(local.config_path)
    cluster_id = var.cluster_id
    profiles   = var.profiles
    region     = local.region
    project    = local.project_id
    scripts    = local.scripts_dir
  }

  provisioner "local-exec" {
    command = join(" ", concat(
      ["${local.scripts_dir}/create_cluster.sh", "--config", local.config_path],
      var.cluster_id != "" ? ["--cluster-id", var.cluster_id] : [],
      var.profiles != "" ? ["--profiles", var.profiles] : [],
      ["--state-out", "${path.root}/.vtc_cluster_state"],
    ))
  }

  // Best-effort teardown on `terraform destroy`. Reads the cluster id back from
  // the state file the create wrote. Filestore/bucket are destroyed by their own
  // resources, so this only removes the cluster.
  provisioner "local-exec" {
    when    = destroy
    command = "${self.triggers.scripts}/delete_cluster.sh --config ${self.triggers.scripts}/../configs/cluster_config.yaml --state-in ${path.root}/.vtc_cluster_state || true"
  }

  depends_on = [
    google_filestore_instance.home,
    google_storage_bucket.code_transfer,
    google_service_networking_connection.psa,
  ]
}
