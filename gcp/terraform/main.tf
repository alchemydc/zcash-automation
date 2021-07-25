provider "google" {
  project = var.project
  region = var.region
  zone = var.zone
}

resource "google_project_service" "compute" {
  project                    = var.project
  service                    = "compute.googleapis.com"
  disable_dependent_services = true
  disable_on_destroy         = false
}

resource "google_compute_network" "zcash_network" {
  name = var.network_name
  timeouts {
    delete = "15m"
  }
}

data "google_compute_subnetwork" "zcash_subnetwork" {
  name       = google_compute_network.zcash_network.name
  region     = var.region
  depends_on = [google_compute_network.zcash_network]
}

resource "google_compute_router" "router" {
  name    = "zcash-router"
  region  = data.google_compute_subnetwork.zcash_subnetwork.region
  network = google_compute_network.zcash_network.self_link
}

resource "google_compute_router_nat" "nat" {
  name                               = "zcash-router-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "sshd" {
  name    = "sshd-firewall"
  network = var.network_name
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["fullnode", "privatenode", "archivenode"]
  #source_ranges = [data.google_compute_subnetwork.zcash.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "zcashd" {
  name    = "zcashd-firewall"
  network = var.network_name
  #depends_on = [google_compute_network.zcash_network]

  target_tags   = ["archivenode"]
  #source_ranges = [data.google_compute_subnetwork.zcash.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["8233"]
  }
}

resource "google_compute_firewall" "zcashd_private" {
  name    = "zcashd-firewall-private"
  network = var.network_name
  #depends_on = [google_compute_network.zcash_network]

  target_tags   = ["fullnode"]
  source_ranges = [data.google_compute_subnetwork.zcash_subnetwork.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["8233"]
  }
}

module "zcashd-fullnode" {
  source = "./modules/zcashd-fullnode"
  # variables
  project                        = var.project
  network_name                   = var.network_name
  service_account_scopes         = var.service_account_scopes
  region                         = var.region
  zone                           = var.zone
  params_disk_name               = var.params_disk_name
  data_disk_name                 = var.data_disk_name
  GCP_DEFAULT_SERVICE_ACCOUNT    = var.GCP_DEFAULT_SERVICE_ACCOUNT
  fullnode_count                 = var.replicas["zcashd-fullnode"]
  instance_type                  = var.instance_types["zcashd-fullnode"]
  boot_disk_size                 = var.boot_disk_size
}

module "zcashd-privatenode" {
  source = "./modules/zcashd-privatenode"
  # variables
  project                        = var.project
  network_name                   = var.network_name
  service_account_scopes         = var.service_account_scopes
  region                         = var.region
  zone                           = var.zone
  params_disk_name               = var.params_disk_name
  data_disk_name                 = var.data_disk_name
  GCP_DEFAULT_SERVICE_ACCOUNT    = var.GCP_DEFAULT_SERVICE_ACCOUNT
  fullnode_private_ip_address    = module.zcashd-fullnode.internal_ip_addresses
  privatenode_count              = var.replicas["zcashd-privatenode"]
  instance_type                  = var.instance_types["zcashd-privatenode"]
  boot_disk_size                 = var.boot_disk_size
}

module "zcashd-archivenode" {
  source = "./modules/zcashd-archivenode"
  # variables
  project                        = var.project
  network_name                   = var.network_name
  service_account_scopes         = var.service_account_scopes
  region                         = var.region
  zone                           = var.zone
  params_disk_name               = var.params_disk_name
  data_disk_name                 = var.data_disk_name
  GCP_DEFAULT_SERVICE_ACCOUNT    = var.GCP_DEFAULT_SERVICE_ACCOUNT
  archivenode_count              = var.replicas["zcashd-archivenode"]
  instance_type                  = var.instance_types["zcashd-archivenode"]
  boot_disk_size                 = var.boot_disk_size
}

module "zebradd-archivenode" {
  source = "./modules/zebrad-archivenode"
  # variables
  project                        = var.project
  network_name                   = var.network_name
  service_account_scopes         = var.service_account_scopes
  region                         = var.region
  zone                           = var.zone
  params_disk_name               = var.zebra_params_disk_name  #"zebra-cargo"  
  data_disk_name                 = var.zebra_data_disk_name    #"zebra-data" 
  GCP_DEFAULT_SERVICE_ACCOUNT    = var.GCP_DEFAULT_SERVICE_ACCOUNT
  archivenode_count              = var.replicas["zebrad-archivenode"]
  instance_type                  = var.instance_types["zebrad-archivenode"]
  boot_disk_size                 = var.boot_disk_size
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