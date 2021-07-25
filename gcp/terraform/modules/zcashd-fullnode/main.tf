resource "google_compute_address" "fullnode" {
  name         = "fullnode-address"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "fullnode_internal" {
  name         = "fullnode-internal-address"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "zcashdata-fullnode-tmp" {
  name = "${var.data_disk_name}-fullnode-tmp"
  #type = "pd-ssd"
  type = "pd-standard"  #want SSD but running into quota issues in region :(
  size = var.data_disk_size
  snapshot = "${var.data_disk_name}-snapshot-latest"
  count = var.fullnode_count
}

resource "google_compute_disk" "zcashparams-fullnode-tmp" {
  name = "${var.params_disk_name}-fullnode-tmp"
  type = "pd-standard"
  snapshot = "${var.params_disk_name}-snapshot-latest"
  size = 2
  count = var.fullnode_count
}

resource "google_compute_instance" "fullnode" {
  name = "zcash-fullnode"
  machine_type = var.instance_type

  count = var.fullnode_count

  allow_stopping_for_update = "true"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
      size = var.boot_disk_size
    }
  }

  attached_disk {
    source = "${var.data_disk_name}-fullnode-tmp"
    device_name = var.data_disk_name
  }

  attached_disk {
    source = "${var.params_disk_name}-fullnode-tmp"
    device_name = var.params_disk_name
  }

  network_interface {
    network    = var.network_name
    network_ip = google_compute_address.fullnode_internal.address
    access_config {
      nat_ip = google_compute_address.fullnode.address
    }
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module), {
      params_disk_name : var.params_disk_name,
      data_disk_name : var.data_disk_name,
      gcloud_project : var.project,
      gcloud_region  : var.region,
      gcloud_zone    : var.zone,
      external_ip_address : google_compute_address.fullnode.address
    }
  )

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "fullnode",
  ]

}