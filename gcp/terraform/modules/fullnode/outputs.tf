output internal_ip_addresses {
  value = google_compute_address.faucet_internal.address
}

output external_ip_addresses {
  value = google_compute_address.faucet.address
}