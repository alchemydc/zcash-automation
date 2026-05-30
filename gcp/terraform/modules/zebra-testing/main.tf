resource "google_compute_address" "zebra_testing" {
  count        = var.instance_count
  name         = format("%s-%d-address", var.hostname_prefix, count.index)
  address_type = "EXTERNAL"
}

resource "google_compute_address" "zebra_testing_internal" {
  count        = var.instance_count
  name         = format("%s-%d-internal-address", var.hostname_prefix, count.index)
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "zebra_state" {
  count    = var.instance_count
  name     = format("%s-%d", var.data_disk_name, count.index)
  type     = var.data_disk_type
  size     = var.data_disk_size
  snapshot = var.data_disk_snapshot

  lifecycle {
    ignore_changes = [snapshot]
  }
}

resource "google_compute_instance" "zebra_testing" {
  count        = var.instance_count
  name         = format("%s-%d", var.hostname_prefix, count.index)
  machine_type = var.instance_type
  depends_on   = [google_compute_disk.zebra_state]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.boot_disk_size
    }
  }

  attached_disk {
    source      = google_compute_disk.zebra_state[count.index].name
    device_name = google_compute_disk.zebra_state[count.index].name
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork
    network_ip = google_compute_address.zebra_testing_internal[count.index].address

    access_config {
      nat_ip = google_compute_address.zebra_testing[count.index].address
    }
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module),
    {
      data_disk_name         = google_compute_disk.zebra_state[count.index].name,
      enable_snapshot_timer  = var.enable_snapshot_timer,
      gcloud_project         = var.project,
      gcloud_zone            = var.zone,
      health_listen_addr     = var.health_listen_addr,
      hostname               = format("%s-%d", var.hostname_prefix, count.index),
      metrics_endpoint_addr  = var.metrics_endpoint_addr,
      module_role            = "zebra-testing",
      snapshot_on_calendar   = var.snapshot_on_calendar,
      zebra_listen_addr      = var.zebra_listen_addr,
      zebra_listen_port      = element(split(":", var.zebra_listen_addr), length(split(":", var.zebra_listen_addr)) - 1),
      zebra_network          = var.zebra_network,
      zebra_repo_ref         = var.zebra_repo_ref,
      zebra_repo_url         = var.zebra_repo_url,
      zebra_git_fetch_ref    = var.zebra_git_fetch_ref,
      zebra_state_mount_path = var.zebra_state_mount_path,
    }
  )

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "zebra-testing",
  ]
}