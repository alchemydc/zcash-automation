output "internal_ip_addresses" {
  value = google_compute_address.zebra_testing_internal[*].address
}

output "external_ip_addresses" {
  value = google_compute_address.zebra_testing[*].address
}