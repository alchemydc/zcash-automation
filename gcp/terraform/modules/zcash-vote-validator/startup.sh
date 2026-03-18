#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/zcash-vote-validator-startup.log"
exec > >(tee -a "$LOG_FILE" | logger -t zcash-vote-validator-startup) 2>&1

export DEBIAN_FRONTEND=noninteractive
export HOME="$${HOME:-/root}"
export PATH="/usr/local/bin:/usr/bin:/bin:$${PATH}"

APP_USER="zcash-vote"
APP_HOME="/home/$APP_USER"
HOSTNAME_PREFIX="${hostname_prefix}"
INSTANCE_INDEX="${instance_index}"
STARTUP_STATE_DIR="/var/lib/zcash-vote-validator-startup"
PROVISIONING_COMPLETE_MARKER="$STARTUP_STATE_DIR/provisioning-complete"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

skip_if_already_initialized() {
    if [ -f "$PROVISIONING_COMPLETE_MARKER" ]; then
        log "Startup provisioning already completed; skipping"
        exit 0
    fi
}

mark_initialization_complete() {
    mkdir -p "$STARTUP_STATE_DIR"
    touch "$PROVISIONING_COMPLETE_MARKER"
}

install_base_packages() {
    log "Installing base packages"
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        jq \
        golang-go \
        tmux \
        unzip \
        htop
}

install_tmux_config() {
    log "Installing global tmux configuration"

    cat <<'EOF' > /etc/tmux.conf
unbind C-b
set -g prefix C-a
bind C-a send-prefix
set -g history-limit 10000
set -g default-command "$${SHELL}"
set -g base-index 1
bind C-a last-window
bind space next-window
bind BSpace previous-window
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
set -g mouse on
set -s escape-time 0
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
    printf '\n# Added by zcash-vote-validator startup\n%s\n' "$alias_line" >> /etc/bash.bashrc
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

install_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale"
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        log "Tailscale already installed"
    fi

    if tailscale ip -4 >/dev/null 2>&1; then
        log "Tailscale already joined; skipping (IP: $(tailscale ip -4))"
        return
    fi

    log "Joining tailnet"
    tailscale up --authkey="${tailscale_auth_key}" --hostname="$${HOSTNAME_PREFIX}-$${INSTANCE_INDEX}"

    log "Waiting for Tailscale IP"
    local retries=0
    while ! tailscale ip -4 >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [ "$retries" -ge 30 ]; then
            log "Timed out waiting for Tailscale IP"
            exit 1
        fi
        sleep 2
    done
    log "Tailscale IP: $(tailscale ip -4)"
}

ensure_user() {
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$APP_USER"
    fi
}

install_go_tools() {
    log "Installing CometBFT and grpcurl via go install"

    su - "$APP_USER" -c '
        export GOPATH="$HOME/go"
        export GOBIN="$GOPATH/bin"
        mkdir -p "$GOBIN"
        go install github.com/cometbft/cometbft/cmd/cometbft@v0.38.17
        go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
    '

    ln -sf "$APP_HOME/go/bin/cometbft" /usr/local/bin/cometbft
    ln -sf "$APP_HOME/go/bin/grpcurl" /usr/local/bin/grpcurl
}

download_install_script() {
    log "Downloading upstream install.sh"
    curl -fsSL "https://raw.githubusercontent.com/hhanh00/zcv/main/install.sh" -o "$APP_HOME/install.sh"
    chmod 0755 "$APP_HOME/install.sh"
    chown "$APP_USER:$APP_USER" "$APP_HOME/install.sh"
}

log "Starting zcash-vote-validator initialization"
skip_if_already_initialized
install_base_packages
install_tmux_config
install_global_bash_aliases
install_ops_agent
install_tailscale
ensure_user
install_go_tools
download_install_script
mark_initialization_complete
log "zcash-vote-validator initialization complete"
log ""
log "=== NEXT STEPS ==="
log "SSH in and run install.sh as the zcash-vote user to complete setup."
log "See: /home/zcash-vote/install.sh --help"
