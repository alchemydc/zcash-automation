variable "region" {
  description = "DigitalOcean region slug all resources are created in"
  type        = string
}

variable "os_image" {
  description = <<-EOT
    Droplet image slug. Debian 13 is required: the bootstrap installs Caddy from
    Debian main, which ships it from trixie onward.
  EOT
  type        = string
  default     = "debian-13-x64"
}

variable "project_name" {
  description = "DigitalOcean project the droplet and volume are assigned to"
  type        = string
  default     = "zcash-vote"
}

variable "project_environment" {
  description = "DigitalOcean project environment label"
  type        = string
  default     = "Production"

  validation {
    condition     = contains(["Development", "Staging", "Production"], var.project_environment)
    error_message = "project_environment must be Development, Staging or Production."
  }
}

variable "vpc_name" {
  description = "Name of the VPC the droplet joins"
  type        = string
  default     = "zcash-vote"
}

variable "ssh_key_fingerprints" {
  description = <<-EOT
    Fingerprints of DigitalOcean SSH keys authorised on the droplet. Upload the
    operators' public keys once (console, or `doctl compute ssh-key import`) and
    reference them here: they are account-level objects shared across operators
    and outlive this module, so Terraform does not manage them.

    List them with: doctl compute ssh-key list
  EOT
  type        = list(string)
}

variable "vote_validator_enabled" {
  description = "Whether to provision the vote validator at all"
  type        = bool
  default     = false
}

variable "vote_validator_hostname" {
  description = "Droplet name for the vote validator"
  type        = string
  default     = "zcash-vote-validator"
}

variable "vote_validator_droplet_size" {
  description = <<-EOT
    DigitalOcean size slug. A partner running this chain confirms Basic AMD
    4 vCPU / 16 GB / 200 GB is sufficient; the workload is not CPU intensive.
    Confirm the current slug with `doctl compute size list`.
  EOT
  type        = string
  default     = "s-4vcpu-16gb-amd"
}

variable "vote_validator_ssh_source_ranges" {
  description = <<-EOT
    Source ranges permitted to reach :22. Open by default: this validator is
    administered by several operators on dynamic addresses, so the accepted
    control is pubkey-only authentication rather than an address allowlist.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "vote_validator_tags" {
  description = "DigitalOcean tags applied to the droplet, volume and firewall"
  type        = list(string)
  default     = ["zcash-vote-validator"]
}

variable "vote_validator_data_disk_name" {
  description = <<-EOT
    Block storage volume name. Load-bearing: the bootstrap locates the device at
    /dev/disk/by-id/scsi-0DO_Volume_<name>, and long names are truncated there.
  EOT
  type        = string
  default     = "svote-data"
}

variable "vote_validator_data_disk_size" {
  description = "Size (in GB) of the block storage volume"
  type        = number
  default     = 120
}

variable "vote_validator_data_volume_snapshot_id" {
  description = <<-EOT
    Optional volume snapshot to build the data volume from, for rebuilding onto
    existing state. The snapshot carries the validator signing key, so a rebuilt
    host must replace the original rather than run alongside it.
  EOT
  type        = string
  default     = null
}

variable "vote_validator_svote_mount_path" {
  description = "Host path where the data volume is mounted; doubles as the svote user's home"
  type        = string
  default     = "/var/lib/svote"
}

variable "vote_validator_svote_env" {
  description = "Which Valar Group network to join: prod (zvote-1) or stage (svote-1)"
  type        = string
  default     = "prod"
}

variable "vote_validator_upgrade_mode" {
  description = "How svoted is started under systemd: cosmovisor or direct"
  type        = string
  default     = "cosmovisor"
}

variable "vote_validator_tls_domain" {
  description = <<-EOT
    Public DNS hostname Caddy obtains a certificate for. Leave empty to derive an
    sslip.io name from the droplet's own IP at boot. Set a real hostname for a
    long-lived validator: this is the URL published in the voting config.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_helper_api_port" {
  description = "Local port the chain REST / helper API listens on"
  type        = number
  default     = 1317
}

variable "vote_validator_p2p_port" {
  description = "CometBFT P2P port"
  type        = number
  default     = 26656
}

variable "vote_validator_join_script_url" {
  description = "URL of Valar Group's validator join installer"
  type        = string
  default     = "https://shielded-vote.nyc3.digitaloceanspaces.com/join.sh"
}

variable "vote_validator_join_script_sha256" {
  description = "Expected SHA-256 of the join installer; empty skips the check"
  type        = string
  default     = ""
}

variable "vote_validator_join_timeout_seconds" {
  description = "Cap on how long the upstream installer may run"
  type        = number
  default     = 3600
}

variable "vote_validator_moniker" {
  description = "The validator's public name. A name, not a hostname."
  type        = string
  default     = ""
}

variable "vote_validator_svote_admin_url" {
  description = "Base URL of Valar Group's admin API; empty derives it from the chain id"
  type        = string
  default     = ""
}

variable "vote_validator_allow_binary_autodownload" {
  description = <<-EOT
    Let cosmovisor download the upgrade binary named in an on-chain upgrade plan,
    always with DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true. See
    docs/svote-installer-security-analysis.md section 2.11.
  EOT
  type        = bool
  default     = true
}

variable "vote_validator_upgrade_check_on_calendar" {
  description = "systemd OnCalendar expression for the daily upgrade-readiness check"
  type        = string
  default     = "*-*-* 07:20:00"
}

variable "vote_validator_key_backup_age_recipient" {
  description = <<-EOT
    Public age recipient (age1...) key archives are encrypted to. The matching
    identity must never live on the droplet. When empty, key backup fails closed.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_key_backup_on_calendar" {
  description = "systemd OnCalendar expression for the validator key backup timer"
  type        = string
  default     = "*-*-* 03:40:00"
}

variable "vote_validator_key_backup_keep_count" {
  description = "Number of encrypted key archives to keep in the on-host spool"
  type        = number
  default     = 14
}
