resource "google_compute_address" "privatenode" {
  name         = "privatenode-address"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "privatenode_internal" {
  name         = "privatenode-internal-address"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_disk" "zcashdata-privatenode-tmp" {
  name = "${var.data_disk_name}-privatenode-tmp"
  type = "pd-ssd"
  size = var.data_disk_size
  snapshot = "${var.data_disk_name}-snapshot-latest"
  count = var.privatenode_count
}

resource "google_compute_disk" "zcashparams-privatenode-tmp" {
  name = "${var.params_disk_name}-privatenode-tmp"
  type = "pd-standard"
  snapshot = "${var.params_disk_name}-snapshot-latest"
  size = 2
  count = var.privatenode_count
}

resource "google_compute_instance" "privatenode" {
  name = "zcash-privatenode"
  machine_type = var.instance_type

  count = var.privatenode_count

  allow_stopping_for_update = "true"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
      size = var.boot_disk_size
    }
  }

  attached_disk {
    source = "${var.data_disk_name}-privatenode-tmp"
    device_name = var.data_disk_name
  }

  attached_disk {
    source = "${var.params_disk_name}-privatenode-tmp"
    device_name = var.params_disk_name
  }

  network_interface {
    network    = var.network_name
    network_ip = google_compute_address.privatenode_internal.address
  }

  metadata_startup_script = templatefile(
    format("%s/startup.sh", path.module), {
      params_disk_name : var.params_disk_name,
      data_disk_name              : var.data_disk_name,
      gcloud_project              : var.project,
      gcloud_region               : var.region,
      gcloud_zone                 : var.zone,
      fullnode_private_ip_address : var.fullnode_private_ip_address
    }
  )

  service_account {
    scopes = var.service_account_scopes
  }

  tags = [
    "privatenode",
  ]

}