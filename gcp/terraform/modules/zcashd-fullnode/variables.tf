variable "project" {
  type = string
  description = "The GCP project"
}

variable "region" {
  type = string
  description = "The GCP region"
}

variable "zone" {
  type = string
  description = "The GCP zone"
}

variable "network_name" {
  type = string
  default = "zcash-network"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type = string
  description = "The GCP service account"
}

variable "service_account_scopes" {
  description = "Scopes to apply to the service account which all nodes in the cluster will inherit"
  type        = list(string)

  #scope reference: https://cloud.google.com/sdk/gcloud/reference/alpha/compute/instances/set-scopes#--scopes
  #verify scopes: curl --silent --connect-timeout 1 -f -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/scopes
  default = [
    "https://www.googleapis.com/auth/monitoring.write",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/cloud-platform"         #this gives r/w to all storage buckets, which is overly broad
    ]
}

variable "data_disk_size" {
  type = number
  description = "Size (in GB) of the disk where the parameters and chaindata reside"
  default = 100
}

variable "params_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash parameters"
}

variable "data_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash blockchain"
}

variable fullnode_count {
  description = "Number of full nodes to spin up"
  type = number
}

variable instance_type {
  description = "The GCP instance type to use for this node"
  type = string
}

variable "boot_disk_size" { 
  type = number
  description = "Size (in GB) of the ephemeral boot disk used for all instances"
}