variable "replicas" {
  description = "The replica number for each component"
  type        = map(number)

  default = {
    zcashd-archivenode = 0
    zcashd-fullnode    = 0
    zcashd-privatenode = 0
    zebrad-archivenode = 0
    zebra-testing      = 0
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
    zebra-testing      = "e2-standard-4"
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

variable "zebra_data_disk_name" {
  type        = string
  description = "name of disk for persisting the Zcash blockchain"
  default     = "zebra-data"
}

variable "zebra_archivenode_data_disk_size" {
  description = "Size (in GB) of the persistent state disk used by zebrad-archivenode"
  type        = number
  default     = 300
}

variable "zebra_testing_data_disk_name" {
  type        = string
  description = "Base name of the persistent state disk used by the zebra-testing module"
  default     = "zebra-testing-data"
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

variable "zebra_repo_url" {
  description = "The Zebra repository to clone on provisioned zebra-testing hosts"
  type        = string
  default     = "https://github.com/ZcashFoundation/zebra"
}

variable "zebra_repo_ref" {
  description = "The branch, tag, or commit to check out in the Zebra repository for zebra-testing"
  type        = string
  default     = "main"
}

variable "zebra_git_fetch_ref" {
  description = "Optional explicit git ref to fetch before checkout for zebra-testing, for example refs/pull/123/head"
  type        = string
  default     = ""
}

variable "zebra_network" {
  description = "The Zebra network name, such as Mainnet, Testnet, or Regtest"
  type        = string
  default     = "Mainnet"
}

variable "zebra_p2p_port" {
  description = "The public P2P port exposed by Zebra hosts"
  type        = number
  default     = 8233
}

variable "zebra_data_disk_type" {
  description = "Disk type for persistent Zebra state disks"
  type        = string
  default     = "pd-standard"
}

variable "zebra_state_mount_path" {
  description = "Host path where the persistent Zebra state disk is mounted"
  type        = string
  default     = "/var/lib/zebra/state"
}

variable "zebra_metrics_endpoint_addr" {
  description = "Optional Zebra metrics endpoint listen address"
  type        = string
  default     = ""
}

variable "zebra_health_listen_addr" {
  description = "Optional Zebra health endpoint listen address"
  type        = string
  default     = ""
}

variable "zebra_public_ssh_source_ranges" {
  description = "Optional public SSH source ranges for zebrad-archivenode and zebra-testing. Leave empty to require IAP tunneling only."
  type        = list(string)
  default     = []
}

variable "zebra_archivenode_snapshot_on_calendar" {
  description = "systemd OnCalendar schedule for zebrad-archivenode state snapshots"
  type        = string
  default     = "*-*-* 04:20:00"
}

variable "zebra_archivenode_data_disk_snapshot" {
  description = "Optional snapshot to restore zebrad-archivenode state from"
  type        = string
  default     = null
}

variable "zebra_testing_data_disk_snapshot" {
  description = "Optional snapshot to restore zebra-testing state from. Leave null to create an empty state disk."
  type        = string
  default     = null
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
