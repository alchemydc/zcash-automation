# Vote validator outputs. Joining the Shielded-Vote chain is a manual,
# interactive step, so the operator needs these values out of Terraform rather
# than having to reconstruct them: the exact join command, the public URL Caddy
# will serve, and where encrypted key backups land.
#
# All are null / empty lists when vote_validator_enabled is false.

output "vote_validator_instance_names" {
  description = "Names of the deployed vote validator instances"
  value       = try(module.zcash-vote-validator[0].instance_names, [])
}

output "vote_validator_public_ips" {
  description = "Reserved external addresses of the vote validator instances"
  value       = try(module.zcash-vote-validator[0].public_ip_addresses, [])
}

output "vote_validator_urls" {
  description = "Public HTTPS URLs the validator helper API is served on"
  value       = try(module.zcash-vote-validator[0].validator_urls, [])
}

output "vote_validator_ssh_commands" {
  description = "IAP-tunnelled SSH commands for the vote validator instances"
  value       = try(module.zcash-vote-validator[0].ssh_commands, [])
}

output "vote_validator_join_commands" {
  description = "Commands that start the interactive join on each vote validator instance"
  value       = try(module.zcash-vote-validator[0].join_commands, [])
}

output "vote_validator_registration_detail_commands" {
  description = "Commands that re-print the approval message for the voting admin"
  value       = try(module.zcash-vote-validator[0].registration_detail_commands, [])
}

output "vote_validator_key_backup_prefixes" {
  description = "GCS prefixes holding encrypted validator key archives"
  value       = try(module.zcash-vote-validator[0].key_backup_prefixes, [])
}

output "vote_validator_post_deployment_instructions" {
  description = "Ordered post-apply steps for the vote validator operator"
  value       = try(module.zcash-vote-validator[0].post_deployment_instructions, "vote_validator_enabled is false")
}
