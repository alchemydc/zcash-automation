locals {
  # The rendered startup script, delivered through cloud-init.
  #
  # Two DigitalOcean constraints shape this, and both are satisfied by the same
  # cloud-config wrapper:
  #
  #   Size. user_data is capped at 64 KiB (65536 bytes) and the rendered script
  #   sits just under it -- close enough that adding one more function has
  #   already eaten most of the margin once. Compressed it runs at roughly 45%
  #   of the cap, so the limit stops being something to think about on every
  #   edit. If you ever do hit it, the script is the thing to trim, not this.
  #
  #   Re-run semantics. GCE re-ran startup-script metadata on every boot, and
  #   this script is written to depend on that -- it is idempotent and refreshes
  #   the operator tooling whenever the host reboots. cloud-init's scripts-user
  #   stage runs once per instance, so the script is installed into
  #   /var/lib/cloud/scripts/per-boot, which cloud-init executes on every boot.
  #   scripts-per-boot runs before scripts-user within the same stage, so on the
  #   very first boot the symlink does not exist yet; runcmd therefore executes
  #   the script explicitly that once.
  startup_script = templatefile("${path.module}/startup.sh", {
    admin_user                = var.admin_user,
    allow_binary_autodownload = var.allow_binary_autodownload,
    data_disk_name            = var.data_disk_name,
    helper_api_port           = var.helper_api_port,
    hostname                  = var.hostname,
    join_script_sha256        = var.join_script_sha256,
    join_script_url           = var.join_script_url,
    join_timeout_seconds      = var.join_timeout_seconds,
    key_backup_age_recipient  = var.key_backup_age_recipient,
    key_backup_keep_count     = var.key_backup_keep_count,
    key_backup_on_calendar    = var.key_backup_on_calendar,
    module_role               = "zcash-vote-validator",
    moniker                   = var.moniker,
    p2p_port                  = var.p2p_port,
    permit_root_login         = var.permit_root_login,
    restored_from_snapshot    = var.data_volume_snapshot_id != null,
    svote_admin_url           = var.svote_admin_url,
    svote_env                 = var.svote_env,
    svote_mount_path          = var.svote_mount_path,
    tls_domain                = var.tls_domain,
    upgrade_check_on_calendar = var.upgrade_check_on_calendar,
    upgrade_mode              = var.upgrade_mode,
  })

  script_path = "/usr/local/sbin/zcash-vote-validator-startup.sh"

  user_data = <<-EOT
    #cloud-config
    write_files:
      - path: ${local.script_path}
        permissions: '0700'
        owner: root:root
        encoding: gz+b64
        content: ${base64gzip(local.startup_script)}
    runcmd:
      - [ install, -d, -m, '0755', /var/lib/cloud/scripts/per-boot ]
      - [ ln, -sf, ${local.script_path}, /var/lib/cloud/scripts/per-boot/00-zcash-vote-validator ]
      - [ ${local.script_path} ]
  EOT
}

resource "digitalocean_volume" "vote_validator_data" {
  region = var.region

  # The name is load-bearing, not cosmetic: the startup script locates the
  # device at /dev/disk/by-id/scsi-0DO_Volume_<name>, so this must match
  # data_disk_name exactly.
  name                    = var.data_disk_name
  size                    = var.data_disk_size
  initial_filesystem_type = "ext4"
  description             = "Shielded-Vote validator home for ${var.hostname}"
  snapshot_id             = var.data_volume_snapshot_id
  tags                    = var.tags

  lifecycle {
    # Matches the GCE module: once the volume exists, a later change to the
    # snapshot source must not recreate it, because recreating it destroys the
    # validator signing key.
    ignore_changes = [snapshot_id]

    # This volume is the validator. It holds priv_validator_key.json, the
    # operator keyring, and -- unlike the GCE arrangement -- the key backup
    # spool as well, because DigitalOcean has no bucket whose permissions can
    # be narrowed to write-only. On GCE a destroyed disk still left the backups
    # sitting in a prevent_destroy bucket. Here one `tofu destroy` would take
    # the key and every copy of it in the same action.
    #
    # So make it a hard plan error rather than silent, unrecoverable data loss.
    # Decommissioning a validator should be a deliberate act, not a side effect
    # of toggling vote_validator_enabled or tearing down a test.
    #
    # To actually remove it: take a final `svote backup-keys`, copy the archive
    # off-host, verify you can decrypt it with the age identity, then either
    # drop this line or `tofu state rm` the resource and delete it by hand.
    prevent_destroy = true
  }
}

resource "digitalocean_droplet" "vote_validator" {
  name     = var.hostname
  region   = var.region
  size     = var.droplet_size
  image    = var.image
  vpc_uuid = var.vpc_uuid
  ssh_keys = var.ssh_key_fingerprints
  tags     = var.tags

  # Supplies the DigitalOcean droplet agent, which is where host metrics come
  # from now that the Google Ops Agent is gone.
  monitoring = true

  # Volume snapshots are the disaster-recovery story for chain state, and chain
  # state is replaceable from Valar's published snapshot anyway. Droplet backups
  # would image the boot disk, which holds nothing worth keeping.
  backups = false

  # Attached here rather than via a separate digitalocean_volume_attachment so
  # the volume is present when cloud-init first runs. With a separate
  # attachment resource the droplet can boot first, and the startup script would
  # find no device; because cloud-init's user-data phase runs once per instance,
  # that host would never be provisioned at all. The script also waits for the
  # device, so this is belt and braces.
  volume_ids = [digitalocean_volume.vote_validator_data.id]

  user_data = local.user_data

  lifecycle {
    # user_data is ForceNew on this resource: editing the startup script, or any
    # variable templated into it, would otherwise destroy and recreate the
    # droplet -- taking the validator signing key with it. The GCE module put
    # the script in the metadata map precisely to avoid that, and this is the
    # nearest equivalent.
    #
    # The cost is real and deliberate: Terraform no longer manages the script's
    # content after create, so drift is invisible to `plan`. To update a running
    # host, copy the rendered script over and run it:
    #
    #   tofu output -raw vote_validator_startup_script > /tmp/startup.sh   (from do/terraform)
    #   scp /tmp/startup.sh root@<ip>:/usr/local/sbin/zcash-vote-validator-startup.sh
    #   ssh root@<ip> /usr/local/sbin/zcash-vote-validator-startup.sh
    #
    # or simply reboot, since the per-boot hook re-runs whatever is installed.
    ignore_changes = [user_data]
  }
}

resource "digitalocean_firewall" "vote_validator" {
  name        = "${var.hostname}-firewall"
  droplet_ids = [digitalocean_droplet.vote_validator.id]
  tags        = var.tags

  # SSH. Not source-restricted: this validator is administered by several
  # operators on dynamic addresses across large ranges, so an allowlist would be
  # either useless or an outage waiting to happen. The control is pubkey-only
  # authentication, enforced on the host.
  #
  # This is a real reduction from the GCE module, where :22 was reachable only
  # from Google's IAP forwarders and gated by Cloud IAM. Nothing on DigitalOcean
  # replaces that.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_source_ranges
  }

  # :80 is not optional even though the helper API is HTTPS-only: Caddy needs it
  # for the Let's Encrypt HTTP-01 challenge.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # The helper API. This is the port that has to be reachable from Tor exit
  # nodes, which is the reason this module exists on DigitalOcean at all.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.p2p_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # DigitalOcean cloud firewalls are default-deny in BOTH directions, unlike
  # GCP's default-allow egress. Without these rules the droplet cannot reach
  # apt, Let's Encrypt, the GitHub API that install_rage uses, Valar's install
  # and snapshot endpoints, or any P2P peer -- and the failure looks like a
  # hung bootstrap rather than a permissions error. Do not remove them.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ICMP egress, so the host can do useful things like path-MTU discovery.
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
