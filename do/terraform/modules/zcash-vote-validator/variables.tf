variable "region" {
  type        = string
  description = "The DigitalOcean region slug (e.g. nyc3)"
}

variable "vpc_uuid" {
  type        = string
  description = "UUID of the VPC the droplet joins"
}

variable "image" {
  type        = string
  description = <<-EOT
    DigitalOcean image slug for the droplet. Debian 13 is required, not merely
    preferred: the bootstrap installs Caddy from Debian main, which ships it
    from trixie onward. On Debian 12 the base package install fails outright.
  EOT
  default     = "debian-13-x64"
}

variable "hostname" {
  description = "Droplet name, also used for the volume description and the login banner"
  type        = string
  default     = "zcash-vote-validator"
}

variable "droplet_size" {
  description = <<-EOT
    DigitalOcean size slug. Valar Group's recommended production spec is 4 vCPU
    / 8 GB; a partner running this chain confirms Basic AMD 4 vCPU / 16 GB /
    200 GB is sufficient. Confirm the current slug with `doctl compute size list`
    before changing it -- DigitalOcean's naming is not stable across generations.
  EOT
  type        = string
  default     = "s-4vcpu-16gb-amd"
}

variable "ssh_key_fingerprints" {
  description = <<-EOT
    Fingerprints of DigitalOcean SSH keys authorised on the droplet. These are
    account-level objects that outlive this module and are shared across
    operators, so they are referenced rather than managed here.

    Must not be empty: DigitalOcean emails a root password for a droplet created
    with no keys, which is exactly the credential this host should not have.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_key_fingerprints) > 0
    error_message = "At least one SSH key fingerprint is required; otherwise DigitalOcean provisions a root password."
  }
}

variable "admin_user" {
  description = <<-EOT
    Non-root login account created on the droplet, seeded with root's authorised
    keys and granted passwordless sudo. Empty disables it, leaving the host
    root-only.

    It has to be created here because DigitalOcean only ever populates root's
    authorized_keys -- no other account gets a key unless this module copies one.
    Keys are merged rather than overwritten, so a key added by hand survives a
    re-run and a key later added to root is picked up.
  EOT
  type        = string
  default     = "svoteadmin"
}

variable "permit_root_login" {
  description = <<-EOT
    sshd PermitRootLogin value. "prohibit-password" is key-only root, which is
    the safe default because DigitalOcean's injected key is initially the only
    way in.

    Set to "no" only after confirming you can log in as admin_user and sudo. The
    bootstrap refuses to apply "no" while that account is missing or has no
    authorized key, falling back to prohibit-password rather than locking the
    host out -- but do not lean on that guard.
  EOT
  type        = string
  default     = "prohibit-password"

  validation {
    condition     = contains(["prohibit-password", "no"], var.permit_root_login)
    error_message = "permit_root_login must be \"prohibit-password\" or \"no\"."
  }
}

variable "ssh_source_ranges" {
  description = <<-EOT
    Source ranges permitted to reach :22. Defaults to open, because this
    validator is administered by several operators on dynamic addresses across
    large ranges; the accepted control is pubkey-only authentication on the
    host, not an address allowlist.

    Narrow this if your operators ever get stable addresses. Note the GCE module
    this replaces reached :22 only through Google's IAP forwarders under Cloud
    IAM, and DigitalOcean has no equivalent -- so this is a known reduction.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "tags" {
  description = "DigitalOcean tags applied to the droplet, volume and firewall"
  type        = list(string)
  default     = ["zcash-vote-validator"]
}

variable "data_disk_name" {
  type        = string
  description = <<-EOT
    Name of the block storage volume holding the validator home directory.

    Load-bearing: the bootstrap locates the device at
    /dev/disk/by-id/scsi-0DO_Volume_<name>. DigitalOcean volume names must be
    lowercase alphanumeric or hyphens and must start with a letter, and a long
    name is truncated in the by-id path, so keep this short.
  EOT
  default     = "svote-data"
}

variable "data_disk_size" {
  type        = number
  description = "Size (in GB) of the block storage volume. Valar Group recommends 120 GB."
  default     = 120
}

variable "data_volume_snapshot_id" {
  type        = string
  description = <<-EOT
    Optional volume snapshot to create the data volume from, for rebuilding a
    validator host onto its existing state. The snapshot carries the validator
    signing key, so a rebuilt host must replace the original rather than run
    alongside it.
  EOT
  default     = null
}

variable "svote_mount_path" {
  description = <<-EOT
    Host path where the data volume is mounted. This doubles as the svote user's
    home directory, so SVOTE_HOME becomes <path>/.svoted.
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
    the helper API. Leave empty to derive an sslip.io name from the droplet's own
    public IP, which needs no DNS record. Point this at a real hostname (whose A
    record you manage yourself) for a long-lived validator: sslip.io both
    discloses the IP and makes certificate renewal depend on a third-party
    wildcard DNS service.

    Unlike the GCE module, the sslip.io fallback is resolved on the host at boot
    rather than in Terraform. A droplet's address is an attribute of the droplet
    itself, so deriving the name here would make user_data depend on the
    resource user_data configures.
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

variable "moniker" {
  description = <<-EOT
    The validator's public name. It goes into the registration payload, the join
    queue, and the on-chain staking record when the wrapper bonds, so it is this
    deployment's public identity — a name, not a hostname.

    Declared here rather than left to the installer's interactive prompt: the
    prompt appears immediately after `svote join` reports the preset TLS domain,
    which makes answering it with the hostname an easy and expensive mistake.
    `svote join` refuses to run while this is empty.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.moniker == "" || !can(regex("\\.", var.moniker))
    error_message = "moniker looks like a hostname. Use a validator name (e.g. \"ZF\"), not a DNS name."
  }
}

variable "join_timeout_seconds" {
  description = <<-EOT
    Cap on how long the upstream installer may run. It ends with an unbounded
    "wait for sync" loop, so a node that cannot start leaves it spinning forever;
    on timeout `svote join` carries on to its post-join steps, which is what
    surfaces the registration details and the key backup prompt.
  EOT
  type        = number
  default     = 3600
}

variable "allow_binary_autodownload" {
  description = <<-EOT
    Let cosmovisor download the upgrade binary named in an on-chain upgrade plan,
    always with DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true.

    This is a deliberate tradeoff, not a default worth changing casually. Enabling
    it means chain governance decides which binary runs on this host: the checksum
    travels in the governance proposal itself, so requiring one proves integrity
    against the proposal, not against governance. It is enabled because a
    foundation validator silently dropping out of a vote is the worse outcome. See
    docs/svote-installer-security-analysis.md section 2.11.

    It is a fallback, not the plan: pre-stage with `svote prestage-upgrade`. It also
    cannot cover every case — plans whose `info` carries no `binaries` map (such as
    the already-applied `v1`) are not downloadable, which is why
    svote-stage-upgrades still exists.
  EOT
  type        = bool
  default     = true
}

variable "upgrade_check_on_calendar" {
  description = "systemd OnCalendar expression for the daily upgrade-readiness check"
  type        = string
  default     = "*-*-* 07:20:00"
}

variable "svote_admin_url" {
  description = <<-EOT
    Base URL of Valar Group's admin API, which `svote register` POSTs the signed
    registration to. Empty derives it from the chain id exactly as join.sh does
    (zvote-1 -> https://prod.svote.valargroup.org), which is what you want unless
    you are joining a non-default deployment.
  EOT
  type        = string
  default     = ""
}

variable "key_backup_age_recipient" {
  description = <<-EOT
    Public age recipient (age1...) that key archives are encrypted to, generated
    off-host with `rage-keygen`. The matching identity must never live on the
    droplet. When empty, key backup fails closed rather than writing plaintext
    signing keys.
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

variable "key_backup_keep_count" {
  description = <<-EOT
    Number of encrypted key archives to keep in the on-host spool; older ones are
    pruned.

    Archives are written locally and never uploaded. On GCE they went straight to
    a bucket where the instance held objectCreator and nothing else, so it could
    add backups but never rewrite or destroy its history. DigitalOcean Spaces
    cannot express that -- per-bucket keys are read, readwrite or fullaccess, and
    a readwrite key can delete -- so rather than hold a credential that weakens
    the guarantee, this host holds none and the archives are collected off-host.
    A spool that has never been collected is not a backup.
  EOT
  type        = number
  default     = 14
}
