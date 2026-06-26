// Filestore instance backing the shared /home across every node (PDF Step 2.5).
// Connect mode is PRIVATE_SERVICE_ACCESS, so it depends on the PSA peering.
// The cluster references this instance as `home_directory_storage` (the script
// derives that resource name from the same config values).

resource "google_filestore_instance" "home" {
  name     = local.fs.instance_id
  project  = local.project_id
  location = local.zone
  tier     = local.fs.tier

  file_shares {
    name = local.fs.share_name
    // Filestore wants GiB; the config carries a human "1TB"-style string, so
    // parse the leading number and scale TB -> GiB (1024), else treat as GB.
    capacity_gb = can(regex("(?i)tb", local.fs.capacity)) ? tonumber(regex("[0-9]+", local.fs.capacity)) * 1024 : tonumber(regex("[0-9]+", local.fs.capacity))
  }

  networks {
    network      = data.google_compute_network.vpc.name
    modes        = ["MODE_IPV4"]
    connect_mode = "PRIVATE_SERVICE_ACCESS"
  }

  depends_on = [google_service_networking_connection.psa]
}
