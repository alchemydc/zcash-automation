output "instance_names" {
  description = "Names of the vote validator instances"
  value       = google_compute_instance.vote_validator[*].name
}

output "public_ip_addresses" {
  description = "Reserved external addresses serving the helper API and P2P port"
  value       = google_compute_address.vote_validator[*].address
}

output "internal_ip_addresses" {
  description = "Internal addresses of the vote validator instances"
  value       = google_compute_address.vote_validator_internal[*].address
}

output "data_disk_names" {
  description = "Persistent data disks holding the validator home directory"
  value       = google_compute_disk.vote_validator_data[*].name
}

output "validator_urls" {
  description = "Public HTTPS URLs Caddy serves the helper API on, once a certificate is issued"
  value       = [for domain in local.tls_domains : format("https://%s", domain)]
}

output "ssh_commands" {
  description = "IAP-tunnelled SSH commands for each instance"
  value = [
    for instance in google_compute_instance.vote_validator[*].name :
    format("gcloud compute ssh %s --tunnel-through-iap --zone %s --project %s", instance, var.zone, var.project)
  ]
}

output "join_commands" {
  description = <<-EOT
    Command to start the interactive join on each instance. The installer prompts
    for a validator name and cannot be run unattended, so this drops you into it
    rather than doing it for you.
  EOT
  value = [
    for instance in google_compute_instance.vote_validator[*].name :
    format(
      "gcloud compute ssh %s --tunnel-through-iap --zone %s --project %s -- -t 'sudo -iu svote svote join'",
      instance, var.zone, var.project
    )
  ]
}

output "registration_detail_commands" {
  description = "Re-print the approval message to send to the Valar Group voting admin"
  value = [
    for instance in google_compute_instance.vote_validator[*].name :
    format(
      "gcloud compute ssh %s --tunnel-through-iap --zone %s --project %s -- 'sudo -iu svote svote addr'",
      instance, var.zone, var.project
    )
  ]
}

output "key_backup_bucket" {
  description = "Bucket encrypted validator key archives are uploaded to"
  value       = var.key_backup_bucket
}

output "key_backup_prefixes" {
  description = "Per-instance object prefixes within the key backup bucket"
  value = [
    for instance in google_compute_instance.vote_validator[*].name :
    format("gs://%s/%s/", var.key_backup_bucket, instance)
  ]
}

output "post_deployment_instructions" {
  description = "What an operator has to do after apply, in order"
  value       = <<-EOT
    The instances are prepared but hold no validator yet. Joining is interactive
    by design; run through this once per instance.

    1. Confirm a key backup recipient is configured. If key_backup_age_recipient
       is empty, key backup refuses to run. Generate one off-host:

         rage-keygen -o svote-backup-identity.txt

       Keep that identity file OFF the VM and backed up. Set the public
       "age1..." line it prints as key_backup_age_recipient, then re-apply.

    2. Join, interactively. See the join_commands output for the exact
       copy-pasteable command per instance, or:

         gcloud compute ssh <instance> --tunnel-through-iap --zone ${var.zone} \
           --project ${var.project} -- -t 'sudo -iu svote svote join'

       It prompts for a validator name, installs and starts svoted, registers
       with the join queue, and then offers to back up the signing key. Say yes.

    3. Send the approval message it prints to the Valar Group voting admin. They
       approve and fund the operator address; the svoted wrapper then bonds the
       validator by itself. Check with 'svote bonded'.

    4. Rehearse the key restore before you depend on it: 'svote restore-keys'
       prints the procedure. A backup you have never decrypted is not a backup.

    Warning: the validator signing key must be live on exactly one host. Do not
    restore it, or a data disk snapshot containing it, onto a second running
    host — that double-signs.
  EOT
}
