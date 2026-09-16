#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/${module_role}-startup.log"
exec > >(tee -a "$LOG_FILE" | logger -t "${module_role}-startup") 2>&1

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

APP_USER="svote"
SVOTE_MOUNT_PATH="${svote_mount_path}"
SVOTE_HOME="$SVOTE_MOUNT_PATH/.svoted"
INSTALL_DIR="$SVOTE_MOUNT_PATH/.local/bin"
BASE_STATE_DIR="/var/lib/${module_role}"
BASE_MARKER_PATH="$BASE_STATE_DIR/base-provisioned"

# DigitalOcean names attached volumes /dev/disk/by-id/scsi-0DO_Volume_<name>.
# Like GCE's google-<name>, this is derived from a name we control rather than
# kernel enumeration order, so it is stable across reboots and reattachments.
#
# Resolved lazily, not here: on GCE the attached_disk block guarantees the
# device exists before the startup script runs, but on DigitalOcean cloud-init
# can win the race against the volume attach. Resolving at script scope under
# `set -e` would abort the whole bootstrap, and because cloud-init's user-data
# phase runs once, that host would never be provisioned at all.
DATA_DISK_BY_ID="/dev/disk/by-id/scsi-0DO_Volume_${data_disk_name}"
DATA_DISK_PATH=""

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

host_public_ip() {
  # DigitalOcean's metadata service: no header, no auth, and -- unlike GCE's --
  # no credentials of any kind, which is why nothing on this host holds a cloud
  # API token.
  curl -fsSL --max-time 5 \
    "http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address" \
    2>/dev/null || true
}

effective_tls_domain() {
  # tls_domain wins when set. Otherwise fall back to an sslip.io name derived
  # from this droplet's own public address.
  #
  # Derived here at boot, not in Terraform: a droplet's address does not exist
  # as a separate resource the way google_compute_address did, so templating it
  # into user_data would be a dependency cycle -- the address is an attribute of
  # the very resource user_data configures. Deriving it on the host also keeps
  # the fallback correct if the address ever changes, which the GCE version
  # could not do without a re-apply.
  local ip

  if [ -n "${tls_domain}" ]; then
    printf '%s' "${tls_domain}"
    return 0
  fi

  ip="$(host_public_ip)"
  if [ -z "$ip" ]; then
    log "WARNING: no tls_domain set and the metadata service returned no public IP"
    return 0
  fi

  printf '%s.sslip.io' "$(printf '%s' "$ip" | tr '.' '-')"
}

ensure_user() {
  # Home is the persistent data disk mount point, so the account is created
  # without -m and the mount point itself is populated in ensure_data_disk.
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Creating $APP_USER account with home $SVOTE_MOUNT_PATH"
    useradd -M -d "$SVOTE_MOUNT_PATH" -s /bin/bash "$APP_USER"
  fi
}

# apt on a freshly booted GCE instance competes with apt-daily and
# unattended-upgrades, and a stalled mirror connection will otherwise hang
# indefinitely while holding the dpkg frontend lock. DPkg::Lock::Timeout makes
# lock waits bounded and graceful (apt >= 1.9, so Debian 11+); the Acquire
# options make a wedged mirror fail and retry instead of hanging forever.
apt_get() {
  apt-get \
    -o DPkg::Lock::Timeout=600 \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    "$@"
}

install_base_packages() {
  log "Installing base packages"
  apt_get update

  # caddy is installed here, at provisioning time, rather than left to the
  # installer. join.sh only installs Caddy when `command -v caddy` fails, and its
  # path adds the cloudsmith apt repo via two curls with no timeout plus a
  # `gpg --dearmor` that prompts if the keyring already exists -- all during the
  # join, where a stall blocks the operator with apt's output hidden. Debian 13
  # ships caddy 2.6.2 in main, which is ample for `reverse_proxy` plus ACME, so
  # installing it up front makes that whole block a no-op.
  #
  # For a newer Caddy, trixie-backports has 2.11.x.
  # rsync is not in the Debian cloud image and is not optional here: migrating a
  # validator onto or off this host is an rsync of the data volume, and finding
  # it missing at cutover -- with the daemon already stopped -- is the wrong time
  # to discover it. It is also what makes a two-pass migration possible, where
  # the bulk copies while the old host still signs and only a delta lands in the
  # downtime window.
  apt_get install -y \
    ca-certificates \
    caddy \
    curl \
    htop \
    jq \
    lz4 \
    rsync \
    tmux
}

install_tmux_config() {
  # The validator join is a long interactive session; tmux keeps it alive across
  # an SSH disconnect.
  log "Installing global tmux configuration"
  cat <<'EOF' > /etc/tmux.conf
# --- Screen Compatibility Basics ---

# 1. Remap Prefix to Control-A
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# 2. Basic Screen Behavior
set -g history-limit 10000
set -g default-command "$SHELL"
set -g base-index 1

# 3. Navigation Bindings
bind C-a last-window
bind space next-window
bind BSpace previous-window

# F1 - F12 Select Windows 1 - 12
bind -n F1 select-window -t 1
bind -n F2 select-window -t 2
bind -n F3 select-window -t 3
bind -n F4 select-window -t 4
bind -n F5 select-window -t 5
bind -n F6 select-window -t 6
bind -n F7 select-window -t 7
bind -n F8 select-window -t 8
bind -n F9 select-window -t 9
bind -n F10 select-window -t 10
bind -n F11 select-window -t 11
bind -n F12 select-window -t 12

# Mouse Support for scrolling
set -g mouse on

# Performance improvements
set -s escape-time 0

# Status bar shows window indexes alongside names.
set -g status-bg black
set -g status-fg white
set -g status-left ""
setw -g window-status-current-format "#[fg=red,bold]#I:#W#[default]"
setw -g window-status-format "#I:#W"
EOF
}

install_global_bash_aliases() {
  local alias_line="alias ll='ls -laF'"

  if grep -Fqx "$alias_line" /etc/bash.bashrc; then
    return
  fi

  printf '\n# Added by %s startup\n%s\n' "${module_role}" "$alias_line" >> /etc/bash.bashrc
}

ensure_rage() {
  # rage provides the age encryption used to protect validator key backups. It is
  # not packaged in Debian, so it comes from the upstream release .deb. Lifted
  # from the z3 module's ensure_rage.
  local dpkg_arch
  local github_api_url
  local rage_asset_url
  local rage_package_path

  if command -v rage-keygen >/dev/null 2>&1; then
    log "rage already installed"
    return
  fi

  dpkg_arch="$(dpkg --print-architecture)"
  github_api_url="https://api.github.com/repos/str4d/rage/releases/latest"
  rage_package_path="/tmp/rage_latest_$${dpkg_arch}.deb"

  log "Installing latest rage binary package for architecture $${dpkg_arch}"
  rage_asset_url="$(curl -fsSL "$github_api_url" | jq -r --arg suffix "_$dpkg_arch.deb" '.assets[] | select(.name | startswith("rage_") and endswith($suffix)) | .browser_download_url' | head -n 1)"

  if [ -z "$rage_asset_url" ] || [ "$rage_asset_url" = "null" ]; then
    log "No compatible rage Debian package found for architecture $${dpkg_arch}"
    exit 1
  fi

  curl -fsSL "$rage_asset_url" -o "$rage_package_path"
  apt_get install -y "$rage_package_path"
  rm -f "$rage_package_path"
}

wait_for_data_disk() {
  # Gives the volume attach up to ~2 minutes to land before giving up. Failing
  # loudly here is the right outcome: every later step writes to the mount, so
  # continuing without it would put chain state on the boot disk.
  local waited=0
  local limit=120

  while [ ! -e "$DATA_DISK_BY_ID" ]; do
    if [ "$waited" -ge "$limit" ]; then
      log "Data disk $DATA_DISK_BY_ID did not appear after $${limit}s"
      return 1
    fi
    [ "$waited" -eq 0 ] && log "Waiting for data disk $DATA_DISK_BY_ID"
    sleep 2
    waited=$((waited + 2))
  done

  DATA_DISK_PATH="$(readlink -f "$DATA_DISK_BY_ID")"
  log "Data disk $DATA_DISK_BY_ID resolves to $DATA_DISK_PATH"
}

remove_do_automount() {
  # DigitalOcean's own volume tooling can leave an /etc/fstab entry mounting the
  # volume under /mnt/<name>. Ours mounts the same device at SVOTE_MOUNT_PATH,
  # and two entries for one device is a boot-order coin flip, so drop theirs.
  #
  # Exact field comparison rather than a regex: the device path is full of
  # characters that are regex metacharacters, and interpolating it into a
  # pattern is both fragile and ambiguous to parse.
  [ -f /etc/fstab ] || return 0

  if awk -v dev="$DATA_DISK_BY_ID" \
    '$1 == dev && $2 ~ "^/mnt/" { found = 1 } END { exit !found }' /etc/fstab; then
    log "Removing DigitalOcean's /mnt automount entry for ${data_disk_name}"
    awk -v dev="$DATA_DISK_BY_ID" \
      '!($1 == dev && $2 ~ "^/mnt/")' /etc/fstab > /etc/fstab.svote-tmp
    mv /etc/fstab.svote-tmp /etc/fstab
  fi
}

ensure_data_disk() {
  local current_disk_format
  local disk_uuid
  local skel_file
  local target

  log "Preparing persistent data disk ${data_disk_name}"
  wait_for_data_disk
  remove_do_automount
  current_disk_format="$(lsblk -i -n -o fstype "$DATA_DISK_PATH")"

  if [ "$current_disk_format" != "ext4" ]; then
    log "Formatting $DATA_DISK_PATH as ext4"
    mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK_PATH"
  fi

  mkdir -p "$SVOTE_MOUNT_PATH"
  disk_uuid="$(blkid -s UUID -o value "$DATA_DISK_PATH")"

  if ! grep -q " $SVOTE_MOUNT_PATH " /etc/fstab; then
    echo "UUID=$disk_uuid $SVOTE_MOUNT_PATH ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi

  if ! mountpoint -q "$SVOTE_MOUNT_PATH"; then
    mount "$SVOTE_MOUNT_PATH"
  fi

  # Only walk the whole tree when ownership is actually wrong (first boot, or a
  # disk restored from a snapshot taken on a host with different UIDs). On an
  # ordinary reboot this is a single stat instead of a recursive chown over
  # ~100 GB of chain data.
  if [ "$(stat -c %U "$SVOTE_MOUNT_PATH")" != "$APP_USER" ]; then
    log "Taking ownership of $SVOTE_MOUNT_PATH for $APP_USER"
    chown -R "$APP_USER:$APP_USER" "$SVOTE_MOUNT_PATH"
  fi
  chmod 700 "$SVOTE_MOUNT_PATH"

  # The account was created with -M, so seed the shell dotfiles the first time
  # the disk is mounted; `sudo -iu svote` expects them.
  for skel_file in .bashrc .profile; do
    target="$SVOTE_MOUNT_PATH/$skel_file"
    if [ ! -f "$target" ] && [ -f "/etc/skel/$skel_file" ]; then
      install -o "$APP_USER" -g "$APP_USER" -m 0644 "/etc/skel/$skel_file" "$target"
    fi
  done

  # One level at a time: `install -d a/b` applies -o/-g only to the final
  # component, which would leave ~/.local owned by root inside the app user's
  # home.
  install -o "$APP_USER" -g "$APP_USER" -d "$SVOTE_MOUNT_PATH/.local"
  install -o "$APP_USER" -g "$APP_USER" -d "$INSTALL_DIR"
}

ensure_admin_user() {
  # A non-root login account, because DigitalOcean gives you root and nothing
  # else: it injects the configured keys into root's authorized_keys at droplet
  # creation and never touches any other account. So an admin user only exists
  # if this script makes one, and it only has keys if this script copies them.
  #
  # Skipped entirely when admin_user is empty, which leaves the host root-only.
  local admin="${admin_user}"
  local home
  local sudoers_file
  local key

  [ -n "$admin" ] || return 0

  if ! id -u "$admin" >/dev/null 2>&1; then
    log "Creating admin account $admin"
    useradd -m -s /bin/bash "$admin"
  fi

  home="$(getent passwd "$admin" | cut -d: -f6)"
  [ -n "$home" ] || { log "ERROR: no home directory for $admin"; return 1; }

  install -o "$admin" -g "$admin" -m 0700 -d "$home/.ssh"
  touch "$home/.ssh/authorized_keys"

  # Merge rather than overwrite. Copying wholesale would clobber keys an
  # operator added by hand, and seeding once would never pick up a key added to
  # root later. Appending only what is missing does both, and is a no-op on the
  # common re-run.
  if [ -f /root/.ssh/authorized_keys ]; then
    while IFS= read -r key; do
      case "$key" in ''|\#*) continue ;; esac
      if ! grep -qxF "$key" "$home/.ssh/authorized_keys"; then
        log "Authorising a key from root for $admin"
        printf '%s\n' "$key" >> "$home/.ssh/authorized_keys"
      fi
    done < /root/.ssh/authorized_keys
  fi

  chown "$admin:$admin" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"

  if [ ! -s "$home/.ssh/authorized_keys" ]; then
    log "WARNING: $admin has no authorized keys; root is still the only way in"
  fi

  # Passwordless, because the account has no password to give: it is created
  # without one, so a sudo that prompts is a sudo that can never succeed.
  sudoers_file="/etc/sudoers.d/$admin"
  cat <<EOF > "$sudoers_file.tmp"
# Installed by ${module_role} startup. $admin is the non-root login account;
# the account has no password, so sudo has to be passwordless to work at all.
$admin ALL=(ALL) NOPASSWD: ALL
EOF

  chmod 0440 "$sudoers_file.tmp"
  if visudo -cqf "$sudoers_file.tmp"; then
    mv "$sudoers_file.tmp" "$sudoers_file"
  else
    rm -f "$sudoers_file.tmp"
    log "Refusing to install malformed sudoers fragment for $admin"
    exit 1
  fi
}

harden_sshd() {
  # On GCE this host was reachable on :22 only through Google's IAP forwarders,
  # gated by Cloud IAM. DigitalOcean has no equivalent and ssh_source_ranges is
  # deliberately open, so sshd is on the public internet and the remaining
  # control is the key itself. Assert that explicitly rather than inheriting
  # whatever the image ships.
  #
  # A drop-in rather than editing sshd_config: survives an openssh-server
  # upgrade, and the 60- prefix sorts after the image's own drop-ins.
  #
  # A drop-in rather than editing sshd_config: survives an openssh-server
  # upgrade, and the 60- prefix sorts after the image's own drop-ins.
  local dropin="/etc/ssh/sshd_config.d/60-${module_role}.conf"
  local root_login="${permit_root_login}"
  local admin="${admin_user}"
  local admin_home
  local tmp
  local unit

  # Refuse to lock root out unless somebody else can actually get in. The
  # configured value is only honoured once the admin account exists AND holds at
  # least one key -- otherwise this silently downgrades to prohibit-password.
  # Getting this wrong costs the host, and the check is two lines.
  if [ "$root_login" = "no" ]; then
    admin_home="$(getent passwd "$admin" 2>/dev/null | cut -d: -f6)"
    if [ -z "$admin" ] || [ -z "$admin_home" ] || [ ! -s "$admin_home/.ssh/authorized_keys" ]; then
      log "WARNING: permit_root_login=no requested, but $${admin:-<no admin user>} cannot log in yet."
      log "         Falling back to prohibit-password rather than locking this host out."
      root_login="prohibit-password"
    fi
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d

  tmp="$(mktemp)"
  cat <<SSHD > "$tmp"
# Managed by ${module_role} startup. Edits here are overwritten on next boot.
PermitRootLogin $root_login
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSHD

  if [ -f "$dropin" ] && cmp -s "$tmp" "$dropin"; then
    rm -f "$tmp"
    return 0
  fi

  log "Hardening sshd (key-only, no password auth, PermitRootLogin $root_login)"
  install -m 0644 "$tmp" "$dropin"
  rm -f "$tmp"

  # Never reload a configuration sshd rejects -- that is how a remote host is
  # lost. Roll the drop-in back instead and leave the running daemon alone.
  if ! sshd -t 2>/dev/null; then
    log "ERROR: sshd rejected the hardening drop-in; removing it and leaving sshd as-is"
    rm -f "$dropin"
    return 1
  fi

  # Debian 13 ships the socket-activated unit as 'ssh'; 'sshd' is an alias on
  # some images and absent on others.
  for unit in ssh sshd; do
    if systemctl list-unit-files "$${unit}.service" >/dev/null 2>&1 \
       && systemctl is-active --quiet "$unit"; then
      systemctl reload "$unit" || systemctl restart "$unit"
      break
    fi
  done
}

pin_unattended_upgrades() {
  # DigitalOcean's Debian image ships unattended-upgrades enabled, which is
  # fine and left alone -- security patching should happen. What is not fine is
  # that Automatic-Reboot is nowhere on disk: Debian's built-in default is
  # false, so the behaviour is right today, but it is implicit and a future
  # image could ship it differently.
  #
  # Pin it, because an unattended reboot is not a small event on this host. It
  # re-runs this bootstrap, and after cutover it restarts the validator at a
  # moment nobody chose. Reboots stay an operator action.
  #
  # 99 prefix so it sorts after 50unattended-upgrades; apt reads apt.conf.d in
  # lexical order and the last assignment wins. Not narrowing Allowed-Origins
  # here -- the image includes the main Debian archive alongside security, which
  # is broader than security-only but is a deliberate call to leave to the
  # operator, not something to change silently from a boot script.
  local conf="/etc/apt/apt.conf.d/99zcash-vote-validator.conf"
  local tmp

  tmp="$(mktemp)"
  cat <<'APTCONF' > "$tmp"
// Managed by zcash-vote-validator startup. Edits are overwritten on next boot.
// Reboots are an operator action: an unattended one re-runs the bootstrap and,
// once a validator is present, restarts it unannounced.
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF

  if [ -f "$conf" ] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    return 0
  fi

  log "Pinning Unattended-Upgrade::Automatic-Reboot=false"
  install -m 0644 "$tmp" "$conf"
  rm -f "$tmp"

  # apt parses its configuration on every invocation, so nothing to reload --
  # but a malformed fragment breaks every later apt call, so prove it parses.
  if ! apt-config dump >/dev/null 2>&1; then
    log "ERROR: apt rejected the config fragment; removing it"
    rm -f "$conf"
    return 1
  fi
}

configure_sudoers() {
  # join.sh is not optional about this: it writes systemd units with `sudo tee`,
  # installs Caddy with `sudo apt-get`, and calls `sudo systemctl` non
  # interactively. Running the installer as an unprivileged account is still
  # worth it, because the unit it generates hard-codes User=$(whoami) — running
  # join.sh as root would leave svoted itself running as root.
  local sudoers_file="/etc/sudoers.d/svote"

  log "Granting $APP_USER passwordless sudo (required by the upstream installer)"
  cat <<EOF > "$sudoers_file.tmp"
# Installed by ${module_role} startup. Required by Valar Group's join.sh, which
# writes systemd units and installs packages via sudo. See
# docs/svote-installer-security-analysis.md; this grant makes the $APP_USER
# account root-equivalent and can be revoked once the validator is bonded.
$APP_USER ALL=(ALL) NOPASSWD: ALL
EOF

  chmod 0440 "$sudoers_file.tmp"
  if visudo -cqf "$sudoers_file.tmp"; then
    mv "$sudoers_file.tmp" "$sudoers_file"
  else
    rm -f "$sudoers_file.tmp"
    log "Refusing to install malformed sudoers fragment"
    exit 1
  fi
}

write_svote_env_file() {
  # Single source of truth for the operator CLI and the key backup unit, so
  # none of them have to be re-templated to change a value.
  local TLS_DOMAIN
  TLS_DOMAIN="$(effective_tls_domain)"

  log "Writing /etc/default/svote"

  cat <<EOF > /etc/default/svote
# Written by ${module_role} startup. Consumed by /usr/local/bin/svote,
# and /usr/local/bin/svote-backup-keys.
SVOTE_APP_USER="$APP_USER"
SVOTE_MOUNT_PATH="$SVOTE_MOUNT_PATH"
SVOTE_HOME="$SVOTE_HOME"
SVOTE_INSTALL_DIR="$INSTALL_DIR"
SVOTE_ENV="${svote_env}"
SVOTE_UPGRADE_MODE="${upgrade_mode}"
SVOTE_TLS_DOMAIN="$TLS_DOMAIN"
SVOTE_HELPER_API_PORT="${helper_api_port}"
SVOTE_P2P_PORT="${p2p_port}"
SVOTE_JOIN_SCRIPT_URL="${join_script_url}"
SVOTE_JOIN_SCRIPT_SHA256="${join_script_sha256}"
SVOTE_ADMIN_URL="${svote_admin_url}"
SVOTE_MONIKER="${moniker}"
SVOTE_JOIN_TIMEOUT="${join_timeout_seconds}"
SVOTE_ALLOW_BINARY_AUTODOWNLOAD="${allow_binary_autodownload}"
SVOTE_KEY_BACKUP_AGE_RECIPIENT="${key_backup_age_recipient}"
SVOTE_KEY_BACKUP_SPOOL="$SVOTE_MOUNT_PATH/keybackup"
SVOTE_KEY_BACKUP_KEEP="${key_backup_keep_count}"
SVOTE_KEY_BACKUP_MARKER="$SVOTE_MOUNT_PATH/.key-backup-configured"
SVOTE_UPGRADE_MARKER="$SVOTE_MOUNT_PATH/.upgrade-action-needed"
SVOTE_DATA_DISK_NAME="${data_disk_name}"
SVOTE_HOSTNAME="${hostname}"
EOF

  # 0644 is deliberate, and stays safe only while this file holds no secret. The
  # unprivileged svote CLI sources it, so it has to be world-readable. If a
  # credential is ever added, put it in a 0600 /etc/default/svote-secrets
  # sourced only by the root-run units rather than loosening this.
  chmod 0644 /etc/default/svote
}

install_upgrade_staging() {
  # Joining from a published snapshot restores data/upgrade-info.json describing
  # an already-applied upgrade. Cosmovisor reads that on start, decides it must
  # run cosmovisor/upgrades/<name>/bin/svoted, finds only genesis/bin/svoted, and
  # exits 1. Every new validator hits this, so stage the binary before svoted
  # starts.
  #
  # Auto-download cannot rescue this case even when enabled: that plan's `info`
  # carries no `binaries` map, so with DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true
  # there is nothing for cosmovisor to fetch. Only newer plans ship binaries.
  #
  # Blindly staging the installed binary would be wrong for a *future* upgrade --
  # running an old binary past an upgrade height diverges the app hash. So this
  # only acts when the required tag recorded in upgrade-info.json is satisfied by
  # what is installed, and otherwise says what to do instead.
  log "Installing cosmovisor upgrade staging helper"

  cat <<'EOF' > /usr/local/bin/svote-stage-upgrades
#!/bin/bash
# Stage the installed svoted as the binary for an already-applied upgrade.
# Runs from svoted.service's ExecStartPre. Advisory: always exits 0, so it can
# never be the reason the daemon fails to start.
set -uo pipefail

# shellcheck disable=SC1091
. /etc/default/svote

log() {
  echo "svote-stage-upgrades: $*"
}

info_file="$SVOTE_HOME/data/upgrade-info.json"
genesis_bin="$SVOTE_HOME/cosmovisor/genesis/bin/svoted"

[ -f "$info_file" ] || exit 0
[ -x "$genesis_bin" ] || exit 0

name="$(jq -r '.name // empty' "$info_file" 2>/dev/null || true)"
[ -n "$name" ] || exit 0

target="$SVOTE_HOME/cosmovisor/upgrades/$name/bin/svoted"
if [ -x "$target" ]; then
  exit 0
fi

height="$(jq -r '.height // empty' "$info_file" 2>/dev/null || true)"
# The upgrade plan records the binary tag it expects inside .info, itself a JSON
# string. fromjson? yields empty rather than failing on anything unparseable.
required="$(jq -r '(.info // "") | (fromjson? // {}) | .tag // empty' "$info_file" 2>/dev/null || true)"
installed="$("$genesis_bin" version 2>/dev/null | tr -d '[:space:]' || true)"

# Satisfied when major and minor match and the installed patch is not older.
# Cosmos patch releases within a minor are state-machine compatible; a different
# major or minor is a consensus change and must not be substituted.
satisfies() {
  local inst="$${1#v}"
  local req="$${2#v}"
  local i_ma i_mi i_pa r_ma r_mi r_pa

  [ -n "$req" ] || return 1
  IFS=. read -r i_ma i_mi i_pa <<<"$inst"
  IFS=. read -r r_ma r_mi r_pa <<<"$req"
  [ "$${i_ma:-x}" = "$${r_ma:-y}" ] &&
    [ "$${i_mi:-x}" = "$${r_mi:-y}" ] &&
    [ "$${i_pa:-0}" -ge "$${r_pa:-0}" ] 2>/dev/null
}

if satisfies "$installed" "$required"; then
  log "staging $installed as the binary for applied upgrade '$name' (height $height, requires $required)"
  # mkdir -p then install, rather than `install -D`, which is a GNU extension.
  if mkdir -p "$(dirname "$target")" && install -m 0755 "$genesis_bin" "$target"; then
    log "staged $target"
  else
    log "WARNING: could not stage $target"
  fi
  exit 0
fi

log "WARNING: upgrade '$name' (height $height) needs binary tag $${required:-<unknown>}, but $${installed:-<unknown>} is installed."
log "         Refusing to substitute it: running the wrong binary past an upgrade height diverges the app hash."
log "         Stage the correct binary first:  svote prestage-upgrade $name <tag>"
exit 0
EOF
  chmod 0755 /usr/local/bin/svote-stage-upgrades
}

write_caddyfile() {
  # The module owns the Caddyfile so that changing the public hostname is a
  # supported operation. join.sh writes this file too, but only during a join,
  # and a join is destructive so it is never re-run: without this, changing
  # tls_domain would update /etc/default/svote and nothing else, leaving Caddy
  # still serving a certificate for the old name.
  #
  # Same content shape as join.sh:1476-1486, so on a host whose domain has not
  # changed this is a no-op.
  local caddyfile="/etc/caddy/Caddyfile"
  local desired
  local domain
  local tmp

  # Resolved at boot, not templated: see effective_tls_domain.
  domain="$(effective_tls_domain)"

  if [ -z "$domain" ]; then
    log "No TLS domain configured; leaving Caddy alone"
    return
  fi

  if ! command -v caddy >/dev/null 2>&1; then
    log "Caddy is not installed yet (installed during 'svote join'); skipping Caddyfile"
    return
  fi

  desired="$(printf '%s {\n    reverse_proxy localhost:%s\n}\n' "$domain" "${helper_api_port}")"

  if [ -f "$caddyfile" ] && [ "$(cat "$caddyfile")" = "$desired" ]; then
    log "Caddyfile already serves $domain"
  else
    log "Writing Caddyfile for $domain -> localhost:${helper_api_port}"
    install -d -m 0755 /etc/caddy
    tmp="$(mktemp)"
    printf '%s' "$desired" > "$tmp"

    if ! caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1; then
      log "Refusing to install a Caddyfile that does not validate"
      caddy validate --config "$tmp" --adapter caddyfile || true
      rm -f "$tmp"
      return 1
    fi

    install -m 0644 "$tmp" "$caddyfile"
    rm -f "$tmp"
  fi

  # Reload rather than restart: a reload keeps existing connections and, more
  # importantly, does not drop the certificates Caddy already holds.
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy || systemctl restart caddy
  else
    systemctl enable --now caddy
  fi
}

stage_svoted_hardening_dropin() {
  # Written before svoted.service exists. systemd applies drop-ins as soon as the
  # unit appears, and unlike editing the generated unit this survives join.sh
  # rewriting it. Upstream's unit ships none of these; the sibling
  # zcash-vote-server repo's hand-written units do.
  #
  # ProtectHome is safe here because SVOTE_HOME lives under /var/lib, not /home.
  log "Staging svoted systemd hardening drop-in"
  install -d -m 0755 /etc/systemd/system/svoted.service.d

  cat <<EOF > /etc/systemd/system/svoted.service.d/10-hardening.conf
# Installed by ${module_role} startup, ahead of the unit that join.sh generates.
[Service]

# Do not resolve the interpreter through \$PATH. The wrapper's shebang is
# '#!/usr/bin/env bash', so the generated unit depends on PATH lookup succeeding
# inside the service's namespace; when it does not, the daemon dies at startup
# with 'env: bash: Not a directory' and exit 126, which is opaque. An absolute
# interpreter removes the lookup entirely. The empty ExecStart= is required to
# reset the value inherited from the generated unit before setting a new one.

# Stage the binary for an already-applied upgrade before cosmovisor looks for it.
# Advisory only: the helper always exits 0.
ExecStartPre=/usr/local/bin/svote-stage-upgrades

ExecStart=
ExecStart=/usr/bin/bash $INSTALL_DIR/svoted-wrapper.sh

# Environment= accumulates across drop-ins with last-assignment-wins, so this
# overrides the PATH the generated unit sets. Same entries minus the macOS
# Homebrew path, plus the sbin directories.
Environment=PATH=$INSTALL_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WorkingDirectory=$SVOTE_MOUNT_PATH

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ProtectControlGroups=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LimitNOFILE=65536
EOF

  # Pin the declared moniker. The generated unit bakes in whatever was typed at
  # the installer's prompt, and the wrapper passes MONIKER to create-val-tx when
  # it bonds, so an unpinned typo becomes the on-chain validator name. Appended
  # conditionally: the wrapper treats an empty MONIKER as fatal, so emitting the
  # line with no value would be worse than omitting it.
  if [ -n "${moniker}" ]; then
    cat <<EOF >> /etc/systemd/system/svoted.service.d/10-hardening.conf
Environment=MONIKER=${moniker}
EOF
  fi

  # Cosmovisor auto-download. The generated unit sets
  # DAEMON_ALLOW_DOWNLOAD_BINARIES=false; Environment= accumulates across drop-ins
  # with last-assignment-wins, so this overrides it. MUST_HAVE_CHECKSUM is not
  # optional -- without it cosmovisor would accept an unchecksummed binary from
  # the plan. See docs/svote-installer-security-analysis.md section 2.11 for what
  # this grants chain governance.
  if [ "${allow_binary_autodownload}" = "true" ]; then
    cat <<EOF >> /etc/systemd/system/svoted.service.d/10-hardening.conf
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=true
Environment=DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true
EOF
  fi

  systemctl daemon-reload
}

stage_cosmovisor_skip_backup_dropin() {
  # Cosmovisor copies the whole data directory before applying an upgrade.
  # Valar Group's guidance is to turn that off permanently
  # (https://setup.valargroup.org/#cosmovisor-backup-maintenance): the copy
  # doubles disk for the duration, and on a validator it delays the restart at
  # exactly the moment the chain wants the node back.
  #
  # Byte-identical, deliberately, to the drop-in Valar's own
  # disable-cosmovisor-backups.sh writes -- same path, same filename, same two
  # lines, same 0644. That script compares the file it finds against the file it
  # would write and reports "already current" when they match, so a host
  # provisioned by this module is already in the state their tooling wants and
  # running it changes nothing. Any edit here breaks that, so don't reformat it.
  #
  # Separate from 10-hardening.conf rather than folded into it for the same
  # reason: their script manages this exact filename, and it sorts after ours,
  # so the two never disagree about who owns the setting.
  #
  # This only stops NEW backups. Existing data-backup-<date> directories under
  # SVOTE_HOME are left alone -- deleting chain data is not something a boot
  # script should do unprompted. Remove them by hand, or with Valar's script.
  local dropin_dir="/etc/systemd/system/svoted.service.d"
  local dropin="$dropin_dir/zz-cosmovisor-skip-backup.conf"
  local tmp

  install -d -m 0755 "$dropin_dir"

  tmp="$(mktemp)"
  printf '[Service]\n' > "$tmp"
  printf 'Environment="UNSAFE_SKIP_BACKUP=true"\n' >> "$tmp"

  if [ -f "$dropin" ] && cmp -s "$tmp" "$dropin"; then
    rm -f "$tmp"
    return 0
  fi

  log "Staging cosmovisor skip-backup drop-in"
  install -m 0644 "$tmp" "$dropin"
  rm -f "$tmp"
  systemctl daemon-reload
}

install_key_backup() {
  # The validator signing key does not exist until `svote join` runs
  # init-validator-keys, so this installs the tooling and leaves the timer
  # disabled.
  log "Installing validator key backup tooling"

  cat <<'EOF' > /usr/local/bin/svote-backup-keys
#!/bin/bash
# Encrypt the validator's key material to an age recipient and write it to a
# local spool directory. Nothing is uploaded.
#
# On GCE this uploaded straight to a bucket on which the instance held
# roles/storage.objectCreator and nothing else, so a compromised validator could
# add backups but never read, overwrite or destroy its own backup history.
# DigitalOcean cannot express that: Spaces access keys come in read, readwrite
# and fullaccess only, bucket policies are mutually exclusive with per-bucket
# keys, and Object Lock is unimplemented. A readwrite key that can delete is
# strictly worse than no key at all, so this host holds no cloud credential and
# the archive is collected out of band.
#
# The archive is still encrypted to the operator's age recipient, so the spool
# holds no plaintext key material and a collector never needs to be trusted with
# any. Retrieve with scp, or point a pull-based collector at the spool over an
# authorized_keys command= restriction.
set -euo pipefail
umask 077

# shellcheck disable=SC1091
. /etc/default/svote

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

if [ -z "$SVOTE_KEY_BACKUP_AGE_RECIPIENT" ]; then
  fail "no age recipient configured (key_backup_age_recipient is empty). Refusing to upload plaintext signing keys. Generate one off-host with 'rage-keygen', set key_backup_age_recipient, and re-apply."
fi

if [ -z "$SVOTE_KEY_BACKUP_SPOOL" ]; then
  fail "no backup spool directory configured."
fi

if [ ! -f "$SVOTE_HOME/config/priv_validator_key.json" ]; then
  fail "$SVOTE_HOME/config/priv_validator_key.json does not exist yet. There is nothing to back up until the validator has been created — run 'svote join' first."
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

listing="$work_dir/paths"
archive="$work_dir/keys.tar.age"
digest_file="$work_dir/keys.tar.age.sha256"

# priv_validator_state.json is deliberately excluded: it is mutable per-block
# state, and restoring a stale copy invites double-signing.
: > "$listing"
for candidate in config/priv_validator_key.json config/node_key.json keyring-test; do
  if [ -e "$SVOTE_HOME/$candidate" ]; then
    echo "$candidate" >> "$listing"
  else
    log "WARNING: $candidate not present; not included in the archive"
  fi
done

# pallas.* and ea.* are listed by upstream as critical but their location is not
# documented, so look in the home root and one level down.
( cd "$SVOTE_HOME" && find . -maxdepth 2 \( -name 'pallas.*' -o -name 'ea.*' \) -printf '%P\n' 2>/dev/null | sort ) >> "$listing"

if [ ! -s "$listing" ]; then
  fail "nothing to archive"
fi

log "Archiving $(wc -l < "$listing") path(s) from $SVOTE_HOME"
tar -C "$SVOTE_HOME" -czf - -T "$listing" | rage -r "$SVOTE_KEY_BACKUP_AGE_RECIPIENT" -o "$archive"

sha256sum "$archive" | awk '{print $1}' > "$digest_file"
log "Encrypted archive is $(stat -c %s "$archive") bytes, sha256 $(cat "$digest_file")"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"

install -d -m 0700 "$SVOTE_KEY_BACKUP_SPOOL"
install -m 0600 "$archive" "$SVOTE_KEY_BACKUP_SPOOL/keys-$stamp.tar.age"
install -m 0600 "$digest_file" "$SVOTE_KEY_BACKUP_SPOOL/keys-$stamp.tar.age.sha256"

# Prune oldest-first, keeping the newest N archives with their digests. The
# timestamped names sort lexicographically in chronological order because the
# stamp is fixed-width UTC, so `ls` order is date order. A negative slice end
# would select nothing, so guard the count before slicing.
keep="$SVOTE_KEY_BACKUP_KEEP"
mapfile -t archives < <(ls -1 "$SVOTE_KEY_BACKUP_SPOOL"/keys-*.tar.age 2>/dev/null | sort)
if [ "$${#archives[@]}" -gt "$keep" ]; then
  for stale in "$${archives[@]:0:$${#archives[@]}-$keep}"; do
    log "Pruning $(basename "$stale")"
    rm -f "$stale" "$stale.sha256"
  done
fi

touch "$SVOTE_KEY_BACKUP_MARKER"

log "Wrote $SVOTE_KEY_BACKUP_SPOOL/keys-$stamp.tar.age"
log "Collect it off this host -- a backup that never leaves the validator is not a backup."
log "Restore with: rage -d -i <offline-identity-file> keys-$stamp.tar.age | tar -xzf -"
EOF
  chmod 0755 /usr/local/bin/svote-backup-keys

  cat <<EOF > /etc/systemd/system/svote-backup-keys.service
[Unit]
Description=Back up Shielded-Vote validator keys to a local spool, encrypted to an age recipient
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/svote-backup-keys
EOF

  cat <<EOF > /etc/systemd/system/svote-backup-keys.timer
[Unit]
Description=Run Shielded-Vote validator key backups on a schedule

[Timer]
OnCalendar=${key_backup_on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  log "Key backup timer installed but left disabled; 'svote backup-keys' enables it after the first successful run"
}

install_upgrade_check_timer() {
  # A coordinated upgrade has a hard deadline and halts the node if missed, so the
  # readiness check runs on a timer rather than waiting for someone to log in.
  # Output lands in journald, which the Ops Agent ships, so an alert policy can key
  # off it.
  log "Installing upgrade readiness check timer"

  cat <<EOF > /etc/systemd/system/svote-upgrade-check.service
[Unit]
Description=Check readiness for the next Shielded-Vote coordinated upgrade
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$APP_USER
ExecStart=/usr/local/bin/svote upgrade-status
SyslogIdentifier=svote-upgrade-check
EOF

  cat <<EOF > /etc/systemd/system/svote-upgrade-check.timer
[Unit]
Description=Run the Shielded-Vote upgrade readiness check on a schedule

[Timer]
OnCalendar=${upgrade_check_on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload

  # Safe to enable before the join: upgrade-status degrades gracefully when there
  # is no validator yet.
  systemctl enable --now svote-upgrade-check.timer
}

install_operator_cli() {
  log "Installing /usr/local/bin/svote operator CLI"

  cat <<'EOF' > /usr/local/bin/svote
#!/bin/bash
# Operator front end for a Valar Group Shielded-Vote validator.
#
# Deliberately does not run the upstream installer unattended: join.sh begins
# with an unconditional `rm -rf $SVOTE_HOME`, prompts for a moniker, and needs a
# human to relay the approval request. This wrapper presets the environment it
# expects, checks the installer's digest, and takes care of everything that can
# be automated on either side of that one interactive step.
set -euo pipefail

# shellcheck disable=SC1091
. /etc/default/svote

export PATH="$SVOTE_INSTALL_DIR:/usr/local/bin:/usr/bin:/bin"

VALIDATOR_URL="https://$SVOTE_TLS_DOMAIN"
REGISTRATION_FILE="$SVOTE_MOUNT_PATH/REGISTRATION.md"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Most subcommands touch the validator home, which is owned by the app user.
# Re-exec as that user when invoked as root so `sudo svote ...` behaves.
reexec_as_app_user() {
  if [ "$(id -un)" = "$SVOTE_APP_USER" ]; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    exec sudo -iu "$SVOTE_APP_USER" /usr/local/bin/svote "$@"
  fi
  die "run this as $SVOTE_APP_USER or root (try: sudo -iu $SVOTE_APP_USER svote $*)"
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

joined() {
  [ -f "$SVOTE_HOME/config/priv_validator_key.json" ]
}

require_joined() {
  joined || die "no validator on this host yet. Run 'svote join' first."
}

svoted_or_die() {
  command -v svoted >/dev/null 2>&1 || die "svoted is not installed. Run 'svote join' first."
}

validator_addr() {
  svoted keys show validator -a --keyring-backend test --home "$SVOTE_HOME" 2>/dev/null || true
}

validator_valoper() {
  svoted keys show validator --bech val -a --keyring-backend test --home "$SVOTE_HOME" 2>/dev/null || true
}

moniker() {
  { sed -n 's/^moniker[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$SVOTE_HOME/config/config.toml" 2>/dev/null || true; } | head -1
}

# Prompt helper. Two things to get right: a bare `read` returns non-zero at EOF,
# which under `set -e` would abort mid-run when svote is invoked without a
# terminal; and the prompt has to go to stderr, because callers read the answer
# from stdout via command substitution.
ask() {
  local prompt="$1"
  local fallback="$2"
  local reply=""

  printf '%s' "$prompt" >&2
  if ! read -r reply; then
    printf '\n' >&2
    reply="$fallback"
  fi
  printf '%s' "$reply"
}

chain_id() {
  jq -r '.chain_id // empty' "$SVOTE_HOME/config/genesis.json" 2>/dev/null || true
}

is_sslip_domain() {
  case "$SVOTE_TLS_DOMAIN" in
    *.sslip.io) return 0 ;;
    *) return 1 ;;
  esac
}

own_public_ip() {
  # DigitalOcean's metadata service needs no header and no auth. Unlike GCE's,
  # it vends no credentials of any kind -- which is why nothing on this host
  # holds a cloud API token. The public address is the droplet's own; this
  # module deliberately does not attach a reserved IP, whose anchor-address
  # behaviour would make the inbound and outbound addresses differ.
  curl -fsSL --max-time 5 \
    "http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address" \
    2>/dev/null || true
}

resolved_ips() {
  # getent is present on Debian without pulling in dnsutils for dig.
  { getent ahostsv4 "$SVOTE_TLS_DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | sort -u
}

# Return 0 when SVOTE_TLS_DOMAIN resolves to this instance's public address.
# sslip.io names resolve by construction, so they are taken on trust.
dns_points_here() {
  local mine
  local ip

  [ -n "$SVOTE_TLS_DOMAIN" ] || return 1
  is_sslip_domain && return 0

  mine="$(own_public_ip)"
  [ -n "$mine" ] || return 1

  for ip in $(resolved_ips); do
    [ "$ip" = "$mine" ] && return 0
  done
  return 1
}

warn_if_sslip() {
  is_sslip_domain || return 0
  cat >&2 <<SSLIP

  NOTE: this validator's public URL is $VALIDATOR_URL

  An sslip.io name is fine for a smoke test, but do not publish it: it discloses
  the host IP and makes certificate renewal depend on a third-party wildcard DNS
  service. Before adding this validator to the public voting config, set
  vote_validator_tls_domain to a hostname you control, re-apply, re-run the
  startup script, then 'svote register'.
SSLIP
}

# ---- coordinated upgrades -------------------------------------------------
#
# The scheduled plan is read from the local REST API when svoted is up, and from
# the seed otherwise -- an unstaged upgrade is exactly the situation where the
# local node may already be down, so a local-only lookup would go blind when it
# matters most.

rest_bases() {
  printf 'http://127.0.0.1:%s\n' "$SVOTE_HELPER_API_PORT"
  curl -fsSL --max-time 10 "https://voting.valargroup.org/$SVOTE_ENV/dynamic-voting-config.json" 2>/dev/null |
    jq -r '.vote_servers[]?.url // empty' 2>/dev/null || true
}

# Print the current upgrade plan as JSON, or nothing.
upgrade_plan() {
  local base
  local out
  for base in $(rest_bases); do
    out="$(curl -fsSL --max-time 10 "$${base%/}/cosmos/upgrade/v1beta1/current_plan" 2>/dev/null || true)"
    if [ -n "$out" ] && [ "$(echo "$out" | jq -r '.plan // empty' 2>/dev/null)" != "" ]; then
      echo "$out" | jq -c '.plan'
      return 0
    fi
  done
}

current_height() {
  local base
  local out
  for base in $(rest_bases); do
    out="$(curl -fsSL --max-time 10 "$${base%/}/cosmos/base/tendermint/v1beta1/blocks/latest" 2>/dev/null || true)"
    out="$(echo "$out" | jq -r '.block.header.height // empty' 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  done
}

installed_version() {
  "$SVOTE_HOME/cosmovisor/genesis/bin/svoted" version 2>/dev/null | tr -d '[:space:]' || true
}

# Same rule as svote-stage-upgrades: same major and minor, patch not older.
version_satisfies() {
  local inst="$${1#v}"
  local req="$${2#v}"
  local i_ma i_mi i_pa r_ma r_mi r_pa

  [ -n "$req" ] || return 1
  IFS=. read -r i_ma i_mi i_pa <<<"$inst"
  IFS=. read -r r_ma r_mi r_pa <<<"$req"
  [ "$${i_ma:-x}" = "$${r_ma:-y}" ] &&
    [ "$${i_mi:-x}" = "$${r_mi:-y}" ] &&
    [ "$${i_pa:-0}" -ge "$${r_pa:-0}" ] 2>/dev/null
}

autodownload_enabled() {
  as_root systemctl show svoted -p Environment 2>/dev/null |
    tr ' ' '\n' | grep -q '^DAEMON_ALLOW_DOWNLOAD_BINARIES=true$'
}

# Admin API base. Empty means derive it from the chain id, matching
# default_admin_url_for_chain in join.sh.
admin_url() {
  if [ -n "$SVOTE_ADMIN_URL" ]; then
    printf '%s' "$SVOTE_ADMIN_URL"
    return 0
  fi
  case "$(chain_id)" in
    zvote-1) printf '%s' "https://prod.svote.valargroup.org" ;;
    svote-1) printf '%s' "https://stage.svote.valargroup.org" ;;
    *) printf '' ;;
  esac
}

print_approval_message() {
  cat <<MSG

Send this to the Valar Group voting admin to request approval and funding:

  Please approve my Shielded-Vote validator.
  Name: $(moniker)
  Validator address: $(validator_addr)
  Public URL: $VALIDATOR_URL

Once they approve and fund the operator address, the svoted wrapper bonds the
validator on its own. Watch it with 'svote logs' and confirm with 'svote bonded'.
MSG
}

write_registration_file() {
  cat > "$REGISTRATION_FILE" <<REG
# Shielded-Vote validator registration

- Host: $SVOTE_HOSTNAME
- Chain ID: $(chain_id)
- Moniker: $(moniker)
- Operator address: $(validator_addr)
- Operator (valoper): $(validator_valoper)
- Public URL: $VALIDATOR_URL
- Joined at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Approval is a manual, out-of-band step: message the Valar Group voting admin
with the operator address above. After bonding, ask them to add the public URL
to vote_servers in https://github.com/valargroup/token-holder-voting-config
REG

  # Same details into Cloud Logging, so they are retrievable without SSH.
  logger -t svote-registration "host=$SVOTE_HOSTNAME chain_id=$(chain_id) moniker=$(moniker) operator=$(validator_addr) valoper=$(validator_valoper) url=$VALIDATOR_URL"
}

backup_keys() {
  require_joined

  if [ -z "$SVOTE_KEY_BACKUP_AGE_RECIPIENT" ]; then
    die "no age recipient configured. Generate one off-host with 'rage-keygen', set key_backup_age_recipient in Terraform and re-apply. Refusing to back up signing keys unencrypted."
  fi

  echo "Backing up validator keys to $SVOTE_KEY_BACKUP_SPOOL/ ..."
  as_root systemctl start svote-backup-keys.service
  as_root journalctl -u svote-backup-keys.service -n 20 --no-pager

  [ -f "$SVOTE_KEY_BACKUP_MARKER" ] || die "backup did not complete; see the log above"

  if ! as_root systemctl is-enabled --quiet svote-backup-keys.timer 2>/dev/null; then
    echo "Enabling the scheduled key backup timer."
    as_root systemctl enable --now svote-backup-keys.timer
  fi

  echo "Done. Rehearse the restore before you rely on it: 'svote restore-keys'."
}

cmd_join() {
  local force=0
  local installer
  local observed
  local rc

  # The moniker is this validator's public name: it goes into the registration
  # payload and, when the wrapper bonds, the on-chain staking record. Requiring it
  # up front is deliberate -- leaving it to the installer's prompt got a hostname
  # entered as the validator name once already.
  [ -n "$SVOTE_MONIKER" ] ||
    die "no moniker configured. Set vote_validator_moniker in Terraform (e.g. \"ZF\"),
  re-apply, re-run the startup script, then retry. This is the validator's public
  name and ends up on chain, so it is not prompted for."

  if [ "$${1:-}" = "--force" ]; then
    force=1
    shift
  fi

  if joined && [ "$force" -eq 0 ]; then
    die "a validator already exists at $SVOTE_HOME.
  The upstream installer starts by deleting that directory, which would destroy
  this validator's signing key and identity.
  To repair chain state instead, use 'svote reset-snapshot'.
  To deliberately discard this validator and create a new one: 'svote join --force'."
  fi

  if joined && [ "$force" -eq 1 ]; then
    echo "WARNING: --force will delete $SVOTE_HOME and create a brand new validator identity."
    echo "Backing up the existing keys first."
    backup_keys
    [ "$(ask 'Type RESET to continue: ' '')" = "RESET" ] || die "aborted; nothing was changed"
  fi

  # Fail before the installer runs rather than after. Caddy cannot obtain a
  # certificate for a name that does not resolve here, and because we pass
  # SVOTE_ALLOW_NO_PUBLIC_URL=1 the installer would otherwise carry on and
  # register this validator with an empty URL.
  if ! dns_points_here; then
    die "$SVOTE_TLS_DOMAIN does not resolve to this instance ($(own_public_ip)).
  Resolved to: $(resolved_ips | tr '\n' ' ')
  Create the DNS record first, wait for it to propagate, then re-run:
    $SVOTE_TLS_DOMAIN.  A  $(own_public_ip)     (DNS only, not proxied)
  Let's Encrypt has to reach this host over :80/:443 for the name you configured."
  fi
  echo "DNS check: $SVOTE_TLS_DOMAIN resolves to this instance."

  installer="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$installer'" EXIT

  echo "Fetching the installer from $SVOTE_JOIN_SCRIPT_URL ..."
  curl -fsSL -o "$installer" "$SVOTE_JOIN_SCRIPT_URL"
  observed="$(sha256sum "$installer" | awk '{print $1}')"
  echo "Installer sha256: $observed"

  if [ -n "$SVOTE_JOIN_SCRIPT_SHA256" ]; then
    if [ "$observed" != "$SVOTE_JOIN_SCRIPT_SHA256" ]; then
      die "installer digest does not match the pinned join_script_sha256 ($SVOTE_JOIN_SCRIPT_SHA256). Refusing to run it."
    fi
    echo "Digest matches the pinned value."
  else
    echo "NOTE: join_script_sha256 is unset, so the digest above was not verified."
    echo "      Pin it in Terraform to detect the installer changing under you."
  fi

  echo ""
  echo "Handing over to the upstream installer. Nothing to answer: the validator"
  echo "name is preset to '$SVOTE_MONIKER' and TLS to $SVOTE_TLS_DOMAIN."
  echo ""

  # SVOTE_ALLOW_NO_PUBLIC_URL: with an explicit domain the installer aborts on
  # any Caddy/ACME hiccup *before* registering and installing the service. Let it
  # degrade to "joined but no public URL" instead; 'svote addr' still yields
  # something the admin can fund, and Caddy can be fixed afterwards.
  #
  # timeout: the installer ends with an unbounded loop waiting for the node to
  # report catching_up=false. A node that cannot start leaves it spinning
  # forever, which would strand the operator before any of the post-join steps
  # below -- including the key backup prompt. Time it out and carry on instead.
  rc=0
  timeout "$${SVOTE_JOIN_TIMEOUT:-3600}" env \
    SVOTE_HOME="$SVOTE_HOME" \
    SVOTE_ENV="$SVOTE_ENV" \
    SVOTE_MONIKER="$SVOTE_MONIKER" \
    SVOTE_UPGRADE_MODE="$SVOTE_UPGRADE_MODE" \
    SVOTE_TLS_MODE=custom \
    SVOTE_DOMAIN="$SVOTE_TLS_DOMAIN" \
    SVOTE_ALLOW_NO_PUBLIC_URL=1 \
    bash "$installer" || rc=$?

  if [ "$rc" = 124 ]; then
    echo ""
    echo "NOTE: the installer hit the $${SVOTE_JOIN_TIMEOUT:-3600}s timeout, almost"
    echo "      certainly in its wait-for-sync loop. Continuing with the post-join"
    echo "      steps; check 'svote logs' and 'svote status' afterwards."
  elif [ "$rc" != 0 ]; then
    echo ""
    echo "WARNING: the installer exited $rc. Continuing to the post-join steps so"
    echo "         the signing key still gets backed up, but verify the result."
  fi

  joined || die "the installer finished but no validator key was created at $SVOTE_HOME"

  echo ""
  echo "=== Post-join automation ==="
  write_registration_file
  echo "Registration details written to $REGISTRATION_FILE"

  echo ""
  echo "The validator signing key now exists on this host and nowhere else."
  echo "Nothing has backed it up yet."
  answer="$(ask 'Back up validator keys now? [Y/n] ' 'Y')"
  case "$${answer:-Y}" in
    [Nn]*)
      echo "Skipped. Run 'svote backup-keys' before you rely on this validator."
      ;;
    *)
      backup_keys
      ;;
  esac

  print_approval_message
  warn_if_sslip
}

cmd_addr() {
  require_joined
  svoted_or_die
  print_approval_message
  warn_if_sslip
}

# Re-send the signed registration with the current public URL.
#
# join.sh only registers as part of a full join, and a join begins by deleting
# $SVOTE_HOME -- so without this, correcting a published URL would mean either
# destroying the validator identity or hand-rolling sign-arbitrary and curl.
# Nothing here touches keys or chain state, and sign-arbitrary reads the local
# keyring, so this works with svoted stopped.
cmd_register() {
  local force=0
  local base
  local timestamp
  local payload
  local sig_json
  local body
  local result
  local status

  if [ "$${1:-}" = "--force" ]; then
    force=1
  fi

  require_joined
  svoted_or_die

  base="$(admin_url)"
  [ -n "$base" ] || die "no admin API base configured and chain id '$(chain_id)' is not recognised. Set svote_admin_url in Terraform."

  [ -n "$SVOTE_TLS_DOMAIN" ] ||
    die "no public URL configured. Set vote_validator_tls_domain, re-apply, re-run the startup script, then retry."

  if is_sslip_domain && [ "$force" -eq 0 ]; then
    die "refusing to register the sslip.io URL $VALIDATOR_URL.
  This is what gets published in the voting config. Set vote_validator_tls_domain
  to a hostname you control, re-apply, re-run the startup script, then retry.
  Use 'svote register --force' only if you really do intend to publish the
  sslip.io name."
  fi

  if ! dns_points_here; then
    echo "WARNING: $SVOTE_TLS_DOMAIN does not currently resolve to this instance." >&2
    echo "         Registering anyway, but clients will not reach this validator." >&2
  fi

  timestamp="$(date +%s)"

  # Field order matters: the server re-derives this exact string to check the
  # signature, so it has to match join.sh's build_register_payload byte for byte.
  payload="$(jq -nc \
    --arg oa "$(validator_addr)" \
    --arg u "$VALIDATOR_URL" \
    --arg m "$(moniker)" \
    --argjson ts "$timestamp" \
    '{operator_address:$oa,url:$u,moniker:$m,timestamp:$ts}')"

  echo "Registering with $base"
  echo "  operator: $(validator_addr)"
  echo "  moniker:  $(moniker)"
  echo "  url:      $VALIDATOR_URL"

  sig_json="$(svoted sign-arbitrary "$payload" --from validator \
    --keyring-backend test --home "$SVOTE_HOME" 2>/dev/null)" ||
    die "could not sign the registration payload"

  body="$(jq -nc \
    --arg oa "$(validator_addr)" \
    --arg u "$VALIDATOR_URL" \
    --arg m "$(moniker)" \
    --argjson ts "$timestamp" \
    --arg s "$(echo "$sig_json" | jq -r '.signature')" \
    --arg pk "$(echo "$sig_json" | jq -r '.pub_key')" \
    '{operator_address:$oa,url:$u,moniker:$m,timestamp:$ts,signature:$s,pub_key:$pk}')"

  result="$(curl -fsSL -X POST "$${base%/}/api/register-validator" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)" ||
    die "could not reach the registration API at $base"

  status="$(echo "$result" | jq -r '.status // empty' 2>/dev/null || true)"
  case "$status" in
    pending|registered|bonded)
      echo "Registered: $status"
      ;;
    *)
      echo "Unexpected response: $result" >&2
      die "registration was not accepted"
      ;;
  esac

  write_registration_file

  cat <<PR

Next: add this validator to the public voting config with a PR against
https://github.com/valargroup/token-holder-voting-config (prod/dynamic-voting-config.json),
appending to vote_servers:

  $(jq -nc --arg url "$VALIDATOR_URL" --arg label "ZcashFoundation" '{url:$url,label:$label}')

Confirm with the voting admin that the queue shows this URL and any earlier one is gone.
PR
}

# Report readiness for the next coordinated upgrade. Also the timer's ExecStart,
# so the exit code is meaningful: non-zero means a human needs to act.
cmd_upgrade_status() {
  local plan name height required binaries staged_bin staged_ver installed
  local head remaining eta_days verdict=READY rc=0

  # The timer is enabled at provisioning time, before any validator exists.
  if ! joined; then
    echo "No validator on this host yet; nothing to check."
    rm -f "$SVOTE_UPGRADE_MARKER" 2>/dev/null || true
    return 0
  fi

  installed="$(installed_version)"
  echo "Installed:  $${installed:-<unknown>}  ($SVOTE_HOME/cosmovisor/genesis/bin/svoted)"

  if autodownload_enabled; then
    echo "Autodownload: enabled (checksum required)"
  else
    echo "Autodownload: disabled -- pre-staging is the only path"
  fi

  plan="$(upgrade_plan)"
  if [ -z "$plan" ]; then
    echo "Plan:       none scheduled on chain"
    echo ""
    echo "Verdict:    READY (nothing pending)"
    return 0
  fi

  name="$(echo "$plan" | jq -r '.name // empty')"
  height="$(echo "$plan" | jq -r '.height // empty')"
  required="$(echo "$plan" | jq -r '(.info // "") | (fromjson? // {}) | .tag // empty')"
  if [ "$(echo "$plan" | jq -r '(.info // "") | (fromjson? // {}) | (.binaries // empty) | length' 2>/dev/null || true)" -gt 0 ] 2>/dev/null; then
    binaries=yes
  else
    binaries=no
  fi

  echo "Plan:       $name at height $height"
  echo "Requires:   $${required:-<unknown>}   downloadable: $binaries"

  head="$(current_height)"
  if [ -n "$head" ] && [ -n "$height" ]; then
    remaining=$((height - head))
    if [ "$remaining" -gt 0 ]; then
      # ~1.386 s/block per the plan's own averaging window.
      eta_days="$(awk -v b="$remaining" 'BEGIN{printf "%.1f", b*1.386/86400}')"
      echo "Head:       $head  ($remaining blocks to go, ~$eta_days days)"
    else
      echo "Head:       $head  (upgrade height reached)"
    fi
  fi

  staged_bin="$SVOTE_HOME/cosmovisor/upgrades/$name/bin/svoted"
  if [ -x "$staged_bin" ]; then
    staged_ver="$("$staged_bin" version 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$required" ] || [ "$staged_ver" = "$required" ]; then
      echo "Staged:     yes  ($staged_ver)"
    else
      echo "Staged:     yes but version mismatch ($staged_ver, expected $required)"
      verdict="ACTION NEEDED"
      rc=1
    fi
  elif version_satisfies "$installed" "$required"; then
    # svote-stage-upgrades will handle this one at next start.
    echo "Staged:     not yet, but the installed binary satisfies $required"
  elif [ "$binaries" = "yes" ] && autodownload_enabled; then
    echo "Staged:     no -- cosmovisor can download it, but pre-staging is safer"
    verdict="NOT STAGED"
  else
    echo "Staged:     NO, and it cannot be downloaded"
    verdict="ACTION NEEDED"
    rc=1
  fi

  echo ""
  echo "Verdict:    $verdict"
  if [ "$verdict" != "READY" ]; then
    echo "Fix:        svote prestage-upgrade"
  fi

  # Marker drives the login banner, so it does not have to query the chain. Keyed
  # on the verdict, not the exit code: NOT STAGED exits 0 because autodownload will
  # probably carry it, but pre-staging is still the intended path, so it should
  # keep nagging.
  if [ "$verdict" = "READY" ]; then
    rm -f "$SVOTE_UPGRADE_MARKER" 2>/dev/null || true
  else
    touch "$SVOTE_UPGRADE_MARKER" 2>/dev/null || true
  fi

  return "$rc"
}

cmd_tls_status() {
  local mine
  local cert

  echo "Configured domain: $${SVOTE_TLS_DOMAIN:-<none>}"
  [ -n "$SVOTE_TLS_DOMAIN" ] || { echo "No public URL. Set vote_validator_tls_domain."; return 0; }

  echo "Public URL:        $VALIDATOR_URL"
  mine="$(own_public_ip)"
  echo "This instance:     $${mine:-unknown}"
  echo "DNS resolves to:   $(resolved_ips | tr '\n' ' ')"

  if dns_points_here; then
    echo "DNS check:         OK"
  else
    echo "DNS check:         MISMATCH - clients will not reach this host"
  fi

  if cert="$(echo | openssl s_client -servername "$SVOTE_TLS_DOMAIN" \
      -connect "$SVOTE_TLS_DOMAIN:443" 2>/dev/null |
      openssl x509 -noout -subject -issuer -enddate 2>/dev/null)"; then
    printf '%s\n' "$cert" | sed 's/^/Certificate:       /'
  else
    echo "Certificate:       could not complete a TLS handshake"
  fi

  if curl -fsS --max-time 10 "$VALIDATOR_URL/cosmos/base/tendermint/v1beta1/node_info" >/dev/null 2>&1; then
    echo "Helper API:        reachable over public HTTPS"
  else
    echo "Helper API:        NOT reachable (a 502 here means Caddy is fine but svoted is down)"
  fi

  warn_if_sslip
}

cmd_status() {
  require_joined
  svoted_or_die
  svoted status --home "$SVOTE_HOME" | jq '{
    network: .node_info.network,
    moniker: .node_info.moniker,
    height: .sync_info.latest_block_height,
    catching_up: .sync_info.catching_up
  }'
}

cmd_bonded() {
  require_joined
  svoted_or_die
  local valoper
  local result
  valoper="$(validator_valoper)"
  [ -n "$valoper" ] || die "could not derive the operator address"

  # A validator that has not been approved and funded yet simply is not on chain,
  # and svoted exits non-zero for that. That is the expected state right after
  # joining, so report it rather than failing.
  result="$(svoted query staking validator "$valoper" --home "$SVOTE_HOME" --output json 2>/dev/null || true)"

  if [ -z "$result" ]; then
    echo "not on chain yet — waiting on the voting admin to approve and fund $valoper"
    return 0
  fi

  echo "$result" | jq -r '.validator.status // .status // "unknown"'
}

cmd_logs() {
  as_root journalctl -u svoted -f
}

cmd_restore_keys() {
  cat <<RESTORE
Restoring validator keys
========================

Backups spool to $SVOTE_KEY_BACKUP_SPOOL on this host, encrypted to
$SVOTE_KEY_BACKUP_AGE_RECIPIENT. This host cannot decrypt them; the matching age
identity is held off-host by the operator.

  DANGER: the validator signing key must be live on exactly one host at a time.
  Restoring onto a second host while the original still runs will double-sign.
  Destroy or permanently stop the original first.

Nothing uploads these. Unlike the GCS arrangement this replaced, there is no
bucket whose permissions stop a compromised host rewriting its own backup
history -- DigitalOcean Spaces cannot express a create-but-not-delete key. That
guarantee now comes from collecting archives off this host and keeping them
somewhere the validator cannot reach. A spool that has never been collected is
not a backup.

From a workstation that holds the age identity. Every line below is pasteable as
is -- no trailing comments, because zsh does not treat # as a comment
interactively and would pass it to the command as an argument.

1. Fetch the newest backup from the validator:

  SPOOL=$SVOTE_KEY_BACKUP_SPOOL
  NEWEST=\$(ssh root@$SVOTE_HOSTNAME "ls -1 \$SPOOL/keys-*.tar.age | sort | tail -1")
  ARCHIVE=\$(basename "\$NEWEST")
  echo "\$NEWEST"
  scp "root@$SVOTE_HOSTNAME:\$NEWEST" .

2. Verify integrity. The two digests must match:

  ssh root@$SVOTE_HOSTNAME "cat \$NEWEST.sha256"
  sha256sum "\$ARCHIVE"

3. Inspect the contents without extracting:

  rage -d -i /path/to/identity.txt "\$ARCHIVE" | tar -tzf -

4. Extract:

  rage -d -i /path/to/identity.txt "\$ARCHIVE" | tar -xzf -

Then, on the replacement host, with svoted stopped:

  sudo systemctl stop svoted
  sudo -u $SVOTE_APP_USER cp config/priv_validator_key.json $SVOTE_HOME/config/
  sudo -u $SVOTE_APP_USER cp config/node_key.json $SVOTE_HOME/config/
  sudo -u $SVOTE_APP_USER cp -r keyring-test $SVOTE_HOME/
  sudo systemctl start svoted

priv_validator_state.json is deliberately not in the archive. Let svoted
rebuild it, or restore chain state from a data disk snapshot instead.

Do this as a drill at least once, before you need it.
RESTORE
}

cmd_reset_snapshot() {
  require_joined
  echo "Backing up keys before touching chain state."
  backup_keys
  echo "Running the upstream snapshot reset."
  curl -fsSL https://shielded-vote.nyc3.digitaloceanspaces.com/reset-validator-snapshot.sh |
    env SVOTE_HOME="$SVOTE_HOME" bash
}

cmd_prestage_upgrade() {
  # Plan name and tag are separate because they genuinely differ: the chain records
  # an applied upgrade named 'v1' whose binary tag is v1.0.0. With no arguments both
  # are discovered from the scheduled plan, which is the normal case.
  local plan="$${1:-}"
  local tag="$${2:-}"
  local plan_json
  local updater

  require_joined

  if [ -z "$plan" ]; then
    plan_json="$(upgrade_plan)"
    [ -n "$plan_json" ] ||
      die "no upgrade plan scheduled on chain, and no plan name given.
  usage: svote prestage-upgrade [plan-name] [release-tag]"
    plan="$(echo "$plan_json" | jq -r '.name // empty')"
    tag="$(echo "$plan_json" | jq -r '(.info // "") | (fromjson? // {}) | .tag // empty')"
    echo "Discovered scheduled plan '$plan' requiring tag '$tag'."
  fi

  tag="$${tag:-$plan}"
  [ -n "$plan" ] || die "could not determine the upgrade plan name"

  updater="https://shielded-vote.nyc3.digitaloceanspaces.com/scripts/upgrade/$tag/update_chain.sh"

  echo "Pre-staging tag $tag for upgrade plan $plan."
  echo "This does not stop the validator."
  curl -fsSL "$updater" |
    as_root bash -s -- --mode prepare --plan-name "$plan" --tag "$tag"

  echo ""
  echo "=== Verifying ==="
  # --skip-cosmovisor-service is required and correct here. verify-prestage
  # otherwise asserts that the unit's ExecStart *is* the cosmovisor binary, which
  # only holds after `update_chain.sh --mode migrate`. This module keeps the
  # wrapper-based unit that join.sh installs -- cosmovisor still performs the
  # switch, as a child of the wrapper. Do not "fix" this by migrating: migrate
  # rewrites the unit and removes conflicting drop-ins, which would delete
  # 10-hardening.conf and with it the ExecStart interpreter fix.
  curl -fsSL "$updater" |
    as_root bash -s -- --mode verify-prestage --plan-name "$plan" --tag "$tag" \
      --skip-cosmovisor-service

  echo ""
  cmd_upgrade_status || true
}

cmd_remove() {
  require_joined
  echo "Backing up keys before teardown."
  backup_keys
  [ "$(ask 'Type REMOVE to tear down this validator: ' '')" = "REMOVE" ] ||
    die "aborted; nothing was changed"
  curl -fsSL https://shielded-vote.nyc3.digitaloceanspaces.com/remove-validator.sh |
    env SVOTE_HOME="$SVOTE_HOME" SVOTE_INSTALL_DIR="$SVOTE_INSTALL_DIR" bash
}

usage() {
  cat <<USAGE
svote — operate a Valar Group Shielded-Vote validator

  svote join [--force]        Run the upstream installer interactively, then
                              register, snapshot and back up automatically
  svote addr                  Print the approval message for the voting admin
  svote register [--force]    Re-send the signed registration with the current
                              public URL (use after changing the hostname)
  svote tls-status            Domain, DNS, certificate and public reachability
  svote upgrade-status        Readiness for the next coordinated upgrade
  svote status                Sync status
  svote bonded                On-chain bonding status
  svote logs                  Follow svoted logs
  svote backup-keys           Encrypt and upload the key material now
  svote restore-keys          Print the off-host restore procedure
  svote reset-snapshot        Re-sync chain state from a published snapshot
  svote prestage-upgrade TAG  Stage a coordinated upgrade binary
  svote remove                Tear the validator down

Host:      $SVOTE_HOSTNAME
Home:      $SVOTE_HOME
Public URL $VALIDATOR_URL
Backups:   $SVOTE_KEY_BACKUP_SPOOL/ (local spool -- collect them off-host)
USAGE
}

subcommand="$${1:-help}"

# Subcommands that read or write the validator home run as the app user. Re-exec
# with the original argv intact before consuming it below.
case "$subcommand" in
  join|addr|register|tls-status|upgrade-status|status|bonded|backup-keys|reset-snapshot|prestage-upgrade|remove)
    reexec_as_app_user "$@"
    ;;
esac

if [ $# -gt 0 ]; then
  shift
fi

case "$subcommand" in
  join)              cmd_join "$@" ;;
  addr)              cmd_addr ;;
  register)          cmd_register "$@" ;;
  tls-status)        cmd_tls_status ;;
  upgrade-status)    cmd_upgrade_status ;;
  status)            cmd_status ;;
  bonded)            cmd_bonded ;;
  backup-keys)       backup_keys ;;
  reset-snapshot)    cmd_reset_snapshot ;;
  prestage-upgrade)  cmd_prestage_upgrade "$@" ;;
  remove)            cmd_remove ;;
  logs)              cmd_logs ;;
  restore-keys)      cmd_restore_keys ;;
  help|-h|--help)    usage ;;
  *)                 usage; exit 1 ;;
esac
EOF
  chmod 0755 /usr/local/bin/svote
}

install_login_banner() {
  log "Installing login status banner"

  # POSIX sh: /etc/profile.d is sourced by dash as well as bash.
  cat <<'EOF' > /etc/profile.d/svote-status.sh
# Shielded-Vote validator status, shown on interactive login.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ -r /etc/default/svote ] || return 0
# shellcheck disable=SC1091
. /etc/default/svote

printf '\n=== Shielded-Vote validator (%s) ===\n' "$SVOTE_HOSTNAME"

if [ ! -f "$SVOTE_HOME/config/priv_validator_key.json" ]; then
  printf 'Status:  not joined yet\n'
  printf 'Next:    sudo -iu %s svote join\n\n' "$SVOTE_APP_USER"
  return 0 2>/dev/null || exit 0
fi

printf 'Status:  joined   URL: https://%s\n' "$SVOTE_TLS_DOMAIN"

case "$SVOTE_TLS_DOMAIN" in
  *.sslip.io)
    printf '\n  NOTE: this is an sslip.io URL. Fine for testing, but do not publish it.\n'
    printf '        Set vote_validator_tls_domain, re-apply, then: svote register\n'
    ;;
esac

if [ ! -f "$SVOTE_KEY_BACKUP_MARKER" ]; then
  printf '\n  WARNING: the validator signing key has never been backed up.\n'
  printf '           It exists only on this host. Run: svote backup-keys\n'
elif ! systemctl is-enabled --quiet svote-backup-keys.timer 2>/dev/null; then
  printf '\n  WARNING: scheduled key backups are not enabled. Run: svote backup-keys\n'
else
  printf 'Backups: %s\n' "$(systemctl show -p ActiveState --value svote-backup-keys.timer 2>/dev/null)"
fi

# Pending coordinated upgrade. Reads the marker the timer leaves rather than
# querying the chain, so login stays fast.
if [ -n "$${SVOTE_UPGRADE_MARKER:-}" ] && [ -f "$SVOTE_UPGRADE_MARKER" ]; then
  printf '\n  WARNING: a coordinated upgrade is scheduled and this node is not ready.\n'
  printf '           The validator will halt at the upgrade height. Run: svote upgrade-status\n'
fi

printf 'Help:    svote help\n\n'
EOF
  chmod 0644 /etc/profile.d/svote-status.sh
}

print_next_steps() {
  local domain
  local ip

  domain="$(effective_tls_domain)"
  ip="$(host_public_ip)"

  log "============================================================"
  log "${module_role} host initialization complete"
  log ""
  log "This host is prepared but has NO validator yet. Joining is deliberately"
  log "a manual, interactive step: the upstream installer prompts for a name and"
  log "begins by deleting any existing validator home."
  log ""
  log "NEXT STEPS:"
  log "  1. SSH in:        ssh root@$${ip:-<droplet-ip>}"
  log "  2. Become svote:  sudo -iu $APP_USER"
  log "  3. Join:          svote join"
  log "  4. Back up keys when prompted (or later: svote backup-keys)"
  log "  5. Send the approval message printed at the end to the Valar Group admin"
  log ""
  log "Public URL once Caddy has a certificate: https://$domain"
  log "Key backups spool to $SVOTE_MOUNT_PATH/keybackup and are NOT uploaded."
  log "Collect them off this host; see the module README."

  case "$domain" in
    *.sslip.io)
      log ""
      log "NOTE: no tls_domain was set, so the public URL is derived from this"
      log "      droplet's IP via sslip.io. That is fine for a smoke test, but it"
      log "      is the URL that gets published in the voting config, so set"
      log "      vote_validator_tls_domain to a hostname you control before"
      log "      registering. DNS must point at this droplet, DNS-only"
      log "      (not proxied), before 'svote join' will proceed."
      ;;
    *)
      log ""
      log "DNS must already point $domain at this droplet's public address"
      log "($${ip:-unknown}), DNS-only (not proxied), or 'svote join' will refuse"
      log "to run: Let's Encrypt has to reach :80/:443 for that name."
      ;;
  esac

  if [ -z "${key_backup_age_recipient}" ]; then
    log ""
    log "WARNING: key_backup_age_recipient is not set, so key backup will refuse"
    log "         to run. Generate a recipient off-host with 'rage-keygen', set"
    log "         key_backup_age_recipient and re-apply BEFORE joining."
  fi

  if [ "${restored_from_snapshot}" = "true" ]; then
    log ""
    log "NOTE: the data disk was restored from a snapshot, so a validator may"
    log "      already be present. 'svote join' will refuse to overwrite it."
    log "      Confirm with 'svote status'. Never run a restored signing key"
    log "      alongside the host it came from: that double-signs."
  fi

  log "============================================================"
}

ensure_base_provisioning() {
  if [ -f "$BASE_MARKER_PATH" ]; then
    return
  fi

  log "Running one-time base provisioning"
  mkdir -p "$BASE_STATE_DIR"
  ensure_user
  install_base_packages
  install_tmux_config
  install_global_bash_aliases
  ensure_rage
  touch "$BASE_MARKER_PATH"
}

main() {
  log "Starting ${module_role} initialization for ${hostname}"

  # Everything below is idempotent and re-runs on every boot, so updating this
  # script and rebooting refreshes the operator tooling. Nothing here touches
  # $SVOTE_HOME, which is why that is safe.
  ensure_base_provisioning
  ensure_data_disk
  ensure_admin_user
  harden_sshd
  pin_unattended_upgrades
  configure_sudoers
  write_svote_env_file
  install_upgrade_staging
  write_caddyfile
  stage_svoted_hardening_dropin
  stage_cosmovisor_skip_backup_dropin
  install_key_backup
  install_operator_cli
  install_upgrade_check_timer
  install_login_banner
  print_next_steps

  log "${module_role} initialization complete"
}

main "$@"
