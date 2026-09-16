# DigitalOcean infrastructure

Terraform (OpenTofu) for Zcash infrastructure on DigitalOcean. Currently one
module: [`zcash-vote-validator`](./modules/zcash-vote-validator/), the validator
for Valar Group's [Shielded-Vote](https://setup.valargroup.org/) chain
(`zvote-1`).

It lives here rather than in `gcp/terraform/` because GCP was dropping
Tor-sourced traffic to the helper API, and voters need to reach it over Tor.
Migrated 2026-09-16.

## Layout

```
do/terraform/
  main.tf variables.tf outputs.tf versions.tf   root config
  terraform.tfvars                              gitignored; local values
  modules/zcash-vote-validator/                 the module + its startup.sh
```

State is on GCS, not Spaces — the S3 backend's locking needs conditional writes
that Spaces does not support, and losing state locking is a worse trade than
keeping one GCP dependency.

## Credentials

Export **`DIGITALOCEAN_ACCESS_TOKEN`** on your workstation. That spelling is not
arbitrary: `doctl` reads only that name, while the Terraform provider accepts
either it or `DIGITALOCEAN_TOKEN`.

On the ZF dev boxes it is forwarded over ssh, landed 0600 in tmpfs, and injected
per-process by `do-run` (ansible-toolbox, `dev_server` role) — so it never
touches disk. Prefix every command:

```
do-run tofu plan
do-run doctl compute droplet list
```

**Never run `doctl auth init`** — it writes the token in plaintext to
`~/.config/doctl/config.yaml`.

There is no `var.do_token`, deliberately: a Terraform variable is a second path
to a long-lived bearer token whose scopes are per resource *type*, never per
instance. Team membership is the only real blast-radius boundary, so keep the
team dedicated.

## Known account limits

- **100 GiB per volume.** Not a scope issue; a cap on the account. `size` is
  expandable in place (`If updated, can only be expanded`), so raising it later
  is non-destructive.
- **Never create a `digitalocean_vpc`.** DigitalOcean promotes the first VPC in
  a region to be that region's default, and a default VPC **cannot be deleted** —
  `tofu destroy` fails with `Can not delete default VPCs` and the resource wedges
  in state permanently. The root config uses a `data` source instead.

---

# Operator runbook

The validator is a single DigitalOcean droplet. Everything below assumes ssh as
the admin user (`vote_validator_admin_user`, passwordless sudo). `root` also has
the key; sshd is key-only.

| | |
|---|---|
| Public URL | `https://zvote.zfnd.org` (Cloudflare DNS, **DNS-only, not proxied**) |
| Chain / moniker | `zvote-1` / `ZF` |
| Data volume | `/var/lib/svote`, owned by `svote`, `0700` |
| Validator home | `/var/lib/svote/.svoted` |
| Service | `svoted.service` (cosmovisor → svoted) |
| Operator CLI | `/usr/local/bin/svote`, run as the `svote` user |
| Config | `/etc/default/svote` (no secrets; world-readable by design) |

## Day to day

```bash
sudo -iu svote svote status          # node, sync and service status
sudo -iu svote svote bonded          # is the validator bonded
sudo -iu svote svote logs            # follow svoted
sudo -iu svote svote tls-status      # certificate and DNS check
sudo -iu svote svote upgrade-status  # coordinated-upgrade readiness
```

Is it actually signing? Being caught up is not the same thing:

```bash
# priv_validator_state.json must advance
jq -r .height /var/lib/svote/.svoted/data/priv_validator_state.json
```

External check: the Uptime Kuma probe `Zcash Vote Validator API`
(infra-monitoring-kuma) polls `/cosmos/base/tendermint/v1beta1/node_info` and
alerts Slack. It probes the chain API, not just the host, so green means the
chain is answering.

## Key backup — the only thing that is irreplaceable

Chain state re-syncs from Valar's published snapshot. The signing key does not.

```bash
sudo -iu svote svote backup-keys     # writes an age-encrypted archive to the spool
ls -l /var/lib/svote/keybackup/
```

Archives are encrypted to `key_backup_age_recipient` before they are written, so
the spool holds no plaintext. **Nothing uploads them.** A spool that has never
been collected is not a backup — copy one off the host and verify you can
decrypt it:

```bash
rage -d -i /path/to/svote-backup-identity.txt keys-<stamp>.tar.age | tar -tzvf -
```

Expect 7 entries: `config/priv_validator_key.json`, `config/node_key.json`,
`keyring-test/`, and `ea.*` / `pallas.*`. The identity file must never live on
the droplet.

Restore procedure: `sudo -iu svote svote restore-keys` prints it.

> On GCE the bucket ACL made backups unforgeable — the host could create but not
> delete them. DigitalOcean cannot express that, so the integrity guarantee now
> comes from archives living somewhere the validator cannot reach. See the
> module README.

## Coordinated chain upgrades

A daily timer (`svote-upgrade-check.timer`, 07:20 UTC) checks readiness and
leaves a marker that the login banner surfaces.

```bash
sudo -iu svote svote upgrade-status        # what is scheduled, are we ready
sudo -iu svote svote prestage-upgrade      # stage the binary ahead of the height
```

Pre-staging is the plan; cosmovisor auto-download
(`DAEMON_ALLOW_DOWNLOAD_BINARIES=true`, always with
`DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true`) is the fallback. See
`docs/svote-installer-security-analysis.md` §2.11 for what that grants chain
governance.

Cosmovisor's pre-upgrade data copy is **disabled** per
[Valar's guidance](https://setup.valargroup.org/#cosmovisor-backup-maintenance),
via `/etc/systemd/system/svoted.service.d/zz-cosmovisor-skip-backup.conf`. Verify
it reaches the running process, not just the file:

```bash
tr '\0' '\n' < /proc/$(systemctl show svoted -p MainPID --value)/environ \
  | grep UNSAFE_SKIP_BACKUP
ls -d /var/lib/svote/.svoted/data-backup-* 2>/dev/null || echo "none — correct"
```

## Patching and reboots

`unattended-upgrades` is enabled (from the DO image) and
`Unattended-Upgrade::Automatic-Reboot` is pinned **false** by the bootstrap.
Reboots are an operator action, because a reboot also re-runs the bootstrap and
restarts the validator.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot        # svoted is enabled; it comes back on its own
```

After a reboot, confirm the per-boot hook ran and the node resumed:

```bash
sudo tail -20 /var/log/zcash-vote-validator-startup.log
sudo -iu svote svote status
```

## Changing the bootstrap script

`user_data` is `ForceNew` on `digitalocean_droplet`, so it is under
`ignore_changes`: **Terraform will not push an edited `startup.sh` to a running
host, and `plan` will report no changes.** Without that guard, editing the script
would destroy the droplet and the signing key with it.

The supported path:

```bash
do-run tofu apply                                          # refresh outputs
do-run tofu output -raw vote_validator_startup_script > /tmp/startup.sh
scp /tmp/startup.sh <admin>@<ip>:/tmp/startup.sh
ssh <admin>@<ip> 'sudo install -m 0700 /tmp/startup.sh \
  /usr/local/sbin/zcash-vote-validator-startup.sh && \
  sudo /usr/local/sbin/zcash-vote-validator-startup.sh'
```

The script is idempotent and safe to run with svoted live — it never touches
`$SVOTE_HOME`. A clean re-run logs almost nothing; that is the point.

## Certificates and DNS

Caddy terminates TLS and reverse-proxies `:443` → `:1317`. It obtains and renews
via Let's Encrypt HTTP-01, so **`:80` must stay open** and the A record must be
**DNS-only**, never proxied — a proxy breaks issuance and hides the origin from
the chain's reachability checks.

```bash
sudo -iu svote svote tls-status
sudo cat /etc/caddy/Caddyfile
```

## Emergencies

**Node not signing.** Check in this order: `systemctl is-active svoted`,
`svote logs`, disk space (`df -h /var/lib/svote`), then peers via
`curl -s localhost:26657/net_info | jq '.result.n_peers'`.

**Disk full.** The volume is capped at 100 GiB by the account limit. Chain state
was ~13 GB at migration. If it grows: raise the cap with DO support, then
increase `vote_validator_data_disk_size` — expansion is in place and
non-destructive. Check for stray `data-backup-*` directories first.

**Corrupt chain state.** `sudo -iu svote svote reset-snapshot` re-syncs from
Valar's published snapshot; it is checksum-verified and preserves
`priv_validator_state.json`. It backs up keys first.

**Suspected key compromise.** Treat as an incident, not a rebuild: the signing
key cannot be rotated without chain-side coordination. Contact the Valar Group
admin.

## Rebuilding or migrating the host

**The one invariant: the signing key is live on exactly one host at a time.**

Order is what makes this safe, not care:

1. Copy the data volume **while the old host still runs** —
   `rsync -aHAX --exclude 'data-backup-*' --rsync-path='sudo rsync'`. No
   `--delete` on this pass. Do **not** copy `svoted.service` yet; with no unit
   file the new host is *structurally* unable to sign.
2. Stop and disable svoted on the old host. Confirm with `pgrep -x svoted`, not
   `pgrep -f` (which matches `journalctl -u svoted`). Note the height in
   `data/priv_validator_state.json`.
3. Repeat the rsync **with `--delete`** — a live database copy is inconsistent,
   and only this pass reconciles it.
4. **Now** copy `/etc/systemd/system/svoted.service`, plus Caddy's storage
   (`/var/lib/caddy/.local/share/caddy/`) to carry the certificate over.
5. `systemd-analyze verify svoted.service`, then `systemctl enable --now svoted`.
6. Flip DNS. Confirm the state file advances past the height from step 2.
7. Decommission the old host: `systemctl mask svoted` (move the unit file aside
   first if it is a real file in `/etc/systemd/system`), shred the key material,
   power off, and **delete any disk snapshots** — they are full images taken
   before the shred.

Do not run `svote join` on a host that is being migrated onto. It is for a
*new* validator: it begins with `rm -rf $SVOTE_HOME` and auto-registers with
Valar's queue.

## Do not

- `tofu destroy` — the volume carries `prevent_destroy` and will refuse, which is
  the intent. Removing a validator is a deliberate act.
- Proxy the A record through Cloudflare.
- Put a cloud API token on the droplet. Nothing there needs one.
- Run two hosts with the same `priv_validator_key.json`.
