data "external" "z3_restore_snapshot" {
  count = var.restore_from_latest_snapshot ? var.instance_count : 0

  program = [
    "bash",
    "${path.root}/scripts/get_latest_z3_snapshot.sh",
    var.project,
    var.deployment_name,
    var.z3_network,
    format("%s-%d", var.data_disk_name, count.index),
  ]

  query = {}
}

locals {
  z3_restore_snapshot_names = var.restore_from_latest_snapshot ? [
    for snapshot in data.external.z3_restore_snapshot : snapshot.result.snapshot_name
  ] : [for _ in range(var.instance_count) : ""]

  z3_restore_snapshot_sizes_gb = var.restore_from_latest_snapshot ? [
    for snapshot in data.external.z3_restore_snapshot : tonumber(snapshot.result.snapshot_size_gb)
  ] : [for _ in range(var.instance_count) : 0]
}

resource "google_compute_address" "z3" {
  count        = var.instance_count
  name         = format("%s-%d-address", var.hostname_prefix, count.index)
  address_type = "EXTERNAL"
  labels       = var.labels
}

resource "google_compute_address" "z3_internal" {
  count        = var.instance_count
  name         = format("%s-%d-internal-address", var.hostname_prefix, count.index)
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  purpose      = "GCE_ENDPOINT"
  labels       = var.labels
}

resource "google_compute_disk" "z3_data" {
  count    = var.instance_count
  name     = format("%s-%d", var.data_disk_name, count.index)
  type     = var.data_disk_type
  size     = max(var.data_disk_size, local.z3_restore_snapshot_sizes_gb[count.index])
  snapshot = local.z3_restore_snapshot_names[count.index] != "" ? local.z3_restore_snapshot_names[count.index] : null
  labels   = var.labels
}

resource "google_compute_instance" "z3" {
  count        = var.instance_count
  name         = format("%s-%d", var.hostname_prefix, count.index)
  machine_type = var.instance_type
  depends_on   = [google_compute_disk.z3_data]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.boot_disk_size
    }
  }

  attached_disk {
    source      = google_compute_disk.z3_data[count.index].name
    device_name = google_compute_disk.z3_data[count.index].name
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork
    network_ip = google_compute_address.z3_internal[count.index].address

    access_config {
      nat_ip = google_compute_address.z3[count.index].address
    }
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module),
    {
      data_disk_name             = google_compute_disk.z3_data[count.index].name,
      deployment_name            = var.deployment_name,
      gcloud_project             = var.project,
      install_rust_toolchain     = var.install_rust_toolchain,
      snapshot_enabled           = tostring(var.snapshot_enabled),
      snapshot_retention_count   = tostring(var.snapshot_retention_count),
      snapshot_timer_on_calendar = var.snapshot_timer_on_calendar,
      z3_mount_path              = var.z3_mount_path,
      z3_network                 = var.z3_network,
      z3_repo_ref                = var.z3_repo_ref,
      z3_repo_url                = var.z3_repo_url,
    }
  )

  # Allow direct SSH login as the shared app account (z3).
  # This module intentionally disables OS Login so operators can use VS Code
  # Remote-SSH as z3.
  metadata = {
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    scopes = var.service_account_scopes
  }

  labels = var.labels

  tags = var.network_tags
}