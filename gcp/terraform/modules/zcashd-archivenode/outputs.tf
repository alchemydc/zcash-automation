output internal_ip_addresses {
  value = google_compute_address.archivenode_internal.address
}

output external_ip_addresses {
  value = google_compute_address.archivenode.address
}