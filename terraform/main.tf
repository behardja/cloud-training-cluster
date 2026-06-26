// Root module — stands up everything a VTC cluster needs AROUND the cluster
// (enabled APIs, PSA peering, Filestore shared /home, the code-transfer bucket),
// then hands cluster creation to scripts/create_cluster.sh so the hardware
// fallback chain lives in exactly one place (shared with the notebook path).
//
// The cluster spec is NOT hand-written here — it is read from
// ../configs/cluster_config.yaml, the same file the notebooks regenerate. Set
// project_id in terraform.tfvars (or in that YAML) and `terraform apply`.

locals {
  // The single contract. yamldecode here = the source of truth for both paths.
  cfg = yamldecode(file("${path.root}/../configs/cluster_config.yaml"))

  project_id = var.project_id != "" ? var.project_id : local.cfg.project.id
  region     = var.region != "" ? var.region : local.cfg.project.region
  zone       = local.cfg.project.zone

  network = local.cfg.network
  fs      = local.cfg.filestore

  // Code-transfer bucket: explicit name, else "<project>-vtc-temp" (matches the
  // script default and the PDF's GCS_BUCKET convention).
  bucket_name = local.cfg.bucket.name != "" ? local.cfg.bucket.name : "${local.project_id}-vtc-temp"

  config_path = abspath("${path.root}/../configs/cluster_config.yaml")
  scripts_dir = abspath("${path.root}/../scripts")
}
