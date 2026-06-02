provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

locals {
  zcashd_fullnode_enabled    = var.replicas["zcashd-fullnode"] > 0
  zcashd_privatenode_enabled = var.replicas["zcashd-privatenode"] > 0
  zcashd_archivenode_enabled = var.replicas["zcashd-archivenode"] > 0
  zebra_testing_enabled      = var.replicas["zebra-testing"] > 0

  z3_p2p_ports = {
    mainnet = "8233"
    testnet = "18233"
  }
  z3_public_deployments = {
    for k, v in var.z3_deployments :
    k => v
    if v.expose_p2p_public && contains(keys(local.z3_p2p_ports), v.network)
  }

  # P2P port per Zebra network name (matches the values inside Zebra: Mainnet, Testnet).
  zebra_p2p_ports = {
    Mainnet = 8233
    Testnet = 18233
  }
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

# Update the sshd firewall rule to allow SSH from anywhere (or restrict to your IP range)
resource "google_compute_firewall" "sshd" {
  name       = "sshd-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["fullnode", "privatenode", "archivenode"]
  source_ranges = ["0.0.0.0/0"] # Consider restricting this to your IP range for security

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Only allow SSH to Zebra source-build hosts through IAP TCP forwarding by default.
resource "google_compute_firewall" "sshd_zebra_iap" {
  name       = "sshd-zebra-iap-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["zebrad-archivenode", "zebra-testing"]
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "sshd_zebra_public" {
  count      = length(var.zebra_public_ssh_source_ranges) > 0 ? 1 : 0
  name       = "sshd-zebra-public-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["zebrad-archivenode", "zebra-testing"]
  source_ranges = var.zebra_public_ssh_source_ranges

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Only allow SSH to z3 instances through IAP TCP forwarding.
resource "google_compute_firewall" "sshd_z3_iap" {
  name       = "sshd-z3-iap-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["z3"]
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Update the zcashd firewall rule to allow public P2P connections
resource "google_compute_firewall" "zcashd" {
  name       = "zcashd-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["archivenode"]
  source_ranges = ["0.0.0.0/0"] # Allow P2P connections from anywhere

  allow {
    protocol = "tcp"
    ports    = ["8233"]
  }
}

resource "google_compute_firewall" "zebrad_archivenode" {
  name       = "zebrad-archivenode-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["zebrad-archivenode"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.zebra_p2p_port)]
  }
}

resource "google_compute_firewall" "zebra_testing" {
  name       = "zebra-testing-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["zebra-testing"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.zebra_p2p_port)]
  }
}

resource "google_compute_firewall" "zcashd_private" {
  name       = "zcashd-firewall-private"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["fullnode"]
  source_ranges = [data.google_compute_subnetwork.zcash_subnetwork.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["8233"]
  }
}

resource "google_compute_firewall" "z3" {
  for_each   = local.z3_public_deployments
  name       = "z3-${each.key}-p2p-firewall"
  network    = google_compute_network.zcash_network.self_link
  depends_on = [google_compute_network.zcash_network]

  target_tags   = ["z3"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = [local.z3_p2p_ports[each.value.network]]
  }
}

module "zcashd-fullnode" {
  count  = local.zcashd_fullnode_enabled ? 1 : 0
  source = "./modules/zcashd-fullnode"
  # variables
  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  params_disk_name            = var.params_disk_name
  data_disk_name              = var.data_disk_name
  data_disk_size              = var.data_disk_size
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  fullnode_count              = var.replicas["zcashd-fullnode"]
  instance_type               = var.instance_types["zcashd-fullnode"]
  boot_disk_size              = var.boot_disk_size
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  depends_on                  = [google_compute_network.zcash_network]
}

module "zcashd-privatenode" {
  count  = local.zcashd_privatenode_enabled ? 1 : 0
  source = "./modules/zcashd-privatenode"
  # variables
  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  params_disk_name            = var.params_disk_name
  data_disk_name              = var.data_disk_name
  data_disk_size              = var.data_disk_size
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  fullnode_private_ip_address = local.zcashd_fullnode_enabled ? module.zcashd-fullnode[0].internal_ip_addresses : null
  privatenode_count           = var.replicas["zcashd-privatenode"]
  instance_type               = var.instance_types["zcashd-privatenode"]
  boot_disk_size              = var.boot_disk_size
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  depends_on                  = [google_compute_network.zcash_network]
}

module "zcashd-archivenode" {
  count  = local.zcashd_archivenode_enabled ? 1 : 0
  source = "./modules/zcashd-archivenode"
  # variables
  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  params_disk_name            = var.params_disk_name
  data_disk_name              = var.data_disk_name
  data_disk_size              = var.data_disk_size
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  archivenode_count           = var.replicas["zcashd-archivenode"]
  instance_type               = var.instance_types["zcashd-archivenode"]
  boot_disk_size              = var.boot_disk_size
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  depends_on                  = [google_compute_network.zcash_network]
}

moved {
  from = module.zebrad-archivenode[0]
  to   = module.zebrad-archivenode["mainnet"]
}

module "zebrad-archivenode" {
  for_each = var.zebrad_archivenode_deployments
  source   = "./modules/zebrad-archivenode"

  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  data_disk_name              = each.value.data_disk_name
  data_disk_size              = each.value.data_disk_size
  data_disk_type              = var.zebra_data_disk_type
  data_disk_snapshot          = each.value.data_disk_snapshot
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  instance_count              = each.value.replicas
  instance_type               = var.instance_types["zebrad-archivenode"]
  boot_disk_size              = var.boot_disk_size
  hostname_prefix             = each.value.hostname_prefix
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  zebra_repo_url              = "https://github.com/ZcashFoundation/zebra"
  zebra_repo_ref              = each.value.zebra_repo_ref
  zebra_git_fetch_ref         = each.value.zebra_git_fetch_ref
  zebra_network               = each.value.network
  zebra_listen_addr           = format("0.0.0.0:%d", lookup(local.zebra_p2p_ports, each.value.network, var.zebra_p2p_port))
  zebra_state_mount_path      = var.zebra_state_mount_path
  metrics_endpoint_addr       = var.zebra_metrics_endpoint_addr
  health_listen_addr          = var.zebra_health_listen_addr
  enable_snapshot_timer       = true
  snapshot_on_calendar        = var.zebra_archivenode_snapshot_on_calendar
  depends_on                  = [google_compute_network.zcash_network]
}

module "zebra-testing" {
  count  = local.zebra_testing_enabled ? 1 : 0
  source = "./modules/zebra-testing"

  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  data_disk_name              = var.zebra_testing_data_disk_name
  data_disk_size              = var.zebra_archivenode_data_disk_size
  data_disk_type              = var.zebra_data_disk_type
  data_disk_snapshot          = var.zebra_testing_data_disk_snapshot
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  instance_count              = var.replicas["zebra-testing"]
  instance_type               = var.instance_types["zebra-testing"]
  boot_disk_size              = var.boot_disk_size
  hostname_prefix             = "zebra-testing"
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  zebra_repo_url              = var.zebra_repo_url
  zebra_repo_ref              = var.zebra_repo_ref
  zebra_git_fetch_ref         = var.zebra_git_fetch_ref
  zebra_network               = var.zebra_network
  zebra_listen_addr           = format("0.0.0.0:%d", var.zebra_p2p_port)
  zebra_state_mount_path      = var.zebra_state_mount_path
  metrics_endpoint_addr       = var.zebra_metrics_endpoint_addr
  health_listen_addr          = var.zebra_health_listen_addr
  enable_snapshot_timer       = false
  snapshot_on_calendar        = var.zebra_archivenode_snapshot_on_calendar
  depends_on                  = [google_compute_network.zcash_network]
}

# Look up the latest archivenode-produced snapshot for each z3 deployment whose
# matching network has an archivenode deployed. Filtered by the labels written
# by zebra-create-snapshot in the archivenode VM. Deployments whose network has
# no archivenode (replicas=0) are excluded so the lookup never fails on absence.
data "google_compute_snapshot" "z3_zebra_state" {
  for_each = {
    for k, v in var.z3_deployments :
    k => v
    if try(var.zebrad_archivenode_deployments[v.network].replicas, 0) > 0
  }
  project     = var.project
  filter      = "labels.purpose=zebra-state AND labels.network=${lower(each.value.network)}"
  most_recent = true
}

module "z3" {
  for_each = var.z3_deployments
  source   = "./modules/z3"

  project                     = var.project
  network_name                = var.network_name
  service_account_scopes      = var.service_account_scopes
  region                      = var.region
  zone                        = var.zone
  GCP_DEFAULT_SERVICE_ACCOUNT = var.GCP_DEFAULT_SERVICE_ACCOUNT
  instance_count              = each.value.replicas
  instance_type               = var.z3_instance_types[each.value.network]
  boot_disk_size              = var.z3_boot_disk_size
  data_disk_name              = "z3-${each.key}-zebra-data"
  data_disk_size              = var.z3_data_disk_sizes[each.value.network]
  data_disk_type              = var.z3_data_disk_type
  hostname_prefix             = each.value.hostname_prefix
  subnetwork                  = data.google_compute_subnetwork.zcash_subnetwork.self_link
  os_image                    = var.os_image
  z3_repo_url                 = var.z3_repo_url
  z3_repo_ref                 = var.z3_repo_ref
  z3_network                  = each.value.network
  z3_mount_path               = var.z3_mount_path
  install_rust_toolchain      = each.value.install_rust_toolchain != null ? each.value.install_rust_toolchain : var.z3_install_rust_toolchain
  data_disk_snapshot          = try(data.google_compute_snapshot.z3_zebra_state[each.key].name, null)
  depends_on                  = [google_compute_network.zcash_network]
}

resource "google_storage_bucket" "chaindata_bucket" {
  name     = "${var.project}-chaindata"
  location = "US"

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      num_newer_versions = 10 # keep 10 copies of chaindata backups (use `gsutil ls -la $bucket` to see versioned objects)
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
  role   = "roles/storage.objectCreator"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
    google_storage_bucket.chaindata_bucket
  ]
}

resource "google_storage_bucket_iam_binding" "chaindata_binding_read" {
  bucket = "${var.project}-chaindata"
  role   = "roles/storage.objectViewer"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
    google_storage_bucket.chaindata_bucket
  ]
}

resource "google_storage_bucket" "chaindata_rsync_bucket" {
  name     = "${var.project}-chaindata-rsync"
  location = "US"

  uniform_bucket_level_access = true

}

resource "google_storage_bucket_iam_binding" "chaindata_rsync_binding_write" {
  bucket = "${var.project}-chaindata-rsync"
  role   = "roles/storage.objectCreator"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
    google_storage_bucket.chaindata_rsync_bucket
  ]
}

resource "google_storage_bucket_iam_binding" "chaindata_rsync_binding_read" {
  bucket = "${var.project}-chaindata-rsync"
  role   = "roles/storage.objectViewer"
  members = [
    "serviceAccount:${var.GCP_DEFAULT_SERVICE_ACCOUNT}",
  ]
  depends_on = [
    google_storage_bucket.chaindata_rsync_bucket
  ]
}

resource "google_logging_metric" "TF_zebra_node_height_distribution" {
  name   = "TF_zebra_node_height_distribution"
  filter = <<EOT
logName="projects/${var.project}/logs/syslog"
resource.type="gce_instance"
jsonPayload.message=~"zebrad::components::sync::progress.*current_height=Height"
EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "DISTRIBUTION"
    unit         = "1"
    display_name = "TF Zebra Node Block Height Distribution"

    labels {
      key        = "instance_id"
      value_type = "STRING"
    }
  }

  bucket_options {
    linear_buckets {
      num_finite_buckets = 10
      width              = 500000
      offset             = 0
    }
  }

  # Fixed regex pattern to properly extract the height number
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \"current_height=Height\\\\(([0-9]+)\\\\)\")"

  label_extractors = {
    instance_id = "EXTRACT(resource.labels.instance_id)"
  }
}

# note that this does *not* presently work due to ANSI color codes in the zcashd log output
# putting this on the back burner for now
resource "google_logging_metric" "TF_zcashd_node_height_distribution" {
  name   = "TF_zcashd_node_height_distribution"
  filter = <<EOT
logName="projects/${var.project}/logs/syslog"
resource.type="gce_instance"
jsonPayload.message=~".*UpdateTip.*height.*"
EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "DISTRIBUTION"
    unit         = "1"
    display_name = "TF Zcashd Node Block Height Distribution"

    labels {
      key        = "instance_id"
      value_type = "STRING"
    }
  }

  bucket_options {
    linear_buckets {
      num_finite_buckets = 10
      width              = 500000
      offset             = 0
    }
  }

  # Updated regex to match height in zcashd logs with ANSI codes
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \"height.*?#033\\\\[3m#033\\\\[2m=#033\\\\[0m([0-9]+)\")"

  label_extractors = {
    instance_id = "EXTRACT(resource.labels.instance_id)"
  }
}
