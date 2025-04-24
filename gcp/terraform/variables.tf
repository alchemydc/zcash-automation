variable replicas {
  description = "The replica number for each component"
  type        = map(number)

  default = {
    zcashd-archivenode         = 1
    zcashd-fullnode            = 0
    zcashd-privatenode         = 0 
    zebrad-archivenode         = 0 
  }
}

variable instance_types {
  description = "The instance type for each component"
  type        = map(string)

  default = {
    zcashd-archivenode         = "e2-standard-4"
    zcashd-fullnode            = "n1-standard-2"
    zcashd-privatenode         = "n1-standard-2"
    zebrad-archivenode         = "n1-standard-2"
  }
}

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
    "https://www.googleapis.com/auth/cloud-platform"         #this gives r/w to all storage buckets, which may be overly broad
    ]
}

variable "params_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash parameters"
  default = "zcashparams"
}

variable "data_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash blockchain"
  default = "zcashdata"
}

variable "zebra_params_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash parameters"
  default = "zebra-cargo"
}

variable "zebra_data_disk_name" {
  type = string
  description = "name of disk for persisting the Zcash blockchain"
  default = "zebra-data"
}

variable "boot_disk_size" { 
  type = number
  description = "Size (in GB) of the ephemeral boot disk used for all instances"
  default = 10
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
  default     = "debian-cloud/debian-12"
}
