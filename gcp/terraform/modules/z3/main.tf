resource "google_compute_address" "z3" {
  count        = var.instance_count
  name         = format("z3-%d-address", count.index)
  address_type = "EXTERNAL"
}

resource "google_compute_address" "z3_internal" {
  count        = var.instance_count
  name         = format("z3-%d-internal-address", count.index)
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "z3_data" {
  count = var.instance_count
  name  = format("%s-%d", var.data_disk_name, count.index)
  type  = var.data_disk_type
  size  = var.data_disk_size
}

resource "google_compute_instance" "z3" {
  count        = var.instance_count
  name         = format("z3-%d", count.index)
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
      data_disk_name = google_compute_disk.z3_data[count.index].name,
      gcloud_project = var.project,
      install_rust_toolchain = var.install_rust_toolchain,
      z3_mount_path  = var.z3_mount_path,
      z3_network     = var.z3_network,
      z3_repo_ref    = var.z3_repo_ref,
      z3_repo_url    = var.z3_repo_url,
    }
  )

  # Allow direct SSH login as the shared app account (z3).
  # This module intentionally disables OS Login so operators can use VS Code
  # Remote-SSH as z3.
  metadata = {
    enable-oslogin       = "FALSE"
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "z3",
  ]
}