// Root inputs. The cluster shape (machine types, accelerators, fallback order,
// Gemma recipe) is NOT here — it lives in ../configs/cluster_config.yaml and is
// read via yamldecode in main.tf. These variables are the few project-wide knobs
// plus the feature gates that keep a first `apply` safe.

variable "project_id" {
  type        = string
  description = "GCP project that hosts the cluster + Filestore + bucket. Overrides project.id in configs/cluster_config.yaml."
  default     = ""
}

variable "region" {
  type        = string
  description = "VTC region. Overrides project.region in the config."
  default     = ""
}

// --- Feature gates -----------------------------------------------------------
// Supporting infra (APIs, PSA, Filestore, bucket) always applies. The cluster
// itself — which calls the v1beta1 Preview API and can take many minutes /
// consume scarce accelerators — is gated OFF so a first apply just stands up the
// plumbing. Flip create_cluster=true when you're ready to provision hardware.

variable "create_cluster" {
  type        = bool
  description = "Run scripts/create_cluster.sh (walks the fallback chain, POSTs the v1beta1 create, polls the LRO) via local-exec. Needs gcloud auth where terraform runs. Leave false to provision only the supporting infra."
  default     = false
}

variable "cluster_id" {
  type        = string
  description = "VTC cluster id (<= 10 chars, unique). Empty = derived from workload.model in the config."
  default     = ""
}

variable "profiles" {
  type        = string
  description = "Comma-separated subset/override of the fallback chain to try, in order (e.g. \"a4b200,cpu\"). Empty = the full fallback_chain from the config."
  default     = ""
}
