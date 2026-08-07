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

variable "boot_disk_size" {
  type        = number
  description = "Size (in GB) of the ephemeral boot disk used for all instances"
  default     = 20
}

variable "os_image" {
  type        = string
  description = "The GCP image to use for VM boot disks"
  default     = "debian-cloud/debian-13"
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
  description = "Zebra health endpoint listen address (/healthy and /ready). Set to \"\" to disable."
  type        = string
  default     = "0.0.0.0:8080"
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

variable "zebrad_archivenode_deployments" {
  description = "Map of zebrad-archivenode deployments keyed by environment (e.g. mainnet, testnet). Each entry produces an independent archive node that snapshots its state daily, with labels purpose=zebra-state and network=<lowercased network> so downstream consumers (z3) can discover the right snapshot by network. data_disk_snapshot is optional: set it for restoring a freshly-created disk, or leave null for first-time bootstrap. zebra_release_tag pins the installed release binary; the default \"latest\" resolves the newest published release at boot."
  type = map(object({
    network            = string
    replicas           = number
    data_disk_name     = string
    data_disk_size     = number
    hostname_prefix    = string
    data_disk_snapshot = optional(string)
    zebra_release_tag  = optional(string, "latest")
  }))
  default = {
    mainnet = {
      network            = "Mainnet"
      replicas           = 0
      data_disk_name     = "zebra-data"
      data_disk_size     = 300
      hostname_prefix    = "zebra-archivenode"
      data_disk_snapshot = "zebra-data-0-snapshot-latest"
    }
    testnet = {
      network         = "Testnet"
      replicas        = 0
      data_disk_name  = "zebra-testnet-data"
      data_disk_size  = 100
      hostname_prefix = "zebra-archivenode-testnet"
    }
  }
}

variable "zebra_testing_instance_type" {
  description = "GCP machine type for all zebra-testing deployments"
  type        = string
  default     = "e2-standard-4"
}

variable "zebra_testing_deployments" {
  description = <<-EOT
    Map of zebra-testing deployments keyed by a short slug (e.g. "v6.2.2", "pr-10513").
    Each entry produces an independent zebra-testing deployment. Set replicas > 1 to
    deploy multiple identical copies of one deployment. data_disk_snapshot is optional:
    set it to restore from an existing snapshot, or omit for a fresh empty disk.
    By default each deployment installs the release binary selected by zebra_release_tag
    ("latest" resolves the newest published release at boot). Setting zebra_repo_ref or
    zebra_git_fetch_ref switches that deployment to building from source instead.
  EOT
  type = map(object({
    network             = string
    replicas            = number
    data_disk_name      = string
    data_disk_size      = number
    hostname_prefix     = string
    data_disk_snapshot  = optional(string)
    zebra_release_tag   = optional(string, "latest")
    zebra_repo_url      = optional(string, "https://github.com/ZcashFoundation/zebra")
    zebra_repo_ref      = optional(string, "")
    zebra_git_fetch_ref = optional(string, "")
  }))
  default = {}
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

variable "vote_validator_enabled" {
  description = "Whether to deploy a Valar Group Shielded-Vote validator"
  type        = bool
  default     = false
}

variable "vote_validator_hostname_prefix" {
  description = "Instance naming prefix for the vote validator"
  type        = string
  default     = "zcash-vote-validator"
}

variable "vote_validator_instance_type" {
  description = "GCP machine type for the vote validator. Valar Group recommends 4 vCPU / 8 GB."
  type        = string
  default     = "e2-standard-4"
}

variable "vote_validator_instance_count" {
  description = "Number of vote validator instances. Keep the signing key on exactly one host."
  type        = number
  default     = 1
}

variable "vote_validator_boot_disk_size" {
  description = "Size (in GB) of the vote validator boot disk"
  type        = number
  default     = 20
}

variable "vote_validator_data_disk_size" {
  description = "Size (in GB) of the vote validator data disk. Valar Group recommends 120 GB."
  type        = number
  default     = 120
}

variable "vote_validator_data_disk_type" {
  description = "Disk type for the vote validator data disk"
  type        = string
  default     = "pd-ssd"
}

variable "vote_validator_data_disk_snapshot" {
  description = "Optional snapshot to rebuild the vote validator data disk from"
  type        = string
  default     = null
}

variable "vote_validator_svote_env" {
  description = "Which Valar Group network to join: prod (zvote-1) or stage (svote-1)"
  type        = string
  default     = "prod"
}

variable "vote_validator_upgrade_mode" {
  description = "How svoted runs under systemd: cosmovisor or direct"
  type        = string
  default     = "cosmovisor"
}

variable "vote_validator_tls_domain" {
  description = <<-EOT
    Public hostname Caddy requests a certificate for. Leave empty to derive an
    sslip.io name from the reserved external IP (no DNS record needed). Set this
    to a hostname you control, with an A record pointing at that IP, for anything
    long-lived.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_join_script_sha256" {
  description = <<-EOT
    Expected SHA-256 of Valar Group's join.sh. When set, `svote join` refuses to
    run an installer that does not match. Empty means the digest is printed but
    not enforced.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_moniker" {
  description = <<-EOT
    The validator's public name, e.g. "ZF". Goes into the registration payload and
    the on-chain staking record, so it is a name, not a hostname. `svote join`
    refuses to run while this is empty rather than prompting for it.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_join_timeout_seconds" {
  description = "Cap on how long Valar Group's installer may run before svote join moves on to its post-join steps"
  type        = number
  default     = 3600
}

variable "vote_validator_allow_binary_autodownload" {
  description = <<-EOT
    Let cosmovisor download the upgrade binary named in an on-chain upgrade plan,
    always with DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true. Enabled deliberately: it
    lets chain governance decide which binary runs here, accepted because a
    foundation validator silently dropping out of a vote is worse. Pre-staging with
    `svote prestage-upgrade` remains the primary path. See
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

variable "vote_validator_svote_admin_url" {
  description = <<-EOT
    Base URL of Valar Group's admin API used by `svote register`. Empty derives it
    from the chain id, matching join.sh.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_key_backup_age_recipient" {
  description = <<-EOT
    Public age recipient (age1...) that validator key archives are encrypted to,
    generated off-host with `rage-keygen`. Key backup fails closed while this is
    empty, so set it before joining.
  EOT
  type        = string
  default     = ""
}

variable "vote_validator_key_backup_on_calendar" {
  description = "systemd OnCalendar expression for validator key backups"
  type        = string
  default     = "*-*-* 03:40:00"
}

variable "vote_validator_snapshot_on_calendar" {
  description = "systemd OnCalendar expression for vote validator data disk snapshots"
  type        = string
  default     = "*-*-* 04:40:00"
}

variable "vote_validator_snapshot_retention_count" {
  description = "Number of vote validator data disk snapshots to retain"
  type        = number
  default     = 7
}

variable "vote_validator_p2p_port" {
  description = "Public CometBFT P2P port exposed by the vote validator"
  type        = number
  default     = 26656
}

variable "vote_validator_ssh_source_ranges" {
  description = <<-EOT
    Extra source ranges allowed to SSH to the vote validator, in addition to the
    always-present IAP range. Empty means IAP only.
  EOT
  type        = list(string)
  default     = []
}
