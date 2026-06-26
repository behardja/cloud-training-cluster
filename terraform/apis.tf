// APIs a VTC cluster + its supporting infra depend on. Everything else depends
// on these being enabled first (PDF Step 2.2).

resource "google_project_service" "required" {
  for_each = toset([
    "aiplatform.googleapis.com",        // Vertex AI — the modelDevelopmentClusters API
    "compute.googleapis.com",           // Compute Engine — the cluster nodes + VPC
    "file.googleapis.com",              // Filestore — shared /home (service name is file.*, not filestore.*)
    "servicenetworking.googleapis.com", // Private Services Access (PSA) for Filestore
    "storage.googleapis.com",           // GCS code-transfer bucket
  ])
  project            = local.project_id
  service            = each.value
  disable_on_destroy = false
}
