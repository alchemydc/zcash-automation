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

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

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
        htop
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

install_ops_agent() {
    if dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
        log "Google Ops Agent already installed"
        return
    fi

    log "Installing Google Ops Agent"
    curl -sS -o /tmp/add-google-cloud-ops-agent-repo.sh https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install
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

    git submodule update --init --recursive
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
}

configure_repo() {
    local network_name
    local zallet_network

    log "Configuring z3 repository"
    cd "$APP_DIR"

    if [ ! -f .env ]; then
        if [ -f .env.example ]; then
            cp .env.example .env
        else
            touch .env
        fi
    fi

    mkdir -p config/tls

    if [ "${z3_network}" = "main" ]; then
        network_name="Mainnet"
        zallet_network="main"
    else
        network_name="Testnet"
        zallet_network="test"
    fi

    ensure_env_var "NETWORK_NAME" "$network_name"
    ensure_env_var "Z3_ZEBRA_DATA_PATH" "$DATA_MOUNT_PATH"

    if [ ! -f config/tls/zaino.crt ] || [ ! -f config/tls/zaino.key ]; then
        log "Generating Zaino TLS certificate"
        openssl req -x509 -newkey rsa:4096 \
            -keyout config/tls/zaino.key \
            -out config/tls/zaino.crt \
            -sha256 -days 365 -nodes \
            -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost,DNS:zaino,IP:127.0.0.1"
    fi

    if [ ! -f config/zallet_identity.txt ]; then
        log "Generating Zallet identity file"
        rage-keygen -o config/zallet_identity.txt
    fi

    if [ -f config/zallet.toml ]; then
        sed -i.bak "0,/^network = \".*\"/s//network = \"$${zallet_network}\"/" config/zallet.toml
    fi
}

build_required_images() {
    log "Building required z3 images"
    cd "$APP_DIR"
    docker compose build zaino zallet
}

install_runtime_helpers() {
    log "Installing runtime helper scripts and systemd services"

    cat <<'EOF' > /usr/local/bin/z3-check-zebra-readiness
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec ./check-zebra-readiness.sh
EOF
    chmod 0755 /usr/local/bin/z3-check-zebra-readiness

    cat <<'EOF' > /usr/local/bin/z3-start-full-stack
#!/bin/bash
set -euo pipefail
cd /opt/z3
exec docker compose up -d
EOF
    chmod 0755 /usr/local/bin/z3-start-full-stack

    cat <<'EOF' > /etc/systemd/system/z3-zebra.service
[Unit]
Description=Z3 Zebra initial sync phase
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/z3
ExecStart=/usr/bin/docker compose up -d zebra
ExecStop=/usr/bin/docker compose stop zebra
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > /etc/systemd/system/z3-stack.service
[Unit]
Description=Z3 full stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/z3
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable z3-zebra.service
    systemctl start z3-zebra.service
}

log "Starting z3 host initialization for project ${gcloud_project}"
install_base_packages
install_tmux_config
install_ops_agent
install_docker
ensure_user
ensure_data_disk
ensure_rage
checkout_repo
configure_repo
#build_required_images
# uncomment above ot use local build instead of pulling from registry - requires docker buildx to be installed
install_runtime_helpers
log "z3 host initialization complete"
