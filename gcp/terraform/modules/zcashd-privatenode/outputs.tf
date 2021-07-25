output internal_ip_addresses {
  value = google_compute_address.privatenode_internal.address
}