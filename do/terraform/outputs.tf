output "vote_validator_public_ip" {
  description = "Public address of the vote validator droplet. Point tls_domain's A record here."
  value       = try(module.zcash-vote-validator[0].public_ip_address, "")
}

output "vote_validator_private_ip" {
  description = "VPC-private address of the vote validator droplet"
  value       = try(module.zcash-vote-validator[0].private_ip_address, "")
}

output "vote_validator_url" {
  description = "Public HTTPS URL of the helper API, when tls_domain is set"
  value       = try(module.zcash-vote-validator[0].validator_url, "")
}

output "vote_validator_ssh_command" {
  description = "SSH command for the vote validator droplet"
  value       = try(module.zcash-vote-validator[0].ssh_command, "")
}

output "vote_validator_join_command" {
  description = "Command to start the interactive join"
  value       = try(module.zcash-vote-validator[0].join_command, "")
}

output "vote_validator_registration_detail_command" {
  description = "Re-print the approval message for the Valar Group voting admin"
  value       = try(module.zcash-vote-validator[0].registration_detail_command, "")
}

output "vote_validator_key_backup_spool" {
  description = "On-host directory encrypted key archives are written to; nothing uploads them"
  value       = try(module.zcash-vote-validator[0].key_backup_spool, "")
}

output "vote_validator_post_deployment_instructions" {
  description = "What an operator has to do after apply, in order"
  value       = try(module.zcash-vote-validator[0].post_deployment_instructions, "")
}
