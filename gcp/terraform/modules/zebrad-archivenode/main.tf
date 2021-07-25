resource "google_compute_address" "zebrad_archivenode" {
  name         = "zebrad-archivenode-address"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "zebrad_archivenode_internal" {
  name         = "zebrad-archivenode-internal-address"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "zebradata" {
  name = var.data_disk_name
  type = "pd-standard"
  size = var.data_disk_size
  count = var.archivenode_count
}

resource "google_compute_disk" "zebracargo" {
  name = var.params_disk_name
  type = "pd-ssd"
  size = 5
  count = var.archivenode_count
}

resource "google_compute_instance" "archivenode" {
  name = "zebra-archivenode"
  machine_type = "n1-standard-2"   # FIXME: parameterize this :)
  #machine_type = var.instance_types["zebrad_archivenode"]
  depends_on = [google_compute_disk.zebradata]

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
    network_ip = google_compute_address.zebrad_archivenode_internal.address
    access_config {
      nat_ip = google_compute_address.zebrad_archivenode.address
    }
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module), {
      params_disk_name : var.params_disk_name,
      data_disk_name : var.data_disk_name,
      gcloud_project : var.project,
      gcloud_region  : var.region,
      gcloud_zone    : var.zone,
      external_ip_address : google_compute_address.zebrad_archivenode.address
    }
  )

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "archivenode",
  ]

}
