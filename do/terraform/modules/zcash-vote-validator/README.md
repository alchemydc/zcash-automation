# zcash-vote-validator (DigitalOcean)

Provisions a host for a Valar Group Shielded-Vote validator (`zvote-1`) on
DigitalOcean. It is a port of `gcp/terraform/modules/zcash-vote-validator`, and
exists because Tor-sourced traffic to the helper API was being dropped on the
GCP path.

Like the GCE module, this prepares the host and stops short of joining the
chain. `startup.sh` never installs `svoted` and never touches `SVOTE_HOME`:
Valar's `join.sh` does that, it is destructive on every run (`rm -rf
$SVOTE_HOME`), and it prompts. The operator runs `svote join` once,
interactively.

## What differs from the GCE module

Read this section before assuming anything carries over.

### Key backup no longer has a bucket, and the guarantee it provided is gone

On GCE, archives were uploaded to a bucket where the instance held
`roles/storage.objectCreator` and nothing else. That is a real property: the
host could *create* timestamped backups but could not read, overwrite or delete
them, so a compromised validator could not rewrite or destroy its own backup
history.

**DigitalOcean cannot express that.** Spaces per-bucket access keys come in
`read`, `readwrite` and `fullaccess` only — there is no create-but-not-delete
level. Bucket policies are mutually exclusive with per-bucket keys, so you
cannot layer a deny on top. Object Lock is unimplemented and returns
`NotImplemented`. Versioning does not rescue it either: a key that can
`DeleteObject` can almost certainly delete versions too.

A `readwrite` key on the validator would be strictly worse than the GCE
arrangement, so this module ships **no cloud credential on the host at all** —
matching the GCE property that mattered most, which was that the metadata-server
token was short-lived and nothing durable sat on disk.

Instead, `svote backup-keys` writes an age-encrypted archive to a local spool:

    /var/lib/svote/keybackup/keys-<UTC timestamp>.tar.age
    /var/lib/svote/keybackup/keys-<UTC timestamp>.tar.age.sha256

pruned to `key_backup_keep_count` (default 14). Encryption is unchanged: the
archive is encrypted to `key_backup_age_recipient` before it is written, so the
spool holds no plaintext key material and whoever collects it never needs to be
trusted with any.

**A spool that has never been collected is not a backup.** Collect archives off
this host — `scp`, or a pull-based collector using an `authorized_keys`
`command=` restriction so the validator cannot reach out. The integrity
guarantee now comes from the archives living somewhere the validator cannot
touch, not from bucket permissions.

### No volume snapshots

`install_snapshot_tooling` is gone. Recreating it against DigitalOcean's volume
snapshot API would put a long-lived API token on a host that holds a validator
signing key, and the trade is not worth it: chain state is replaceable via
`svote reset-snapshot`, which re-syncs from Valar's published snapshot with a
checksum check and preserves `priv_validator_state.json`. The only irreplaceable
data is the keys, and those are handled above.

### SSH is public, pubkey-only

On GCE, `:22` was reachable only from Google's IAP forwarders and gated by Cloud
IAM with org-level audit logging. DigitalOcean has no equivalent.
`ssh_source_ranges` defaults to open because this validator is administered by
several operators on dynamic addresses, so an allowlist would be either useless
or an outage waiting to happen.

Note the knock-on effect: `docs/svote-installer-security-analysis.md` §2.5
accepted `join.sh`'s `/tmp` race partly *because* the host was "single-purpose
with IAP-only SSH." That justification is weaker here.

### The startup script does not update in place

`user_data` is `ForceNew` on `digitalocean_droplet`. The GCE module deliberately
put the script in the metadata map so edits updated the instance rather than
replacing it — replacement destroys the validator signing key. The nearest
equivalent here is `lifecycle { ignore_changes = [user_data] }`, which is set.

The cost: **Terraform stops managing the script's content after create, so drift
is invisible to `plan`.** To update a running host:

    tofu output -raw startup_script > /tmp/startup.sh
    scp /tmp/startup.sh root@<ip>:/usr/local/sbin/zcash-vote-validator-startup.sh
    ssh root@<ip> /usr/local/sbin/zcash-vote-validator-startup.sh

or just reboot — the script is installed into
`/var/lib/cloud/scripts/per-boot/`, which cloud-init runs on every boot. That
per-boot hook is what replaces GCE's re-run-metadata-on-every-boot behaviour,
which `startup.sh` is written to depend on.

### Smaller deltas

- **Data volume device path** is `/dev/disk/by-id/scsi-0DO_Volume_<name>`, so
  `data_disk_name` is load-bearing rather than cosmetic. The script waits up to
  two minutes for the device, because cloud-init can beat the volume attach and
  the user-data phase only runs once.
- **`tls_domain`'s sslip.io fallback is resolved on the host at boot**, not in
  Terraform. A droplet's IP is an attribute of the droplet itself, so deriving
  the name in Terraform would make `user_data` depend on the resource
  `user_data` configures.
- **No reserved IP.** A DigitalOcean reserved IP is additive: the droplet keeps
  an anchor address and egresses from it, so inbound and outbound addresses
  would differ — bad for CometBFT's advertised `external_address`.
- **No Google Ops Agent.** Host metrics come from `monitoring = true` on the
  droplet. Log-based alerting is not replaced here; the Kuma probe in
  `infra-monitoring-kuma` covers the public endpoint.
- **Firewall egress is explicit.** DigitalOcean cloud firewalls are default-deny
  in *both* directions, unlike GCP. The `outbound_rule` blocks in `main.tf` are
  load-bearing — without them the droplet cannot reach apt, Let's Encrypt, the
  GitHub API, Valar's endpoints, or any peer.

## Before `tofu apply`

Four things cannot be created by Terraform:

1. **Billing** on the DigitalOcean account.
2. **A team**, if you want isolation. Token scopes are per resource *type*,
   never per instance, so a dedicated team is the only real blast-radius
   control — and a token belongs to the team it was minted in, so decide first.
3. **The API token.** Custom scopes, not Full Access:
   `droplet`, `block_storage`, `firewall`, `vpc`, `project` (create/read/update/
   delete), `block_storage_action` (create/read), `tag` (create/read),
   `ssh_key:read`, and read on regions/sizes/image. A missing scope surfaces as
   a 403 naming the endpoint. Set an expiry — it is mandatory at mint time, and
   a DigitalOcean PAT is otherwise a long-lived bearer token with no IP
   restriction and no refresh.

   Export it as **`DIGITALOCEAN_ACCESS_TOKEN`**, which is the only spelling both
   tools honour: `doctl` reads only that name, while the Terraform provider
   accepts either it or `DIGITALOCEAN_TOKEN`.

   Do **not** run `doctl auth init` — it persists the token in plaintext to
   `~/.config/doctl/config.yaml`. On the dev boxes the token is forwarded over
   ssh and injected per-process by `do-run` (ansible-toolbox, dev_server role),
   so it never reaches disk; prefix commands with it:

       do-run doctl account get
       do-run tofu plan
4. **SSH public keys**, uploaded once (console or `doctl compute ssh-key
   import`) and referenced by fingerprint via `ssh_key_fingerprints`. Not
   optional: DigitalOcean emails a root password for a droplet created with no
   keys.

Do **not** pre-create the project, VPC, droplet, volume or firewall — Terraform
owns those. No DigitalOcean DNS zone is needed; `zvote.zfnd.org` is on
Cloudflare nameservers.

Sanity-check before applying:

    do-run doctl compute size list | grep -i amd
    do-run doctl compute image list-distribution | grep -i debian

Debian 13 is required, not preferred: `install_base_packages` installs Caddy
from Debian main, which ships it from trixie onward. On Debian 12 the bootstrap
dies.

## Bringing the host up as a follower first

When migrating an existing validator, bring this host up as a **follower** — a
fully-synced node that is not in the validator set — and move the signing key
only after the old host has stopped. That keeps the invariant that matters:

> The validator signing key is live on exactly one host at any moment.

A CometBFT node always has a `priv_validator_key.json`; a follower's is simply
not the bonded one, and it signs nothing. The real key never touches this host
until the old one is stopped and confirmed stopped.

Avoid `svote join` with a throwaway identity for this: `join.sh` auto-registers
the throwaway operator address with Valar's queue
(`docs/svote-installer-security-analysis.md` §2.14) and the wrapper will loop
trying to bond it. Prefer a minimal bring-up — binary, genesis, peers, and a
sync from Valar's published snapshot.

## Operator CLI

`svote` is installed at `/usr/local/bin/svote` and runs as the `svote` user.

| Command | What it does |
| --- | --- |
| `svote join` | Interactive join (wraps Valar's `join.sh`) |
| `svote status` | Node, sync and service status |
| `svote addr` | Re-print the approval message for the Valar admin |
| `svote register` | POST the signed registration to Valar's admin API |
| `svote bonded` | Whether the validator is bonded |
| `svote tls-status` | Certificate and DNS check |
| `svote upgrade-status` | Coordinated-upgrade readiness |
| `svote prestage-upgrade` | Stage an upgrade binary ahead of the height |
| `svote backup-keys` | Write an encrypted key archive to the spool |
| `svote restore-keys` | Print the restore procedure |
| `svote reset-snapshot` | Re-sync chain state from Valar's published snapshot |
| `svote logs` | Follow `svoted` |
| `svote remove` | Tear the validator down |

## Danger

The validator signing key must be live on exactly one host. Do not restore it,
or a volume snapshot containing it, onto a second running host — that
double-signs. When decommissioning the old host, `systemctl mask svoted` and
shred the key rather than leaving it stopped-but-intact: a stopped host with a
live key on disk and a stale `priv_validator_state.json` is one console click
away from an equivocation.
