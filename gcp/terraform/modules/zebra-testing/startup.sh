#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/${module_role}-startup.log"
exec > >(tee -a "$LOG_FILE" | logger -t "${module_role}-startup") 2>&1

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

APP_USER="zebra"
APP_DIR="/opt/zebra"
APP_HOME="/home/$APP_USER"
ZEBRAD_BIN="/usr/local/bin/zebrad"
BASE_STATE_DIR="/var/lib/${module_role}"
BASE_MARKER_PATH="$BASE_STATE_DIR/base-provisioned"
RELEASE_MARKER_PATH="$BASE_STATE_DIR/zebrad-release"
TOOLCHAIN_MARKER_PATH="$BASE_STATE_DIR/build-toolchain-provisioned"
DATA_DISK_PATH="$(readlink -f /dev/disk/by-id/google-${data_disk_name})"
STATE_MOUNT_PATH="${zebra_state_mount_path}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

ensure_user() {
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$APP_USER"
    fi
}

install_base_packages() {
    log "Installing base packages"
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        htop \
        jq \
        nftables \
        tmux
}

install_ops_agent() {
    local ops_agent_installer

    if dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
        log "Google Ops Agent already installed"
        return
    fi

    log "Installing Google Ops Agent"
    ops_agent_installer="/tmp/add-google-cloud-ops-agent-repo.sh"
    curl -fsSL -o "$ops_agent_installer" https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash "$ops_agent_installer" --also-install
    rm -f "$ops_agent_installer"
}

install_tmux_config() {
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

ensure_build_toolchain() {
    local app_home

    if [ -f "$TOOLCHAIN_MARKER_PATH" ]; then
        return
    fi

    log "Installing build packages and Rust toolchain for $APP_USER"

    apt-get update
    apt-get install -y \
        build-essential \
        clang \
        git \
        libclang-dev \
        libssl-dev \
        llvm \
        pkg-config

    app_home="$(getent passwd "$APP_USER" | cut -d: -f6)"

    if [ -z "$app_home" ]; then
        log "Could not determine home directory for $APP_USER"
        exit 1
    fi

    if ! su - "$APP_USER" -c 'command -v rustup >/dev/null 2>&1'; then
        su - "$APP_USER" -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'
    fi

    su - "$APP_USER" -c 'source "$HOME/.cargo/env" && rustup toolchain install stable && rustup default stable && rustup component add rustfmt clippy'

    if ! grep -Fq '. "$HOME/.cargo/env"' "$app_home/.bashrc"; then
        printf '\n# Added by %s startup\n. "$HOME/.cargo/env"\n' "${module_role}" >> "$app_home/.bashrc"
        chown "$APP_USER:$APP_USER" "$app_home/.bashrc"
    fi

    mkdir -p "$BASE_STATE_DIR"
    touch "$TOOLCHAIN_MARKER_PATH"
}

ensure_data_disk() {
    local current_disk_format
    local disk_uuid

    log "Preparing persistent state disk ${data_disk_name}"
    current_disk_format="$(lsblk -i -n -o fstype "$DATA_DISK_PATH")"

    if [ "$current_disk_format" != "ext4" ]; then
        log "Formatting $DATA_DISK_PATH as ext4"
        mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK_PATH"
    fi

    mkdir -p "$STATE_MOUNT_PATH"
    disk_uuid="$(blkid -s UUID -o value "$DATA_DISK_PATH")"

    if ! grep -q " $STATE_MOUNT_PATH " /etc/fstab; then
        echo "UUID=$disk_uuid $STATE_MOUNT_PATH ext4 discard,defaults,nofail 0 2" >> /etc/fstab
    fi

    if ! mountpoint -q "$STATE_MOUNT_PATH"; then
        mount "$STATE_MOUNT_PATH"
    fi

    chown -R "$APP_USER:$APP_USER" "$STATE_MOUNT_PATH"
    chmod 700 "$STATE_MOUNT_PATH"
}

configure_firewall() {
    log "Configuring host nftables firewall"
    cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0;
        iif lo accept
        ct state established,related accept
        tcp dport { 22, ${zebra_listen_port} } ct state new accept
        counter drop
    }
}
EOF

    systemctl enable nftables.service
    systemctl restart nftables.service
}

write_zebra_env_file() {
    log "Writing zebrad environment file"

    cat <<EOF > /etc/default/zebrad
ZEBRA_NETWORK__NETWORK=${zebra_network}
ZEBRA_NETWORK__LISTEN_ADDR=${zebra_listen_addr}
ZEBRA_STATE__CACHE_DIR=${zebra_state_mount_path}
ZEBRA_STATE__EPHEMERAL=false
ZEBRA_TRACING__USE_JOURNALD=true
ZEBRA_TRACING__USE_COLOR=false
ZEBRA_TRACING__FORCE_USE_COLOR=false
EOF

    if [ -n "${metrics_endpoint_addr}" ]; then
        echo "ZEBRA_METRICS__ENDPOINT_ADDR=${metrics_endpoint_addr}" >> /etc/default/zebrad
    fi

    if [ -n "${health_listen_addr}" ]; then
        echo "ZEBRA_HEALTH__LISTEN_ADDR=${health_listen_addr}" >> /etc/default/zebrad
    fi

    chmod 0644 /etc/default/zebrad
}

write_zebrad_service() {
    log "Writing zebrad systemd service"

    cat <<EOF > /etc/systemd/system/zebrad.service
[Unit]
Description=Zebra node (${module_role})
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${zebra_state_mount_path}

[Service]
User=$APP_USER
Group=$APP_USER
Environment=HOME=$APP_HOME
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=-/etc/default/zebrad
WorkingDirectory=$APP_HOME
ExecStart=$ZEBRAD_BIN start
Restart=on-failure
RestartSec=30
LimitNOFILE=1048576
SyslogIdentifier=zebrad

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable zebrad.service
}

write_snapshot_units() {
    if [ "${enable_snapshot_timer}" != "true" ]; then
        systemctl disable --now zebra-snapshot.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/zebra-snapshot.service /etc/systemd/system/zebra-snapshot.timer /usr/local/bin/zebra-create-snapshot
        systemctl daemon-reload
        return
    fi

    cat <<'EOF' > /usr/local/bin/zebra-create-snapshot
#!/bin/bash
set -euo pipefail

PROJECT="${gcloud_project}"
ZONE="${gcloud_zone}"
DISK_NAME="${data_disk_name}"
SNAPSHOT_NAME="${data_disk_name}-snapshot-latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

metadata_get() {
    curl -fsSL -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"
}

access_token() {
    metadata_get "instance/service-accounts/default/token" | jq -r '.access_token'
}

snapshot_url="https://compute.googleapis.com/compute/v1/projects/$PROJECT/global/snapshots/$SNAPSHOT_NAME"
token="$(access_token)"

if curl -fsS -H "Authorization: Bearer $token" "$snapshot_url" >/dev/null 2>&1; then
    log "Deleting existing snapshot $SNAPSHOT_NAME"
    curl -fsS -X DELETE -H "Authorization: Bearer $token" "$snapshot_url" >/dev/null
    for _ in $(seq 1 60); do
        if ! curl -fsS -H "Authorization: Bearer $token" "$snapshot_url" >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done
fi

log "Stopping zebrad before snapshot"
systemctl stop zebrad.service
sleep 5

log "Creating snapshot $SNAPSHOT_NAME"
curl -fsS \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/disks/$DISK_NAME/createSnapshot" \
    -d "{\"name\":\"$SNAPSHOT_NAME\"}" >/dev/null

log "Starting zebrad after snapshot request"
systemctl start zebrad.service
EOF
    chmod 0755 /usr/local/bin/zebra-create-snapshot

    cat <<EOF > /etc/systemd/system/zebra-snapshot.service
[Unit]
Description=Create a snapshot of the Zebra state disk
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zebra-create-snapshot
EOF

    cat <<EOF > /etc/systemd/system/zebra-snapshot.timer
[Unit]
Description=Run Zebra state disk snapshots on a schedule

[Timer]
OnCalendar=${snapshot_on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable zebra-snapshot.timer
    systemctl restart zebra-snapshot.timer
}

checkout_repo() {
    local current_rev
    local old_rev=""

    log "Cloning or updating Zebra repository"
    mkdir -p /opt

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone "${zebra_repo_url}" "$APP_DIR"
    fi

    cd "$APP_DIR"
    old_rev="$(git rev-parse HEAD 2>/dev/null || true)"
    git remote set-url origin "${zebra_repo_url}"
    git fetch --tags --prune origin

    if [ -n "${zebra_git_fetch_ref}" ]; then
        git fetch --prune origin "${zebra_git_fetch_ref}"
        git checkout --detach FETCH_HEAD
    elif git ls-remote --exit-code --heads origin "${zebra_repo_ref}" >/dev/null 2>&1; then
        git checkout -B "${zebra_repo_ref}" "origin/${zebra_repo_ref}"
    elif git show-ref --verify --quiet "refs/tags/${zebra_repo_ref}"; then
        git checkout "tags/${zebra_repo_ref}"
    else
        git checkout "${zebra_repo_ref}"
    fi

    git submodule update --init --recursive
    current_rev="$(git rev-parse HEAD)"
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"

    if [ ! -x "$APP_DIR/target/release/zebrad" ] || [ "$old_rev" != "$current_rev" ] || [ "$(cat "$RELEASE_MARKER_PATH" 2>/dev/null)" != "source:$current_rev" ]; then
        log "Zebra source changed or binary missing; rebuilding"
        su - "$APP_USER" -c 'source "$HOME/.cargo/env" && cd /opt/zebra && cargo build --release --locked --bin zebrad --features prometheus'
    else
        log "Zebra source unchanged; skipping rebuild"
    fi

    install -m 0755 -T "$APP_DIR/target/release/zebrad" "$ZEBRAD_BIN"
    mkdir -p "$BASE_STATE_DIR"
    echo "source:$current_rev" > "$RELEASE_MARKER_PATH"
}

install_zebrad_release() {
    local requested_tag="${zebra_release_tag}"
    local resolved_tag installed_tag machine version asset base_url tmp_dir

    if [ "$requested_tag" = "latest" ]; then
        resolved_tag="$(curl -fsSL https://api.github.com/repos/ZcashFoundation/zebra/releases/latest | jq -r '.tag_name' || true)"
        if [ -z "$resolved_tag" ] || [ "$resolved_tag" = "null" ]; then
            if [ -x "$ZEBRAD_BIN" ]; then
                log "Could not resolve latest Zebra release; keeping installed $(cat "$RELEASE_MARKER_PATH" 2>/dev/null || echo unknown)"
                return 0
            fi
            log "Could not resolve latest Zebra release and no zebrad installed"
            exit 1
        fi
    else
        resolved_tag="$requested_tag"
    fi

    installed_tag="$(cat "$RELEASE_MARKER_PATH" 2>/dev/null || true)"
    if [ "$installed_tag" = "$resolved_tag" ] && [ -x "$ZEBRAD_BIN" ]; then
        log "zebrad $resolved_tag already installed; skipping download"
        return 0
    fi

    machine="$(uname -m)"
    case "$machine" in
        x86_64|aarch64) ;;
        *) log "Unsupported architecture $machine"; exit 1 ;;
    esac

    version="$${resolved_tag#v}"
    asset="zebrad-$version-$machine-unknown-linux-gnu.tar.gz"
    base_url="https://github.com/ZcashFoundation/zebra/releases/download/$resolved_tag"

    log "Installing zebrad $resolved_tag ($asset)"
    tmp_dir="$(mktemp -d)"
    curl -fsSL -o "$tmp_dir/$asset" "$base_url/$asset"
    curl -fsSL -o "$tmp_dir/$asset.sha256" "$base_url/$asset.sha256"
    (cd "$tmp_dir" && sha256sum -c "$asset.sha256")
    tar -xzf "$tmp_dir/$asset" -C "$tmp_dir" zebrad
    install -m 0755 -T "$tmp_dir/zebrad" "$ZEBRAD_BIN"
    rm -rf "$tmp_dir"

    log "Installed: $("$ZEBRAD_BIN" --version)"
    mkdir -p "$BASE_STATE_DIR"
    echo "$resolved_tag" > "$RELEASE_MARKER_PATH"
}

ensure_base_provisioning() {
    if [ -f "$BASE_MARKER_PATH" ]; then
        return
    fi

    log "Running one-time base provisioning"
    mkdir -p "$BASE_STATE_DIR"
    ensure_user
    install_base_packages
    install_ops_agent
    install_tmux_config
    install_global_bash_aliases
    touch "$BASE_MARKER_PATH"
}

main() {
    log "Starting ${module_role} initialization for ${hostname}"
    ensure_base_provisioning
    ensure_data_disk
    configure_firewall
    write_zebra_env_file
    write_zebrad_service
    write_snapshot_units

    if [ -n "${zebra_repo_ref}" ] || [ -n "${zebra_git_fetch_ref}" ]; then
        ensure_build_toolchain
        checkout_repo
    else
        install_zebrad_release
    fi

    systemctl restart zebrad.service
    log "${module_role} initialization complete"
}

main "$@"