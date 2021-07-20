locals {
  params_disk_name = "zcashparams"
  data_disk_name = "zcashdata"
}

resource "google_compute_address" "fullnode" {
  name         = "fullnode-address"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "fullnode_internal" {
  name         = "fullnode-internal-address"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_firewall" "zcashd" {
  name    = "zcashd-firewall"
  network = var.network_name
  #depends_on = [google_compute_network.zcash_network]

  target_tags   = ["fullnode"]
  #source_ranges = [data.google_compute_subnetwork.zcash.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["8233"]
  }
}

resource "google_compute_disk" "zcashdata" {
  name = "${local.data_disk_name}"
  type = "pd-ssd"
  size = var.data_disk_size
}

resource "google_compute_disk" "zcashparams" {
  name = "${local.params_disk_name}"
  type = "pd-standard"
  size = 2
}

resource "google_compute_instance" "fullnode" {
  name = "zcash-fullnode"
  #machine_type = "n1-standard-4"
  machine_type = "n1-standard-2"
  depends_on = [google_compute_disk.zcashdata]

  allow_stopping_for_update = "true"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
      size = 20
    }
  }

  attached_disk {
    source = "zcashdata"
    device_name = "zcashdata"
  }

  attached_disk {
    source = "zcashparams"
    device_name = "zcashparams"
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
      params_disk_name : local.params_disk_name,
      data_disk_name : local.data_disk_name,
      gcloud_project : var.project,
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

resource "google_storage_bucket" "chaindata_bucket" {
  name = "${var.project}-chaindata"
  location = "US"

  lifecycle_rule {
    condition {
      num_newer_versions = 10  # keep 10 copies of chaindata backups (use `gsutil ls -la $bucket` to see versioned objects)
    }
    action {
      type = "Delete"
    }
  }

  versioning {
      enabled = true
    }
}

resource "google_storage_bucket_iam_binding" "chaindata_binding_write" {
  bucket = "${var.project}-chaindata"
  role = "roles/storage.objectCreator"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
  google_storage_bucket.chaindata_bucket
  ]
}

resource "google_storage_bucket_iam_binding" "chaindata_binding_read" {
  bucket = "${var.project}-chaindata"
  role = "roles/storage.objectViewer"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
  google_storage_bucket.chaindata_bucket
  ]
}

resource "google_storage_bucket" "chaindata_rsync_bucket" {
  name = "${var.project}-chaindata-rsync"
  location = "US"

}

resource "google_storage_bucket_iam_binding" "chaindata_rsync_binding_write" {
  bucket = "${var.project}-chaindata-rsync"
  role = "roles/storage.objectCreator"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
  google_storage_bucket.chaindata_rsync_bucket
  ]
}

resource "google_storage_bucket_iam_binding" "chaindata_rsync_binding_read" {
  bucket = "${var.project}-chaindata-rsync"
  role = "roles/storage.objectViewer"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
  google_storage_bucket.chaindata_rsync_bucket
  ]
}


