locals {
  # Caddy needs a DNS name, not a bare IP, to obtain a Let's Encrypt certificate.
  # When no real hostname is supplied we derive an sslip.io name from the
  # reserved external address rather than letting join.sh discover the IP by
  # asking ifconfig.me, which would hand a third party control over which
  # certificate this validator requests.
  tls_domains = [
    for addr in google_compute_address.vote_validator[*].address :
    var.tls_domain != "" ? var.tls_domain : format("%s.sslip.io", replace(addr, ".", "-"))
  ]
}

resource "google_compute_address" "vote_validator" {
  count = var.instance_count
  name  = format("%s-%d-address", var.hostname_prefix, count.index)

  # Static rather than ephemeral: the address appears in the validator's public
  # URL that clients resolve, in the sslip.io certificate name, and in the peer
  # address other validators dial, so it has to survive a stop/start.
  address_type = "EXTERNAL"
}

resource "google_compute_address" "vote_validator_internal" {
  count        = var.instance_count
  name         = format("%s-%d-internal-address", var.hostname_prefix, count.index)
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "vote_validator_data" {
  count    = var.instance_count
  name     = format("%s-%d", var.data_disk_name, count.index)
  type     = var.data_disk_type
  size     = var.data_disk_size
  snapshot = var.data_disk_snapshot

  labels = var.labels

  lifecycle {
    ignore_changes = [snapshot]
  }
}

resource "google_compute_instance" "vote_validator" {
  count        = var.instance_count
  name         = format("%s-%d", var.hostname_prefix, count.index)
  machine_type = var.instance_type
  depends_on   = [google_compute_disk.vote_validator_data]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  attached_disk {
    source      = google_compute_disk.vote_validator_data[count.index].name
    device_name = google_compute_disk.vote_validator_data[count.index].name
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork
    network_ip = google_compute_address.vote_validator_internal[count.index].address

    # A public address is not optional for this workload: the chain only treats a
    # validator as client-ready once its helper API is reachable over public
    # HTTPS, and Let's Encrypt has to reach :80/:443 to issue the certificate.
    access_config {
      nat_ip = google_compute_address.vote_validator[count.index].address
    }
  }

  # startup-script lives in the metadata map (not metadata_startup_script) so
  # script changes update the instance in place instead of forcing replacement,
  # which on this module would mean destroying the validator signing key.
  #
  # This script prepares the host only. It never runs the installer and never
  # touches SVOTE_HOME, so it is safe to re-run on every boot: the operator runs
  # `svote join` interactively once, and join.sh begins with an unconditional
  # `rm -rf $SVOTE_HOME`.
  metadata = {
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
    startup-script = templatefile(
      format("%s/startup.sh", path.module),
      {
        data_disk_name           = google_compute_disk.vote_validator_data[count.index].name,
        enable_snapshot_timer    = var.enable_snapshot_timer,
        gcloud_project           = var.project,
        gcloud_zone              = var.zone,
        helper_api_port          = var.helper_api_port,
        hostname                 = format("%s-%d", var.hostname_prefix, count.index),
        join_script_sha256       = var.join_script_sha256,
        join_script_url          = var.join_script_url,
        key_backup_age_recipient = var.key_backup_age_recipient,
        key_backup_bucket        = var.key_backup_bucket,
        key_backup_on_calendar   = var.key_backup_on_calendar,
        module_role              = "zcash-vote-validator",
        p2p_port                 = var.p2p_port,
        restored_from_snapshot   = var.data_disk_snapshot != null,
        snapshot_on_calendar     = var.snapshot_on_calendar,
        snapshot_retention_count = var.snapshot_retention_count,
        svote_admin_url          = var.svote_admin_url,
        svote_env                = var.svote_env,
        svote_mount_path         = var.svote_mount_path,
        tls_domain               = local.tls_domains[count.index],
        upgrade_mode             = var.upgrade_mode,
      }
    )
  }

  service_account {
    scopes = var.service_account_scopes
  }

  labels = var.labels

  tags = var.network_tags
}
