variable "replicas" {
  description = "The replica number for each component"
  type        = map(number)

  default = {
    zcashd-archivenode = 0
    zcashd-fullnode    = 0
    zcashd-privatenode = 0
    zebrad-archivenode = 0
  }
}

variable "instance_types" {
  description = "The instance type for each component"
  type        = map(string)

  default = {
    zcashd-archivenode = "e2-standard-4"
    zcashd-fullnode    = "n1-standard-2"
    zcashd-privatenode = "n1-standard-2"
    zebrad-archivenode = "e2-standard-4"
  }
}

variable "project" {
  type        = string
  description = "The GCP project"
}

variable "region" {
  type        = string
  description = "The GCP region"
}

variable "zone" {
  type        = string
  description = "The GCP zone"
}

# GCP "network" not blockchain network
variable "network_name" {
  type    = string
  default = "zcash-network"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type        = string
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
    "https://www.googleapis.com/auth/cloud-platform" #this gives r/w to all storage buckets, which may be overly broad
  ]
}

variable "params_disk_name" {
  type        = string
  description = "name of disk for persisting the Zcash parameters"
  default     = "zcashparams"
}

variable "data_disk_name" {
  type        = string
  description = "name of disk for persisting the Zcash blockchain"
  default     = "zcashdata"
}

variable "data_disk_size" {
  description = "Size (in GB) of the persistent data disk for all nodes"
  type        = number
  default     = 300
}

variable "zebra_params_disk_name" {
  type        = string
  description = "name of disk for persisting the Zcash parameters"
  default     = "zebra-cargo"
}

variable "zebra_data_disk_name" {
  type        = string
  description = "name of disk for persisting the Zcash blockchain"
  default     = "zebra-data"
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the ephemeral boot disk used for all instances"
  default     = 10
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
  default     = "debian-cloud/debian-13"
}

variable "zebra_release_tag" {
  description = "The git tag or release to use when building Zebra"
  type        = string
  default     = "v2.3.0"
}

variable "z3_repo_url" {
  description = "The z3 repository to clone on provisioned z3 hosts"
  type        = string
  default     = "https://github.com/zcashfoundation/z3"
}

variable "z3_repo_ref" {
  description = "The branch, tag, or commit to check out in the z3 repository"
  type        = string
  default     = "dev"
}

variable "z3_boot_disk_size" {
  description = "Size (in GB) of the z3 boot disk used for Docker images, builds, and repo checkout"
  type        = number
  default     = 50
}

variable "z3_data_disk_type" {
  description = "Disk type for the persistent z3 Zebra data disk"
  type        = string
  default     = "pd-standard"
}

variable "z3_mount_path" {
  description = "Host path where the persistent z3 Zebra data disk is mounted"
  type        = string
  default     = "/var/lib/z3/zebra-state"
}

variable "z3_install_rust_toolchain" {
  description = "Whether to install rustup/cargo for the z3 app user"
  type        = bool
  default     = false
}

variable "z3_deployments" {
  description = "Map of z3 deployments keyed by environment name (e.g. mainnet, testnet, regtest)"
  type = map(object({
    network                = string
    replicas               = number
    hostname_prefix        = string
    labels                 = map(string)
    expose_p2p_public      = bool
    install_rust_toolchain = optional(bool)
  }))
  default = {}
}

variable "z3_instance_types" {
  description = "GCP machine type per z3 network (mainnet, testnet, regtest)"
  type        = map(string)
  default = {
    mainnet = "e2-standard-4"
    testnet = "e2-standard-4"
    regtest = "e2-standard-2"
  }
}

variable "z3_data_disk_sizes" {
  description = "Persistent data disk size (GB) per z3 network (mainnet, testnet, regtest)"
  type        = map(number)
  default = {
    mainnet = 350
    testnet = 50
    regtest = 10
  }
}
