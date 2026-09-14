output "droplet_id" {
  description = "ID of the vote validator droplet"
  value       = digitalocean_droplet.vote_validator.id
}

output "droplet_name" {
  description = "Name of the vote validator droplet"
  value       = digitalocean_droplet.vote_validator.name
}

output "public_ip_address" {
  description = "Public address serving the helper API and P2P port. Point tls_domain's A record here."
  value       = digitalocean_droplet.vote_validator.ipv4_address
}

output "private_ip_address" {
  description = "VPC-private address of the droplet"
  value       = digitalocean_droplet.vote_validator.ipv4_address_private
}

output "data_volume_id" {
  description = "Block storage volume holding the validator home directory"
  value       = digitalocean_volume.vote_validator_data.id
}

output "validator_url" {
  description = <<-EOT
    Public HTTPS URL Caddy serves the helper API on, once a certificate is
    issued. Empty when tls_domain is unset, because the sslip.io fallback is
    derived on the host at boot and is not known to Terraform. In that case read
    it from the startup log or `svote status`.
  EOT
  value       = var.tls_domain != "" ? format("https://%s", var.tls_domain) : ""
}

output "ssh_command" {
  description = "SSH command for the droplet"
  value       = format("ssh root@%s", digitalocean_droplet.vote_validator.ipv4_address)
}

output "join_command" {
  description = <<-EOT
    Command to start the interactive join. The installer prompts for a validator
    name and cannot be run unattended, so this drops you into it rather than
    doing it for you.
  EOT
  value = format(
    "ssh -t root@%s 'sudo -iu svote svote join'",
    digitalocean_droplet.vote_validator.ipv4_address
  )
}

output "registration_detail_command" {
  description = "Re-print the approval message to send to the Valar Group voting admin"
  value = format(
    "ssh root@%s 'sudo -iu svote svote addr'",
    digitalocean_droplet.vote_validator.ipv4_address
  )
}

output "key_backup_spool" {
  description = <<-EOT
    On-host directory encrypted key archives are written to. Nothing uploads
    them; collect them off this host or they are not backups.
  EOT
  value       = format("%s/keybackup", var.svote_mount_path)
}

output "startup_script" {
  description = <<-EOT
    The rendered bootstrap script. user_data is ignore_changes on the droplet, so
    Terraform will not push an edited script to a running host; write this out
    and copy it over instead. See the lifecycle comment in main.tf.
  EOT
  value       = local.startup_script
  sensitive   = true
}

output "post_deployment_instructions" {
  description = "What an operator has to do after apply, in order"
  value       = <<-EOT
    The droplet is prepared but holds no validator yet. Joining is interactive by
    design.

    1. Confirm a key backup recipient is configured. If key_backup_age_recipient
       is empty, key backup refuses to run. Generate one off-host:

         rage-keygen -o svote-backup-identity.txt

       Keep that identity file OFF the droplet and backed up. Set the public
       "age1..." line it prints as key_backup_age_recipient, then re-apply.

    2. Point tls_domain's A record at ${digitalocean_droplet.vote_validator.ipv4_address},
       DNS-only (not proxied). Let's Encrypt has to reach :80/:443 for that name,
       and `svote join` refuses to run until DNS resolves here.

    3. Join, interactively:

         ssh -t root@${digitalocean_droplet.vote_validator.ipv4_address} 'sudo -iu svote svote join'

       It prompts for a validator name, installs and starts svoted, registers
       with the join queue, and then offers to back up the signing key. Say yes.

    4. Send the approval message it prints to the Valar Group voting admin. They
       approve and fund the operator address; the svoted wrapper then bonds the
       validator by itself. Check with 'svote bonded'.

    5. Collect the key archive off this host. It spools to
       ${var.svote_mount_path}/keybackup and nothing uploads it. Then rehearse
       the restore: 'svote restore-keys' prints the procedure. A backup you have
       never decrypted is not a backup.

    Warning: the validator signing key must be live on exactly one host. Do not
    restore it, or a volume snapshot containing it, onto a second running host —
    that double-signs.
  EOT
}

output "droplet_urn" {
  description = "Droplet URN, for assigning the droplet to a DigitalOcean project"
  value       = digitalocean_droplet.vote_validator.urn
}

output "volume_urn" {
  description = "Volume URN, for assigning the volume to a DigitalOcean project"
  value       = digitalocean_volume.vote_validator_data.urn
}
