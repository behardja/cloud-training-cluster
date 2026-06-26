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

// VTC nodes have no external IPs, so the subnet MUST have Private Google Access
// enabled or cluster creation fails with: "Subnetwork does not allow private IP
// Google access." The subnet is pre-existing (we don't manage it), so we can't
// flip the flag here — instead we look it up and fail the plan early with the
// exact fix, rather than letting the API reject the create minutes later.
data "google_compute_subnetwork" "subnet" {
  name    = local.network.subnet
  region  = local.region
  project = local.project_id
}

check "subnet_private_google_access" {
  assert {
    condition     = data.google_compute_subnetwork.subnet.private_ip_google_access
    error_message = "Subnet '${local.network.subnet}' (${local.region}) must have Private Google Access enabled. Fix: gcloud compute networks subnets update ${local.network.subnet} --region=${local.region} --enable-private-ip-google-access --project=${local.project_id}"
  }
}

// If instead you let this repo MANAGE the subnet, set the flag directly:
//   resource "google_compute_subnetwork" "subnet" {
//     name                     = local.network.subnet
//     region                   = local.region
//     network                  = data.google_compute_network.vpc.id
//     ip_cidr_range            = "10.150.0.0/20"
//     private_ip_google_access = true   # <-- required for VTC
//   }

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
