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

variable "network_name" {
  type        = string
  description = "The VPC network name to use for the Zebra archive node"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type        = string
  description = "The GCP service account"
}

variable "service_account_scopes" {
  description = "Scopes to apply to the service account which all nodes in the cluster will inherit"
  type        = list(string)
}

variable "data_disk_size" {
  type        = number
  description = "Size (in GB) of the persistent state disk"
}

variable "data_disk_name" {
  type        = string
  description = "Base name of the persistent state disk"
}

variable "data_disk_type" {
  type        = string
  description = "Disk type for the persistent state disk"
}

variable "data_disk_snapshot" {
  type        = string
  description = "Optional snapshot to restore the persistent state disk from"
  default     = null
}

variable "instance_count" {
  description = "Number of archive nodes to provision"
  type        = number
}

variable "instance_type" {
  description = "The GCP instance type to use for this node"
  type        = string
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the boot disk used for source checkout and build artifacts"
}

variable "subnetwork" {
  type        = string
  description = "The self_link of the subnetwork to use for internal addresses"
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
}

variable "hostname_prefix" {
  type        = string
  description = "Prefix used for GCP resource names (instances, disks, addresses)"
}

variable "zebra_repo_url" {
  description = "The Zebra repository to clone on provisioned archive nodes"
  type        = string
}

variable "zebra_repo_ref" {
  description = "The branch, tag, or commit to check out in the Zebra repository. The sentinel \"latest-release\" resolves at startup to the most recent v* tag on the remote."
  type        = string
  default     = "latest-release"
}

variable "zebra_git_fetch_ref" {
  description = "Optional explicit git ref to fetch before checkout, for example refs/pull/123/head"
  type        = string
  default     = ""
}

variable "zebra_network" {
  description = "The Zebra network name, such as Mainnet, Testnet, or Regtest"
  type        = string
}

variable "zebra_listen_addr" {
  description = "The Zebra P2P listen address"
  type        = string
}

variable "zebra_state_mount_path" {
  description = "Host path where the persistent Zebra state disk is mounted"
  type        = string
}

variable "metrics_endpoint_addr" {
  description = "Optional Zebra metrics endpoint listen address"
  type        = string
  default     = ""
}

variable "health_listen_addr" {
  description = "Zebra health endpoint listen address (/healthy and /ready). Set to \"\" to disable."
  type        = string
  default     = "0.0.0.0:8080"
}

variable "enable_snapshot_timer" {
  description = "Whether to install and enable a recurring snapshot timer for the Zebra state disk"
  type        = bool
  default     = true
}

variable "snapshot_on_calendar" {
  description = "systemd OnCalendar schedule for state disk snapshots"
  type        = string
  default     = "*-*-* 04:20:00"
}
