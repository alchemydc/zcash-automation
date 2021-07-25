output internal_ip_addresses {
  value = google_compute_address.zebrad_archivenode_internal.address
}

output external_ip_addresses {
  value = google_compute_address.zebrad_archivenode.address
}