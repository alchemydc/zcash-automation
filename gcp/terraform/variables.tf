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
    z3                 = "e2-standard-4"
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
  default     = "v4.1.0"
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

variable "z3_deployments" {
  description = "Named z3 deployment groups. Each deployment can target its own network, replicas, labels, and ingress policy, with optional per-deployment overrides for compute and storage sizing."
  type = map(object({
    enabled                      = optional(bool, true)
    network                      = string
    replicas                     = number
    instance_type                = optional(string)
    boot_disk_size               = optional(number)
    data_disk_name               = optional(string)
    data_disk_size               = optional(number)
    data_disk_type               = optional(string)
    hostname_prefix              = optional(string)
    labels                       = optional(map(string), {})
    expose_p2p_public            = optional(bool)
    additional_tags              = optional(list(string), [])
    snapshot_enabled             = optional(bool)
    snapshot_retention_count     = optional(number)
    snapshot_timer_on_calendar   = optional(string)
    restore_from_latest_snapshot = optional(bool)
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, deployment in var.z3_deployments : contains(["mainnet", "testnet", "regtest"], deployment.network)
    ])
    error_message = "Each z3 deployment network must be either mainnet, testnet, or regtest."
  }
}

variable "z3_instance_types" {
  description = "Default z3 instance types keyed by blockchain network name. Used unless a deployment sets its own instance_type override."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for network_name in keys(var.z3_instance_types) : contains(["mainnet", "testnet", "regtest"], network_name)
    ])
    error_message = "z3_instance_types keys must be limited to mainnet, testnet, and regtest."
  }
}

variable "z3_boot_disk_size" {
  description = "Size (in GB) of the z3 boot disk used for Docker images, builds, and repo checkout"
  type        = number
  default     = 50
}

variable "z3_data_disk_name" {
  description = "Base name of the persistent z3 Zebra data disk"
  type        = string
  default     = "z3-zebra-data"
}

variable "z3_data_disk_size" {
  description = "Size (in GB) of the persistent z3 Zebra data disk"
  type        = number
  default     = 500
}

variable "z3_data_disk_sizes" {
  description = "Default z3 data disk sizes in GB keyed by blockchain network name. Used unless a deployment sets its own data_disk_size override."
  type        = map(number)
  default     = {}

  validation {
    condition = alltrue([
      for network_name in keys(var.z3_data_disk_sizes) : contains(["mainnet", "testnet", "regtest"], network_name)
    ])
    error_message = "z3_data_disk_sizes keys must be limited to mainnet, testnet, and regtest."
  }
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

variable "z3_snapshot_timer_on_calendar" {
  description = "Default systemd OnCalendar schedule for z3 data snapshots"
  type        = string
  default     = "Sun *-*-* 04:20:00"
}

variable "z3_snapshot_retention_count" {
  description = "Default number of z3 data snapshots to retain per deployment host"
  type        = number
  default     = 7
}

variable "z3_restore_from_latest_snapshot" {
  description = "Whether z3 data disks should restore from the latest matching snapshot when one exists"
  type        = bool
  default     = true
}
