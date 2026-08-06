#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/zcash-vote-validator-startup.log"
exec > >(tee -a "$LOG_FILE" | logger -t zcash-vote-validator-startup) 2>&1

export DEBIAN_FRONTEND=noninteractive
export HOME="$${HOME:-/root}"
export PATH="/usr/local/bin:/usr/bin:/bin:$${PATH}"

APP_USER="zcash-vote"
APP_HOME="/home/$APP_USER"
COMETBFT_HOME="$APP_HOME/.cometbft"
ZCV_RELEASE_TAG="${zcv_release_tag}"
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

# --- F-Key Mappings (Direct press, no prefix) ---

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
set -s escape-time 0

# --- Status Bar ---
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

    # Make go-installed binaries available system-wide
    ln -sf "$APP_HOME/go/bin/cometbft" /usr/local/bin/cometbft
    ln -sf "$APP_HOME/go/bin/grpcurl" /usr/local/bin/grpcurl
}

install_vote_cometbft() {
    local binary_url

    log "Installing vote-cometbft from release $ZCV_RELEASE_TAG"

    binary_url="https://github.com/hhanh00/zcv/releases/download/$${ZCV_RELEASE_TAG}/vote-cometbft"

    curl -fsSL "$binary_url" -o /usr/local/bin/vote-cometbft
    chmod 0755 /usr/local/bin/vote-cometbft

    # vote.proto is in the repo source, not in the release assets
    mkdir -p "$APP_HOME/proto"
    curl -fsSL "https://raw.githubusercontent.com/hhanh00/zcv/main/zcvlib/protos/vote.proto" -o "$APP_HOME/proto/vote.proto"
    chown -R "$APP_USER:$APP_USER" "$APP_HOME/proto"
}

configure_cometbft() {
    log "Initializing and configuring CometBFT"

    su - "$APP_USER" -c "cometbft init --home $COMETBFT_HOME"

    # Download genesis
    curl -fsSL -L "${genesis_url}" -o "$COMETBFT_HOME/config/genesis.json"
    chown "$APP_USER:$APP_USER" "$COMETBFT_HOME/config/genesis.json"

    # Configure seed peer
    local config_file="$COMETBFT_HOME/config/config.toml"
    sed -i "s|^seeds = .*|seeds = \"${seed}\"|" "$config_file"

    # Set external address to Tailscale IP
    local tailscale_ip
    tailscale_ip="$(tailscale ip -4)"
    sed -i "s|^external_address = .*|external_address = \"$${tailscale_ip}:26656\"|" "$config_file"

    chown -R "$APP_USER:$APP_USER" "$COMETBFT_HOME"
}

install_systemd_services() {
    log "Installing systemd services for cometbft and vote-cometbft"

    cat <<EOF > /etc/systemd/system/vote-cometbft.service
[Unit]
Description=Vote CometBFT ABCI application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_HOME
ExecStart=/usr/local/bin/vote-cometbft
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vote-cometbft

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/cometbft.service
[Unit]
Description=CometBFT node
After=vote-cometbft.service
Wants=vote-cometbft.service

[Service]
Type=simple
User=$APP_USER
ExecStart=/usr/local/bin/cometbft start --home $COMETBFT_HOME
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cometbft

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vote-cometbft.service cometbft.service
    systemctl start vote-cometbft.service cometbft.service
}

install_helper_script() {
    log "Installing zcash-vote helper script"

    cat <<'HELPEREOF' > /usr/local/bin/zcash-vote
#!/bin/bash
set -euo pipefail

APP_USER="zcash-vote"
APP_HOME="/home/$APP_USER"
COMETBFT_HOME="$APP_HOME/.cometbft"
PROTO_DIR="$APP_HOME/proto"

usage() {
    cat <<EOF
Usage: zcash-vote <command>

Commands:
  promote              Promote this node to validator
  show-validators      Show current validator set
  coordinate           Show node ID and Tailscale IP for peering
  set-election         Send election definition (--election-json <file>)
  lock                 Lock the blockchain
  unsafe-reset         Stop services and reset all chain data
  start                Start cometbft and vote-cometbft services
  stop                 Stop cometbft and vote-cometbft services
  status               Show service status
  logs                 Follow service logs
EOF
}

cmd_promote() {
    local pub_key
    pub_key="$(jq '.pub_key.value' "$COMETBFT_HOME/config/priv_validator_key.json")"

    grpcurl -plaintext \
        -import-path "$PROTO_DIR" \
        -proto vote.proto \
        -d "{\"pub_key\": $pub_key, \"power\": \"10\"}" \
        localhost:9010 cash.z.vote.sdk.rpc.VoteStreamer/AddValidator
}

cmd_show_validators() {
    curl -s localhost:26657/validators | jq .result
}

cmd_coordinate() {
    local node_id
    node_id="$(cometbft show-node-id --home "$COMETBFT_HOME")"
    local ts_ip
    ts_ip="$(tailscale ip -4)"
    echo "Node ID:       $node_id"
    echo "Tailscale IP:  $ts_ip"
    echo "Seed address:  $${node_id}@$${ts_ip}:26656"
}

cmd_set_election() {
    local election_json=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --election-json)
                election_json="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    if [ -z "$election_json" ]; then
        echo "Usage: zcash-vote set-election --election-json <file>" >&2
        exit 1
    fi

    grpcurl -plaintext \
        -import-path "$PROTO_DIR" \
        -proto vote.proto \
        -d "$(cat "$election_json")" \
        localhost:9010 cash.z.vote.sdk.rpc.VoteStreamer/SetElection
}

cmd_lock() {
    grpcurl -plaintext \
        -import-path "$PROTO_DIR" \
        -proto vote.proto \
        localhost:9010 cash.z.vote.sdk.rpc.VoteStreamer/Lock
}

cmd_unsafe_reset() {
    echo "Stopping services..."
    systemctl stop vote-cometbft.service cometbft.service || true

    echo "Removing vote.db..."
    rm -rf "$APP_HOME/vote.db"

    echo "Running cometbft unsafe-reset-all..."
    su - "$APP_USER" -c "cometbft unsafe-reset-all --home $COMETBFT_HOME"

    echo "Reset complete. Use 'zcash-vote start' to restart services."
}

cmd_start() {
    systemctl start cometbft.service vote-cometbft.service
}

cmd_stop() {
    systemctl stop vote-cometbft.service cometbft.service
}

cmd_status() {
    systemctl status cometbft.service vote-cometbft.service --no-pager
}

cmd_logs() {
    journalctl -u cometbft -u vote-cometbft -f
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    promote)         cmd_promote ;;
    show-validators) cmd_show_validators ;;
    coordinate)      cmd_coordinate ;;
    set-election)    cmd_set_election "$@" ;;
    lock)            cmd_lock ;;
    unsafe-reset)    cmd_unsafe_reset ;;
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    status)          cmd_status ;;
    logs)            cmd_logs ;;
    *)
        echo "Unknown command: $command" >&2
        usage
        exit 1
        ;;
esac
HELPEREOF

    chmod 0755 /usr/local/bin/zcash-vote
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
install_vote_cometbft
configure_cometbft
install_systemd_services
install_helper_script
mark_initialization_complete
log "zcash-vote-validator initialization complete"
