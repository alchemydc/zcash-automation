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

  target_tags   = ["fullnode"]
  #source_ranges = [data.google_compute_subnetwork.zcash.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

module "fullnode" {
  source = "./modules/fullnode"
  # variables
  project                        = var.project
  network_name                   = var.network_name
  service_account_scopes         = var.service_account_scopes
  region                         = var.region
  zone                           = var.zone
  GCP_DEFAULT_SERVICE_ACCOUNT    = var.GCP_DEFAULT_SERVICE_ACCOUNT
}