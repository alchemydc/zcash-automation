resource "google_compute_address" "archivenode" {
  name         = "archivenode-address"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "archivenode_internal" {
  name         = "archivenode-internal-address"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "zcashdata" {
  name = var.data_disk_name
  #type = "pd-ssd"
  type = "pd-standard"  #want SSD but running into quota issues in region :(
  size = var.data_disk_size
}

resource "google_compute_disk" "zcashparams" {
  name = var.params_disk_name
  type = "pd-standard"
  size = 2
}

resource "google_compute_instance" "archivenode" {
  name = "zcash-archivenode"
  machine_type = var.instance_type
  depends_on = [google_compute_disk.zcashdata]

  count = var.archivenode_count

  allow_stopping_for_update = "true"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
      size = var.boot_disk_size
    }
  }

  attached_disk {
    source = var.data_disk_name
    device_name = var.data_disk_name
  }

  attached_disk {
    source = var.params_disk_name
    device_name = var.params_disk_name
  }

  network_interface {
    network    = var.network_name
    network_ip = google_compute_address.archivenode_internal.address
    access_config {
      nat_ip = google_compute_address.archivenode.address
    }
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module), {
      params_disk_name : var.params_disk_name,
      data_disk_name : var.data_disk_name,
      gcloud_project : var.project,
      gcloud_region  : var.region,
      gcloud_zone    : var.zone,
      external_ip_address : google_compute_address.archivenode.address
    }
  )

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "archivenode",
  ]

}
