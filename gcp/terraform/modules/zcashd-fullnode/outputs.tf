output internal_ip_addresses {
  value = google_compute_address.fullnode_internal.address
}

output external_ip_addresses {
  value = google_compute_address.fullnode.address
}