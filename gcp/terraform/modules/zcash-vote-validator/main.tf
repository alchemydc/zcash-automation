resource "google_compute_address" "vote_validator_internal" {
  count        = var.instance_count
  name         = format("%s-%d-internal-address", var.hostname_prefix, count.index)
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_instance" "vote_validator" {
  count        = var.instance_count
  name         = format("%s-%d", var.hostname_prefix, count.index)
  machine_type = var.instance_type

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.boot_disk_size
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork
    network_ip = google_compute_address.vote_validator_internal[count.index].address
  }

  metadata = {
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
    startup-script = templatefile(
      format("%s/startup.sh", path.module),
      {
        hostname_prefix    = var.hostname_prefix,
        instance_index     = count.index,
        seed               = var.seed,
        genesis_url        = var.genesis_url,
        zcv_release_tag    = var.zcv_release_tag,
        tailscale_auth_key = var.tailscale_auth_key,
      }
    )
  }

  service_account {
    scopes = var.service_account_scopes
  }

  labels = var.labels

  tags = var.network_tags
}
