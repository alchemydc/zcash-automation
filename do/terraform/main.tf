locals {
  vote_validator_count = var.vote_validator_enabled ? 1 : 0
}

# A project is organisational only, but without one every resource lands in the
# account's default project, which makes a shared account hard to reason about.
resource "digitalocean_project" "zcash" {
  count       = local.vote_validator_count
  name        = var.project_name
  description = "Zcash Shielded-Vote validator infrastructure"
  purpose     = "Service or API"
  environment = var.project_environment

  resources = [
    module.zcash-vote-validator[0].droplet_urn,
    module.zcash-vote-validator[0].volume_urn,
  ]
}

# The region's default VPC, looked up rather than created.
#
# Creating one is a trap: DigitalOcean promotes the first VPC in a region to be
# that region's default, and a default VPC cannot be deleted -- ever. So a
# `digitalocean_vpc` resource applied into a fresh region becomes permanently
# undestroyable, `tofu destroy` fails on it with 403 "Can not delete default
# VPCs", and the resource is stuck in state. Learned the hard way in sfo3, where
# `zcash-vote` is now the immortal default.
#
# Per the provider docs, passing only `region` returns that region's default VPC,
# which is what the droplet wants anyway: a VPC is a private network boundary,
# and this module deploys a single host into it.
data "digitalocean_vpc" "zcash" {
  region = var.region
}

module "zcash-vote-validator" {
  count  = local.vote_validator_count
  source = "./modules/zcash-vote-validator"

  region   = var.region
  vpc_uuid = data.digitalocean_vpc.zcash.id
  image    = var.os_image

  hostname             = var.vote_validator_hostname
  droplet_size         = var.vote_validator_droplet_size
  ssh_key_fingerprints = var.ssh_key_fingerprints
  ssh_source_ranges    = var.vote_validator_ssh_source_ranges
  admin_user           = var.vote_validator_admin_user
  permit_root_login    = var.vote_validator_permit_root_login
  tags                 = var.vote_validator_tags

  data_disk_name          = var.vote_validator_data_disk_name
  data_disk_size          = var.vote_validator_data_disk_size
  data_volume_snapshot_id = var.vote_validator_data_volume_snapshot_id

  svote_mount_path = var.vote_validator_svote_mount_path
  svote_env        = var.vote_validator_svote_env
  upgrade_mode     = var.vote_validator_upgrade_mode
  tls_domain       = var.vote_validator_tls_domain
  helper_api_port  = var.vote_validator_helper_api_port
  p2p_port         = var.vote_validator_p2p_port

  join_script_url      = var.vote_validator_join_script_url
  join_script_sha256   = var.vote_validator_join_script_sha256
  join_timeout_seconds = var.vote_validator_join_timeout_seconds
  moniker              = var.vote_validator_moniker
  svote_admin_url      = var.vote_validator_svote_admin_url

  allow_binary_autodownload = var.vote_validator_allow_binary_autodownload
  upgrade_check_on_calendar = var.vote_validator_upgrade_check_on_calendar

  key_backup_age_recipient = var.vote_validator_key_backup_age_recipient
  key_backup_on_calendar   = var.vote_validator_key_backup_on_calendar
  key_backup_keep_count    = var.vote_validator_key_backup_keep_count
}
