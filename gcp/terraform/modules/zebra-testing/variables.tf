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
  description = "The VPC network name to use for the Zebra testing node"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type        = string
  description = "The default GCP service account used by instances in this project"
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
  description = "Optional snapshot to restore the persistent state disk from. Set to null/omit for a fresh empty disk."
  default     = null
}

variable "instance_count" {
  description = "Number of Zebra testing nodes to provision"
  type        = number
}

variable "instance_type" {
  description = "The GCP instance type to use for this testing node"
  type        = string
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the boot disk, used for source checkout and build artifacts in source mode"
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
  description = "The Zebra repository to clone on provisioned testing nodes. Only used in source mode."
  type        = string
}

variable "zebra_repo_ref" {
  description = "Branch, tag, or commit to build from source. Empty (default) installs the release binary selected by zebra_release_tag instead."
  type        = string
  default     = ""
}

variable "zebra_git_fetch_ref" {
  description = "Optional explicit git ref to fetch before checkout, for example refs/pull/123/head. Setting this selects source mode."
  type        = string
  default     = ""
}

variable "zebra_release_tag" {
  description = "Zebra GitHub release tag to install (e.g. \"v6.2.2\"). The sentinel \"latest\" resolves at boot via the GitHub releases API. Ignored when zebra_repo_ref or zebra_git_fetch_ref selects a source build."
  type        = string
  default     = "latest"
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

variable "rpc_listen_addr" {
  description = "Zebra JSON-RPC listen address. Defaults to localhost-only. Set to \"\" to disable."
  type        = string
  default     = "127.0.0.1:8232"
}

variable "enable_snapshot_timer" {
  description = "Whether to install and enable a recurring snapshot timer for the Zebra state disk"
  type        = bool
  default     = false
}

variable "snapshot_on_calendar" {
  description = "systemd OnCalendar schedule for state disk snapshots"
  type        = string
  default     = "*-*-* 04:20:00"
}