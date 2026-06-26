// Private Services Access (PSA) — required for Filestore to attach to your VPC
// (PDF Step 2.4). This is the Terraform equivalent of the guide's
// `gcloud compute addresses create ... && gcloud services vpc-peerings connect`.
//
// The VPC + subnet themselves are assumed to already exist (VTC does not create
// them); we look the network up by name from the config.

data "google_compute_network" "vpc" {
  name    = local.network.vpc
  project = local.project_id
}

// Reserved IP range Google's managed services (Filestore) peer into. Don't let
// this overlap your existing subnets.
resource "google_compute_global_address" "psa_range" {
  name          = "google-managed-services-${local.network.vpc}"
  project       = local.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = local.network.psa_prefix_length
  network       = data.google_compute_network.vpc.id

  depends_on = [google_project_service.required]
}

// The peering connection itself.
resource "google_service_networking_connection" "psa" {
  network                 = data.google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]

  depends_on = [google_project_service.required]
}
