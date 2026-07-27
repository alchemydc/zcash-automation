#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/z3-startup.log"
exec > >(tee -a "$LOG_FILE" | logger -t z3-startup) 2>&1

export DEBIAN_FRONTEND=noninteractive
export HOME="$${HOME:-/root}"
export PATH="/usr/local/bin:/usr/bin:/bin:/root/.cargo/bin:$${PATH}"

APP_DIR="/opt/z3"
APP_USER="z3"
DATA_MOUNT_PATH="${z3_mount_path}"
DATA_DISK_PATH="$(readlink -f /dev/disk/by-id/google-${data_disk_name})"
DOCKER_CONFIG_DIR="/etc/apt/keyrings"
INSTALL_RUST_TOOLCHAIN="${install_rust_toolchain}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Normalize the requested network to the canonical token upstream z3 uses
# (mainnet|testnet|regtest) and derive the matching Zebra health port.
case "${z3_network}" in
    main|mainnet) NETWORK="mainnet"; READINESS_PORT="8080" ;;
    test|testnet) NETWORK="testnet"; READINESS_PORT="18080" ;;
    regtest)      NETWORK="regtest"; READINESS_PORT="28080" ;;
    *) log "Unsupported z3 network: ${z3_network}"; exit 1 ;;
esac

# Every compose invocation selects the network via its committed env file and
# layers our gitignored .env (host overrides) on top; the later file wins.
COMPOSE_ENV_FILES="--env-file .env.$NETWORK --env-file .env"

ensure_user() {
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$APP_USER"
    fi

    usermod -aG docker "$APP_USER"
}

install_base_packages() {
    log "Installing base packages"
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssl \
        tmux \
        unzip \
        htop \
        ripgrep
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
set -g default-command "$${SHELL}"

# Set base index to 1 so windows start at 1
set -g base-index 1

# 3. Navigation Bindings
bind C-a last-window
bind space next-window
bind BSpace previous-window

# --- Your F-Key Mappings (Direct press, no prefix) ---

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

# Performance Improvements
# By default, tmux waits 500ms after receiving an escape character to see if it's part of a function key sequence. This often adds a barely perceptible but annoying delay to all input, including rapid scroll events.
# Set this to zero (or near zero) to make the terminal feel snappy.
set -s escape-time 0

# --- Optional: Improved Status Bar ---
# This helps you see which window index you are on so the F-keys make sense
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
        log "Global bash alias ll already configured"
        return
    fi

    log "Installing global bash alias ll"
    printf '\n# Added by z3 startup\n%s\n' "$alias_line" >> /etc/bash.bashrc
}

install_rust_toolchain() {
    local app_home

    if [ "$INSTALL_RUST_TOOLCHAIN" != "true" ]; then
        log "Skipping Rust toolchain installation"
        return
    fi

    log "Installing Rust toolchain for $APP_USER"
    apt-get install -y \
        build-essential \
        clang \
        pkg-config \
        libssl-dev

    app_home="$(getent passwd "$APP_USER" | cut -d: -f6)"

    if [ -z "$app_home" ]; then
        log "Could not determine home directory for $APP_USER"
        exit 1
    fi

    if ! su - "$APP_USER" -c 'command -v rustup >/dev/null 2>&1'; then
        su - "$APP_USER" -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'
    fi

    su - "$APP_USER" -c 'source "$HOME/.cargo/env" && rustup toolchain install stable && rustup default stable && rustup component add clippy rustfmt'

    if ! grep -Fq '. "$HOME/.cargo/env"' "$app_home/.bashrc"; then
        printf '\n# Added by z3 startup\n. "$HOME/.cargo/env"\n' >> "$app_home/.bashrc"
        chown "$APP_USER:$APP_USER" "$app_home/.bashrc"
    fi
}

install_ops_agent() {
    if dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
        log "Google Ops Agent already installed"
        return
    fi

    log "Installing Google Ops Agent"
    curl -sS -o /tmp/add-google-cloud-ops-agent-repo.sh https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install
}

configure_docker_daemon() {
    local docker_config_dir="/etc/docker"
    local daemon_config_file="$docker_config_dir/daemon.json"

    log "Configuring Docker daemon logging driver"
    install -m 0755 -d "$docker_config_dir"
    cat <<'EOF' > "$daemon_config_file"
{
  "log-driver": "journald"
}
EOF

    if systemctl is-active --quiet docker.service; then
        log "Restarting Docker to apply daemon configuration"
        systemctl restart docker.service
    fi
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker already installed"
        return
    fi

    log "Installing Docker Engine"
    install -m 0755 -d "$DOCKER_CONFIG_DIR"
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_CONFIG_DIR/docker.asc"
    chmod a+r "$DOCKER_CONFIG_DIR/docker.asc"

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=$${DOCKER_CONFIG_DIR}/docker.asc] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$${VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update
    apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin

    systemctl enable docker.service
    systemctl enable containerd.service
    systemctl start docker.service
}

ensure_data_disk() {
    local disk_uuid
    local current_disk_format

    log "Preparing persistent data disk ${data_disk_name}"
    current_disk_format="$(lsblk -i -n -o fstype "$DATA_DISK_PATH")"

    if [ "$current_disk_format" != "ext4" ]; then
        log "Formatting $DATA_DISK_PATH as ext4"
        mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK_PATH"
    fi

    mkdir -p "$DATA_MOUNT_PATH"
    disk_uuid="$(blkid -s UUID -o value "$DATA_DISK_PATH")"

    if ! grep -q " $${DATA_MOUNT_PATH} " /etc/fstab; then
        echo "UUID=$${disk_uuid} $${DATA_MOUNT_PATH} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
    fi

    if ! mountpoint -q "$DATA_MOUNT_PATH"; then
        mount "$DATA_MOUNT_PATH"
    fi

    chown 10001:10001 "$DATA_MOUNT_PATH"
    chmod 700 "$DATA_MOUNT_PATH"
}

ensure_rage() {
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
    apt-get install -y "$rage_package_path"
    rm -f "$rage_package_path"
}

checkout_repo() {
    log "Cloning or updating z3 repository"
    mkdir -p /opt

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone "${z3_repo_url}" "$APP_DIR"
    fi

    cd "$APP_DIR"
    git remote set-url origin "${z3_repo_url}"
    git fetch --tags --prune origin

    if git ls-remote --exit-code --heads origin "${z3_repo_ref}" >/dev/null 2>&1; then
        git checkout -B "${z3_repo_ref}" "origin/${z3_repo_ref}"
    else
        git checkout "${z3_repo_ref}"
    fi

    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
}

ensure_env_var() {
    local key="$1"
    local value="$2"
    local env_file="$APP_DIR/.env"
    local temp_file

    temp_file="$(mktemp)"
    if [ -f "$env_file" ]; then
        grep -v "^$${key}=" "$env_file" > "$temp_file" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$temp_file"
    mv "$temp_file" "$env_file"

    # Preserve app-user access because mv recreates .env as root-owned.
    chown "$APP_USER:$APP_USER" "$env_file"
    chmod u+rw "$env_file"
}

configure_repo() {
    log "Configuring z3 repository for network $NETWORK"
    cd "$APP_DIR"

    # Materialize per-network config (zaino.toml, zallet.toml, optional
    # zebra.toml for regtest) and the Zallet identity using upstream's
    # idempotent setup script. Run as the app user so the files it creates are
    # owned by the account the containers and helper scripts run as.
    su - "$APP_USER" -c "cd '$APP_DIR' && ./scripts/setup-network.sh '$NETWORK'"

    # Redirect Zebra chain state onto the persistent data disk. This override
    # must ride the --env-file chain (compose interpolates the volumes block
    # only from --env-file files), so we keep it in the gitignored .env that we
    # layer last on every invocation.
    ensure_env_var "Z3_CHAIN_DATA_PATH" "$DATA_MOUNT_PATH"
}

pull_images() {
    log "Pulling pinned z3 images for network $NETWORK"
    cd "$APP_DIR"
    # Default compose has no build context (source builds are an opt-in overlay),
    # so there is no local-build fallback; just surface a clear warning on failure.
    if ! docker compose $COMPOSE_ENV_FILES pull; then
        log "WARNING: 'docker compose pull' failed; check image pins and network access"
    fi
}

install_runtime_helpers() {
    log "Installing runtime helper scripts"

    cat <<EOF > /usr/local/bin/z3-check-zebra-readiness
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec ./scripts/check-zebra-readiness.sh $READINESS_PORT
EOF
    chmod 0755 /usr/local/bin/z3-check-zebra-readiness

    # Zebra-only start. Explicit service name keeps default-on zaino/zallet out.
    cat <<EOF > /usr/local/bin/z3-start-zebra
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec docker compose $COMPOSE_ENV_FILES up -d zebra
EOF
    chmod 0755 /usr/local/bin/z3-start-zebra

    # Monitoring-only start. Explicit service list (not just --profile monitoring)
    # so that any depends_on inside the monitoring profile cannot pull in
    # default-on zaino/zallet.
    cat <<EOF > /usr/local/bin/z3-start-monitoring
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec docker compose $COMPOSE_ENV_FILES --profile monitoring up -d --no-deps jaeger prometheus grafana alertmanager
EOF
    chmod 0755 /usr/local/bin/z3-start-monitoring

    cat <<EOF > /usr/local/bin/z3-start-full-stack
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec docker compose $COMPOSE_ENV_FILES up -d
EOF
    chmod 0755 /usr/local/bin/z3-start-full-stack

}

fix_restored_disk_permissions() {
    if [ "${restored_from_snapshot}" != "true" ]; then
        log "No snapshot restore in effect; skipping zebra permission fix"
        return
    fi

    if [ ! -x "$APP_DIR/scripts/fix-permissions.sh" ]; then
        log "WARNING: $APP_DIR/scripts/fix-permissions.sh not found or not executable; skipping fix-permissions for restored disk"
        return
    fi

    log "Fixing permissions on restored Zebra state disk at $DATA_MOUNT_PATH"
    ( cd "$APP_DIR" && ./scripts/fix-permissions.sh zebra "$DATA_MOUNT_PATH" )
}

install_baseline_services() {
    if [ "$NETWORK" = "regtest" ]; then
        log "Regtest: skipping z3-zebra.service and z3-monitoring.service (regtest requires interactive init via scripts/regtest-init.sh)"
        return
    fi

    log "Installing z3-zebra.service (zebra only)"
    cat <<EOF > /etc/systemd/system/z3-zebra.service
[Unit]
Description=z3 Zebra service (chain sync only; no zaino/zallet)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
RequiresMountsFor=${z3_mount_path}

[Service]
Type=oneshot
RemainAfterExit=yes
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment=HOME=/home/$APP_USER
ExecStart=/usr/local/bin/z3-start-zebra
ExecStop=/usr/bin/docker compose $COMPOSE_ENV_FILES stop zebra

[Install]
WantedBy=multi-user.target
EOF

    log "Installing z3-monitoring.service (jaeger/prometheus/grafana/alertmanager)"
    cat <<EOF > /etc/systemd/system/z3-monitoring.service
[Unit]
Description=z3 monitoring services (jaeger, prometheus, grafana, alertmanager)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment=HOME=/home/$APP_USER
ExecStart=/usr/local/bin/z3-start-monitoring
ExecStop=/usr/bin/docker compose $COMPOSE_ENV_FILES --profile monitoring stop jaeger prometheus grafana alertmanager

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable z3-zebra.service z3-monitoring.service

    if ! systemctl start z3-zebra.service; then
        log "WARNING: z3-zebra.service failed to start; check 'systemctl status z3-zebra.service'"
    fi
    if ! systemctl start z3-monitoring.service; then
        log "WARNING: z3-monitoring.service failed to start; check 'systemctl status z3-monitoring.service'"
    fi
}

print_next_steps() {
    log "============================================================"
    log "z3 host initialization complete (network: $NETWORK)"
    log ""

    if [ "$NETWORK" = "regtest" ]; then
        log "NEXT STEPS:"
        log "  1. SSH into the instance:  gcloud compute ssh <hostname> --tunnel-through-iap"
        log "  2. Switch to the app user: sudo -iu z3"
        log "  3. Run first-time setup:   cd /opt/z3 && ./scripts/regtest-init.sh"
        log "     (generates wallet password hash, mines block 1, inits wallet)"
        log "  4. Start the full stack:   cd /opt/z3 && docker compose $COMPOSE_ENV_FILES up -d"

    else
        log "BASELINE SERVICES STARTED AUTOMATICALLY:"
        log "  - z3-zebra.service       (Zebra chain sync)"
        log "  - z3-monitoring.service  (Jaeger, Prometheus, Grafana, Alertmanager)"
        log "  Zaino and Zallet are NOT started by default."
        log ""
        log "NEXT STEPS:"
        log "  1. SSH into the instance:  gcloud compute ssh <hostname> --tunnel-through-iap"
        log "  2. Switch to the app user: sudo -iu z3"
        log "  3. Monitor Zebra sync:     /usr/local/bin/z3-check-zebra-readiness"
        log "                             (or:  curl http://localhost:$READINESS_PORT/ready)"
        log "  4. When Zebra is synced, start the rest of the stack:"
        log "       cd /opt/z3 && docker compose $COMPOSE_ENV_FILES up -d"
        log "       (this brings up Zaino and Zallet alongside the running Zebra+monitoring)"
        log ""
        if [ "${restored_from_snapshot}" = "true" ]; then
            log "NOTE: This disk was restored from a Zebra state snapshot. Sync should"
            log "      complete in minutes rather than hours."
        else
            log "NOTE: No snapshot was available; Zebra is syncing from genesis."
            log "      This may take several hours on $NETWORK."
        fi
    fi

    log "============================================================"
}

log "Starting z3 host initialization for project ${gcloud_project}"
install_base_packages
install_tmux_config
install_global_bash_aliases
install_ops_agent
install_docker
configure_docker_daemon
ensure_user
install_rust_toolchain
ensure_data_disk
ensure_rage
checkout_repo
configure_repo
fix_restored_disk_permissions
pull_images
install_runtime_helpers
install_baseline_services
print_next_steps
