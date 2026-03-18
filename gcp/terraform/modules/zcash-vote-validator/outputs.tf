output "internal_ip_addresses" {
  value = [for address in google_compute_address.vote_validator_internal : address.address]
}
