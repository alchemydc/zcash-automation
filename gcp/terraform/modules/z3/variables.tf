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
  description = "The VPC network name to use for the z3 instance"
}

variable "subnetwork" {
  type        = string
  description = "The self_link of the subnetwork to use for the z3 instance"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type        = string
  description = "The default GCP service account used by instances in this project"
}

variable "service_account_scopes" {
  description = "Scopes to apply to the service account which all nodes in the cluster will inherit"
  type        = list(string)
}

variable "deployment_name" {
  description = "Sanitized name for this logical z3 deployment"
  type        = string
}

variable "hostname_prefix" {
  description = "Instance naming prefix used for hosts in this z3 deployment"
  type        = string
}

variable "labels" {
  description = "Labels to apply to z3 instances and attached resources"
  type        = map(string)
}

variable "network_tags" {
  description = "Network tags to apply to z3 instances"
  type        = list(string)
}

variable "instance_count" {
  description = "Number of z3 hosts to provision"
  type        = number
}

variable "instance_type" {
  description = "The GCP instance type to use for this z3 host"
  type        = string
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the z3 boot disk used for Docker images and repo checkout"
}

variable "data_disk_name" {
  type        = string
  description = "Base name of the persistent data disk used for Zebra chain data"
}

variable "data_disk_size" {
  type        = number
  description = "Size (in GB) of the persistent data disk used for Zebra chain data"
}

variable "data_disk_type" {
  type        = string
  description = "Disk type for the persistent data disk used for Zebra chain data"
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
}

variable "z3_repo_url" {
  type        = string
  description = "The z3 repository to clone on provisioned z3 hosts"
}

variable "z3_repo_ref" {
  type        = string
  description = "The branch, tag, or commit to check out in the z3 repository"
}

variable "z3_network" {
  type        = string
  description = "The z3 network to configure. Valid values are mainnet, testnet, or regtest."
}

variable "z3_mount_path" {
  type        = string
  description = "Host path where the persistent z3 Zebra data disk is mounted"
}

variable "install_rust_toolchain" {
  type        = bool
  description = "Whether to install rustup/cargo for the z3 app user"
  default     = true
}

variable "snapshot_enabled" {
  type        = bool
  description = "Whether to install and enable periodic z3 data snapshot tooling on the host"
  default     = true
}

variable "snapshot_retention_count" {
  type        = number
  description = "Number of z3 data snapshots to retain for this host"
  default     = 7
}

variable "snapshot_timer_on_calendar" {
  type        = string
  description = "systemd OnCalendar expression for periodic z3 data snapshots"
  default     = "Sun *-*-* 04:20:00"
}

variable "restore_from_latest_snapshot" {
  type        = bool
  description = "Whether to create z3 data disks from the latest matching snapshot when available"
  default     = true
}