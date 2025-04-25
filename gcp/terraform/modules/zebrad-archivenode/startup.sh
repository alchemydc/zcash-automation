#!/bin/bash
set -euo pipefail
set -x

# Add a logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | logger -t startup-script
}

log "Starting zebra node initialization"

apt update && apt install -y screen htop nftables pigz clang libclang1 libclang-dev build-essential llvm

# ---- Useful aliases ----
log "Configuring aliases"
echo "alias ll='ls -laF'" >> /etc/skel/.bashrc
echo "alias ll='ls -laF'" >> /root/.bashrc

# ---- Install Google Ops Agent ----
log "Installing Google Ops Agent"
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# add zebra user
useradd -m zebra -s /bin/bash

# ---- Set Up Persistent Disk for .zebra dir ----
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${data_disk_name})
DATA_DIR=/home/zebra/.cache

log "Setting up persistent disk ${data_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

log "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  log "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  log "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

log "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR
chown -R zebra:zebra $DATA_DIR

# ---- Set Up Persistent Disk for .cargo dir ----
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${params_disk_name})
DATA_DIR=/home/zebra/.cargo

log "Setting up persistent disk ${params_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

log "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  log "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  log "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

log "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR
chown -R zebra:zebra $DATA_DIR

# ---- Setup swap
log "Setting up swapfile"
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
swapon -s

# ---- Config /etc/screenrc ----
log "Configuring /etc/screenrc"
cat <<'EOF' >> '/etc/screenrc'
bindkey -k k1 select 1  #  F1 = screen 1
bindkey -k k2 select 2  #  F2 = screen 2
bindkey -k k3 select 3  #  F3 = screen 3
bindkey -k k4 select 4  #  F4 = screen 4
bindkey -k k5 select 5  #  F5 = screen 5
bindkey -k k6 select 6  #  F6 = screen 6
bindkey -k k7 select 7  #  F7 = screen 7
bindkey -k k8 select 8  #  F8 = screen 8
bindkey -k k9 select 9  #  F9 = screen 9
bindkey -k F1 prev      # F11 = prev
bindkey -k F2 next      # F12 = next
EOF

# ---- Create backup script
log "Creating chaindata backup script"
cat <<'EOF' > /root/backup.sh
#!/bin/bash
set -x

log "Starting chaindata backup"
log "Stopping zebrad"
systemctl stop zebrad.service
sleep 5
log "Tarring up chainstate and blocks"
mkdir /home/zebra/.cache/backup
tar -I "pigz --fast" --exclude='IDENTITY' -C /home/zebra/.cache -cvf /home/zebra/.cache/backup/zebra_chaindata.tgz zebra
log "copying tarball to GCS"
gsutil cp /home/zebra/.cache/backup/zebra_chaindata.tgz gs://${gcloud_project}-chaindata
log "removing tarball from local fs"
rm -f /home/zebra/.cache/backup/zebra_chaindata.tgz
log "Chaindata backup completed"
sleep 3
log "starting zebrad"
systemctl start zebrad.service
EOF
chmod u+x /root/backup.sh

# ----- Create snapshot script
cat <<EOF > /root/backup_snapshot.sh
#!/bin/bash
set -x
log "Deleting snapshots"
echo 'y' | gcloud compute snapshots delete ${data_disk_name}-snapshot-latest 
echo 'y' | gcloud compute snapshots delete ${params_disk_name}-snapshot-latest
log "Taking snapshot of Zebra cargo disk"
gcloud compute disks snapshot ${params_disk_name} --snapshot-names=${params_disk_name}-snapshot-latest --zone=${gcloud_zone}
log "Stopping zebrad"
systemctl stop zebrad
sleep 5
log "Taking snapshot of Zebrad data disk"
gcloud compute disks snapshot ${data_disk_name} --snapshot-names=${data_disk_name}-snapshot-latest --zone=${gcloud_zone}
sleep 3
log "starting zebrad"
systemctl start zebrad.service
EOF
chmod u+x /root/backup_snapshot.sh

# ---- Create rsync backup script
log "Creating rsync chaindata backup script"
cat <<'EOF' > /root/backup_rsync.sh
#!/bin/bash
set -x

log "Starting rsync chaindata backup"
log "Stopping zebrad"
systemctl stop zebrad.service
sleep 5
log "rsyncing Zebra state to GCS"
gsutil -m rsync -d -r /home/zebra/.cache/zebra gs://${gcloud_project}-chaindata-rsync/zebra
log "rsync chaindata backup completed"
sleep 3
log "starting zebrad"
systemctl start zebrad.service
EOF
chmod u+x /root/backup_rsync.sh

# ---- Add backups to cron
if [ "${enable_cron_backups}" = "true" ]; then
cat <<'EOF' > /root/backup.crontab
# m h  dom mon dow   command
57 0 * * 0 /root/backup.sh | logger
17 0 * * * /root/backup_rsync.sh | logger
20 04 * * * /root/backup_snapshot.sh | logger
EOF
/usr/bin/crontab /root/backup.crontab
fi

# ---- Create restore script
log "Creating chaindata restore script"
cat <<'EOF' > /root/restore.sh
#!/bin/bash
set -x

gsutil -q stat gs://${gcloud_project}-chaindata/zebra_chaindata.tgz
if [ $? -eq 0 ]
then
  mkdir -p /home/zebra/.cache
  mkdir -p /home/zebra/.cache/restore
  log "downloading chaindata from gs://${gcloud_project}-chaindata/zebra_chaindata.tgz"
  gsutil cp gs://${gcloud_project}-chaindata/zebra_chaindata.tgz /home/zebra/.cache/restore/zebra_chaindata.tgz
  log "stopping zebrad to untar chaindata"
  systemctl stop zebrad.service
  sleep 3
  log "Deleting old chaindata"
  rm -rf /home/zebra/.cache/*
  log "untarring chaindata"
  tar xvf /home/zebra/.cache/restore/zebra_chaindata.tgz -I pigz --directory /home/zebra/.cache
  log "Setting perms on chaindata"
  chown -R zebra:zebra /home/zebra/.cache
  log "removing chaindata tarball"
  rm -rf /home/zebra/.cache/restore/zebra_chaindata.tgz
  sleep 3
  log "starting zebrad"
  systemctl start zebrad.service
  else
    log "No zebra_chaindata.tgz found in bucket gs://${gcloud_project}-chaindata, aborting warp restore"
    log "Starting zebrad"
    systemctl start zebrad
  fi
EOF
chmod u+x /root/restore.sh

# ---- Create rsync restore script
log "Creating rsync chaindata restore script"
cat <<'EOF' > /root/restore_rsync.sh
#!/bin/bash
set -x

gsutil -q stat gs://${gcloud_project}-chaindata-rsync/zebra
if [ $? -eq 0 ]
then
  log "stopping zebrad"
  systemctl stop zebrad.service
  log "downloading Zebra state via rsync from gs://${gcloud_project}-chaindata-rsync/zebra"
  mkdir -p /home/zebra/.cache/zebra
  gsutil -m rsync -d -r gs://${gcloud_project}-chaindata-rsync/zebra /home/zebra/.cache/zebra
  log "Setting perms on state"
  chown -R zebra:zebra /home/zebra/.cache
  log "starting zebrad"
  sleep 3
  systemctl start zebrad.service
  else
    log "No chaindata found in bucket gs://${gcloud_project}-chaindata-rsync, aborting warp restore"
  fi
EOF
chmod u+x /root/restore_rsync.sh

log "Configuring firewall rules"
 tee <<EOF >/dev/null /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
        chain input {
                type filter hook input priority 0;
                iif lo accept
                ct state established,related accept
                tcp dport { 22, 8233 } ct state new accept
                counter drop
        }
}
EOF

log "Enabling host nftables firewall"
systemctl enable nftables.service
systemctl start nftables.service

log "Creating Zebra install script in /home/zebra"
tee << 'EOF' > /dev/null /home/zebra/install_zebra.sh
#!/bin/bash
set -x
echo "Installing rust"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
echo "Adding rust to path"
. /home/zebra/.cargo/env
# Rust/Cargo optimized build flags for production
echo "Building zebrad with optimizations"
export RUSTFLAGS="-C target-cpu=native -C codegen-units=1 -C opt-level=3"
export CARGO_PROFILE_RELEASE_LTO="thin"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3

# Install zebrad with optimizations and features
cargo install \
    --locked \
    --features prometheus \
    --git https://github.com/ZcashFoundation/zebra zebrad\
    --tag "${zebra_release_tag}" \
    --jobs "$(nproc)" \
    --verbose
echo "Generating default zebrad config"
zebrad generate > /home/zebra/zebrad.conf
EOF

log "Creating systemd unit for zebrad"
tee <<'EOF' > /dev/null /etc/systemd/system/zebrad.service
[Unit]
Description=Zebrad
Requires=zebrad.service

[Service]
User=zebra
Group=zebra
ExecStart=/home/zebra/.cargo/bin/zebrad -c /home/zebra/zebrad.conf start
Restart=on-failure
RestartSec=30
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=zebrad

[Install]
WantedBy=multi-user.target
EOF

log "Setting perms on zebra installer"
chown -R zebra:zebra /home/zebra
chmod u+x /home/zebra/install_zebra.sh
log "Running zebra installer as zebra user"
sudo -u zebra /home/zebra/install_zebra.sh

log "Enabling zebrad via systemd"
systemctl daemon-reload
systemctl enable zebrad.service

log "Creating zebrad.conf"
cat << EOF > /home/zebra/zebrad.conf
# This file can be used as a skeleton for custom configs.
#
# Unspecified fields use default values. Optional fields are Some(field) if the
# field is present and None if it is absent.
#
# This file is generated as an example using zebrad's current defaults.
# You should set only the config options you want to keep, and delete the rest.
# Only a subset of fields are present in the skeleton, since optional values
# whose default is None are omitted.
#
# The config format (including a complete list of sections and fields) is
# documented here:
# https://doc.zebra.zfnd.org/zebrad/config/struct.ZebradConfig.html
#
# zebrad attempts to load configs in the following order:
#
# 1. The -c flag on the command line, e.g., `zebrad -c myconfig.toml start`;
# 2. The file `zebrad.toml` in the users's preference directory (platform-dependent);
# 3. The default config.

[consensus]
checkpoint_sync = true

[metrics]

[network]
initial_mainnet_peers = [
    'dnsseed.z.cash:8233',
    'dnsseed.str4d.xyz:8233',
    'mainnet.seeder.zfnd.org:8233',
    'mainnet.is.yolo.money:8233',
]
initial_testnet_peers = [
    'testnet.seeder.zfnd.org:18233',
    'testnet.is.yolo.money:18233',
    'dnsseed.testnet.z.cash:18233',
]
listen_addr = '0.0.0.0:8233'
network = 'Mainnet'
peerset_initial_target_size = 50

[network.crawl_new_peer_interval]
nanos = 0
secs = 60

[state]
cache_dir = '/home/zebra/.cache/zebra'
ephemeral = false

[sync]
checkpoint_verify_concurrency_limit = 1000
download_concurrency_limit = 50
full_verify_concurrency_limit = 20
parallel_cpu_threads = 0

[tracing]
buffer_limit = 128000
force_use_color = false
use_color = false
use_journald = true
EOF

log "Setting perms on zebra config"
chown -R zebra:zebra /home/zebra

log "Starting zebrad"
systemctl start zebrad
