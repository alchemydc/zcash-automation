output "internal_ip_addresses" {
  value = [for address in google_compute_address.z3_internal : address.address]
}

output "external_ip_addresses" {
  value = [for address in google_compute_address.z3 : address.address]
}