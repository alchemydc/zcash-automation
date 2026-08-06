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
  description = "The VPC network name"
}

variable "subnetwork" {
  type        = string
  description = "The self_link of the subnetwork to use"
}

variable "GCP_DEFAULT_SERVICE_ACCOUNT" {
  type        = string
  description = "The default GCP service account used by instances in this project"
}

variable "service_account_scopes" {
  description = "Scopes to apply to the service account"
  type        = list(string)
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
}

variable "hostname_prefix" {
  description = "Instance naming prefix"
  type        = string
  default     = "zcash-vote-validator"
}

variable "instance_type" {
  description = "The GCP instance type"
  type        = string
  default     = "e2-standard-2"
}

variable "instance_count" {
  description = "Number of vote validator instances to provision"
  type        = number
  default     = 1
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the boot disk"
  default     = 20
}

variable "labels" {
  description = "Labels to apply to instances and attached resources"
  type        = map(string)
  default     = {}
}

variable "network_tags" {
  description = "Network tags to apply to instances"
  type        = list(string)
  default     = ["zcash-vote-validator"]
}

variable "seed" {
  description = "CometBFT seed peer address"
  type        = string
  default     = "1b158b43b004ca9a2ef810db4bffbd720c747fe1@100.104.174.21:26656"
}

variable "genesis_url" {
  description = "URL to the CometBFT genesis.json file"
  type        = string
  default     = "https://tinyurl.com/y856k648"
}

variable "zcv_release_tag" {
  description = "GitHub release tag for the zcv vote-cometbft binary"
  type        = string
  default     = "zcvlib-v0.5.0"
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for joining the tailnet"
  type        = string
  sensitive   = true
}
