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
  description = <<-EOT
    The GCP instance type. Valar Group's recommended production spec is 4 vCPU /
    8 GB RAM; e2-standard-4 is 4 vCPU / 16 GB, i.e. the smallest predefined type
    that satisfies it. Use e2-custom-4-8192 to match the spec exactly for less
    money.
  EOT
  type        = string
  default     = "e2-standard-4"
}

variable "instance_count" {
  description = <<-EOT
    Number of vote validator instances to provision. Valar Group's guidance is to
    keep the validator signing key live on exactly one host, so this is normally
    1; higher values are for running validators on separate independent chains,
    not for redundancy of a single validator identity.
  EOT
  type        = number
  default     = 1
}

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the boot disk. Chain state lives on the data disk, not here."
  default     = 20
}

variable "boot_disk_type" {
  type        = string
  description = "Disk type for the boot disk"
  default     = "pd-balanced"
}

variable "data_disk_name" {
  type        = string
  description = "Base name of the persistent data disk holding the validator home directory"
  default     = "svote-data"
}

variable "data_disk_size" {
  type        = number
  description = "Size (in GB) of the persistent data disk. Valar Group recommends 120 GB."
  default     = 120
}

variable "data_disk_type" {
  type        = string
  description = "Disk type for the persistent data disk. Valar Group recommends NVMe-class storage."
  default     = "pd-ssd"
}

variable "data_disk_snapshot" {
  type        = string
  description = <<-EOT
    Optional snapshot to create the data disk from, for rebuilding a validator
    host onto its existing state. The snapshot carries the validator signing key,
    so a rebuilt host must replace the original rather than run alongside it.
  EOT
  default     = null
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

variable "svote_mount_path" {
  description = <<-EOT
    Host path where the persistent data disk is mounted. This doubles as the
    svote user's home directory, so SVOTE_HOME becomes <path>/.svoted.
  EOT
  type        = string
  default     = "/var/lib/svote"
}

variable "svote_env" {
  description = "Which Valar Group network to join: prod (zvote-1) or stage (svote-1)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "stage"], var.svote_env)
    error_message = "svote_env must be either \"prod\" or \"stage\"."
  }
}

variable "upgrade_mode" {
  description = <<-EOT
    How svoted is started under systemd: "cosmovisor" (upstream default on Linux,
    supports staged coordinated upgrades) or "direct".
  EOT
  type        = string
  default     = "cosmovisor"

  validation {
    condition     = contains(["cosmovisor", "direct"], var.upgrade_mode)
    error_message = "upgrade_mode must be either \"cosmovisor\" or \"direct\"."
  }
}

variable "tls_domain" {
  description = <<-EOT
    Public DNS hostname Caddy obtains a Let's Encrypt certificate for, fronting
    the helper API. Leave empty to derive an sslip.io name from the instance's
    reserved external IP, which needs no DNS record. Point this at a real
    hostname (whose A record you manage yourself) for a long-lived validator:
    sslip.io both discloses the IP and makes certificate renewal depend on a
    third-party wildcard DNS service.
  EOT
  type        = string
  default     = ""
}

variable "helper_api_port" {
  description = "Local port the chain REST / helper API listens on, reverse-proxied by Caddy"
  type        = number
  default     = 1317
}

variable "p2p_port" {
  description = "CometBFT P2P port"
  type        = number
  default     = 26656
}

variable "join_script_url" {
  description = "URL of Valar Group's validator join installer"
  type        = string
  default     = "https://shielded-vote.nyc3.digitaloceanspaces.com/join.sh"
}

variable "join_script_sha256" {
  description = <<-EOT
    Expected SHA-256 of join_script_url. When set, `svote join` refuses to run an
    installer that does not match. When empty it prints the observed digest and
    continues, which is the fast path but leaves the DigitalOcean Spaces bucket
    as an unauthenticated source of root-equivalent code. See
    docs/svote-installer-security-analysis.md.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.join_script_sha256 == "" || can(regex("^[0-9a-fA-F]{64}$", var.join_script_sha256))
    error_message = "join_script_sha256 must be empty or a 64-character hex SHA-256 digest."
  }
}

variable "key_backup_bucket" {
  description = <<-EOT
    GCS bucket that encrypted validator key archives are uploaded to. The
    instance service account should hold objectCreator on it and nothing more,
    so a compromised validator cannot read its own backup history back.
  EOT
  type        = string
}

variable "key_backup_age_recipient" {
  description = <<-EOT
    Public age recipient (age1...) that key archives are encrypted to, generated
    off-host with `rage-keygen`. The matching identity must never live on the
    instance. When empty, key backup fails closed rather than uploading
    plaintext signing keys.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.key_backup_age_recipient == "" || startswith(var.key_backup_age_recipient, "age1")
    error_message = "key_backup_age_recipient must be empty or an age recipient starting with \"age1\"."
  }
}

variable "key_backup_on_calendar" {
  description = "systemd OnCalendar expression for the validator key backup timer"
  type        = string
  default     = "*-*-* 03:40:00"
}

variable "enable_snapshot_timer" {
  description = <<-EOT
    Whether `svote join` enables the daily data disk snapshot timer once the
    validator exists. Snapshotting stops svoted briefly, so it cannot be enabled
    before the join completes.
  EOT
  type        = bool
  default     = true
}

variable "snapshot_on_calendar" {
  description = "systemd OnCalendar expression for the data disk snapshot timer"
  type        = string
  default     = "*-*-* 04:40:00"
}

variable "snapshot_retention_count" {
  description = "Number of timestamped data disk snapshots to keep; older ones are pruned"
  type        = number
  default     = 7
}
