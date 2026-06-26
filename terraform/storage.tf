// Code-transfer bucket — scratch GCS bucket used to stage training recipes onto
// the login node (PDF Steps 2.6 / 4.5). Ephemeral, so force_destroy is on.

resource "google_storage_bucket" "code_transfer" {
  name                        = local.bucket_name
  project                     = local.project_id
  location                    = local.region
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.required]
}
