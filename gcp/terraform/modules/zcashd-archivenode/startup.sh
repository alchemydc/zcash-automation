#!/bin/bash
# Add better error handling
set -euo pipefail
# Keep existing debug output
set -x

# Injected by Terraform

# Add a logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | logger -t startup-script
}

log "Starting node initialization"

apt update && apt install -y screen htop nftables pigz

# ---- Configure logrotate ----
# no longer needed since debian 12 uses systemd-journald which does it own log rotation

# ---- Useful aliases ----
log "Configuring aliases"
echo "alias ll='ls -laF'" >> /etc/skel/.bashrc
echo "alias ll='ls -laF'" >> /root/.bashrc

# ---- Install Google Ops Agent ----
log "Installing Google Ops Agent"
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# add zcash user
useradd -m zcash -s /bin/bash

# ---- Set Up Persistent Disk for .zcash dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${data_disk_name})
DATA_DIR=/home/zcash/.zcash

log "Setting up persistent disk ${data_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

log "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

# If the disk has already been formatted previously (this will happen
# if this instance has been recreated with the same disk), we skip formatting
if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  log "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  log "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

# Mounting the volume
log "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR

log "Creating zcash.conf"
cat <<'EOF' > $DATA_DIR/zcash.conf
externalip=${external_ip_address}
testnet=0
listen=1
maxconnections=20
i-am-aware-zcashd-will-be-replaced-by-zebrad-and-zallet-in-2025=1
printtoconsole=1
EOF
chown -R zcash:zcash /home/zcash


# ---- Set Up Persistent Disk for .zcash-params dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${params_disk_name})
DATA_DIR=/home/zcash/.zcash-params

log "Setting up persistent disk ${params_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

log "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

# If the disk has already been formatted previously (this will happen
# if this instance has been recreated with the same disk), we skip formatting
if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  log "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  log "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

# Mounting the volume
log "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR
chown -R zcash:zcash $DATA_DIR

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
# This script stops zcashd, tars up the chaindata (with bzip compression), and copies it to GCS.
# The 'chaindata' GCS bucket has versioning enabled, so if a corrupted tarball is uploaded, an older version can be selected for restore.
# This takes quit some time, and takes quite a bit of local disk.
# The rsync variant (below) is more efficient, but tarballs are more portable.
set -x

log "Starting chaindata backup"
log "Stopping zcashd"
systemctl stop zcashd.service
sleep 5
log "Tarring up chainstate and blocks"
mkdir /home/zcash/.zcash/backup
tar -I "pigz --fast" -C /home/zcash/.zcash -cvf /home/zcash/.zcash/backup/chaindata.tgz blocks chainstate
log "copying tarball to GCS"
gsutil cp /home/zcash/.zcash/backup/chaindata.tgz gs://${gcloud_project}-chaindata
log "removing tarball from local fs"
rm -f /home/zcash/.zcash/backup/chaindata.tgz
log "Chaindata backup completed"
sleep 3
log "starting zcashd"
systemctl start zcashd.service
EOF
chmod u+x /root/backup.sh

# ----- Create snapshot script
cat <<EOF > /root/backup_snapshot.sh
#!/bin/bash
# This script stops zcashd, deletes snapshots from GCS, and then snapshots the
# disk containing the Zcash parameters, as well as the disk containing the Zcash blockchain
# and supporting data.

set -x
log "Deleting snapshots"
echo 'y' | gcloud compute snapshots delete ${data_disk_name}-snapshot-latest 
echo 'y' | gcloud compute snapshots delete ${params_disk_name}-snapshot-latest
log "Taking snapshot of Zcash params disk"
gcloud compute disks snapshot ${params_disk_name} --snapshot-names=${params_disk_name}-snapshot-latest --zone=${gcloud_zone}
log "Stopping zcashd"
systemctl stop zcashd
sleep 5
log "Taking snapshot of Zcash data disk"
gcloud compute disks snapshot ${data_disk_name} --snapshot-names=${data_disk_name}-snapshot-latest --zone=${gcloud_zone}
sleep 3
log "starting zcashd"
systemctl start zcashd.service
EOF
chmod u+x /root/backup_snapshot.sh

# ---- Create rsync backup script
log "Creating rsync chaindata backup script"
cat <<'EOF' > /root/backup_rsync.sh
#!/bin/bash
# This script stops zcashd, and uses rsync to copy chaindata to GCS.
set -x

log "Starting rsync chaindata backup"
log "Stopping zcashd"
systemctl stop zcashd.service
sleep 5
log "rsyncing blocks to GCS"
gsutil -m rsync -d -r /home/zcash/.zcash/blocks gs://${gcloud_project}-chaindata-rsync/zcashd/blocks
log "rsyncing chainstate to GCS"
gsutil -m rsync -d -r /home/zcash/.zcash/chainstate gs://${gcloud_project}-chaindata-rsync/zcashd/chainstate
log "rsync chaindata backup completed"
sleep 3
log "starting zcashd"
systemctl start zcashd.service
EOF
chmod u+x /root/backup_rsync.sh

# ---- Add backups to cron

if [ "${enable_cron_backups}" = "true" ]; then
cat <<'EOF' > /root/backup.crontab
# m h  dom mon dow   command
# backup full tarball once a week at 00:57 on Sunday
57 0 * * 0 /root/backup.sh | logger

# backup via rsync once a day at 00:17 past the hour
17 0 * * * /root/backup_rsync.sh | logger

# backup via snapshot once a day at 04:20 past the hour
# note that snapshot backup is the only method enabled by default, because it's by far the fastest.
20 04 * * * /root/backup_snapshot.sh | logger
EOF
/usr/bin/crontab /root/backup.crontab
fi

# ---- Create restore script
log "Creating chaindata restore script"
cat <<'EOF' > /root/restore.sh
#!/bin/bash
set -x

# test to see if chaindata exists in bucket
gsutil -q stat gs://${gcloud_project}-chaindata/chaindata.tgz
if [ $? -eq 0 ]
then
  #chaindata exists in bucket
  mkdir -p /home/zcash/.zcash
  mkdir -p /home/zcash/.zcash/restore
  log "downloading chaindata from gs://${gcloud_project}-chaindata/chaindata.tgz"
  gsutil cp gs://${gcloud_project}-chaindata/chaindata.tgz /home/zcash/.zcash/restore/chaindata.tgz
  log "stopping zcashd to untar chaindata"
  systemctl stop zcashd.service
  sleep 3
  log "Deleting old chaindata"
  rm -rf /home/zcash/.zcash/blocks/*
  rm -rf /home/zcash/.zcash/chainstate/*
  log "untarring chaindata"
  tar xvf /home/zcash/.zcash/restore/chaindata.tgz -I pigz --directory /home/zcash/.zcash
  log "Setting perms on chaindata"
  chown -R zcash:zcash /home/zcash/.zcash
  log "removing chaindata tarball"
  rm -rf /home/zcash/.zcash/restore/chaindata.tgz
  sleep 3
  log "starting zcashd"
  systemctl start zcashd.service
  else
    log "No chaindata.tgz found in bucket gs://${gcloud_project}-chaindata, aborting warp restore"
    log "Starting zcashd"
    systemctl start zcashd
  fi
EOF
chmod u+x /root/restore.sh

# ---- Create rsync restore script
log "Creating rsync chaindata restore script"
cat <<'EOF' > /root/restore_rsync.sh
#!/bin/bash
set -x

# test to see if chaindata exists in the rsync chaindata bucket
gsutil -q stat gs://${gcloud_project}-chaindata-rsync/zcashd/blocks/blk00000.dat
if [ $? -eq 0 ]
then
  #chaindata exists in bucket
  log "stopping zcashd"
  systemctl stop zcashd.service
  log "downloading blocks via rsync from gs://${gcloud_project}-chaindata-rsync/zcashd/blocks"
  mkdir -p /home/zcash/.zcash/blocks
  gsutil -m rsync -d -r gs://${gcloud_project}-chaindata-rsync/zcashd/blocks /home/zcash/.zcash/blocks
  log "downloading chainstate via rsync from gs://${gcloud_project}-chaindata-rsync/zcashd/chainstate"
  mkdir -p /home/zcash/.zcash/chainstate
  gsutil -m rsync -d -r gs://${gcloud_project}-chaindata-rsync/zcashd/chainstate /home/zcash/.zcash/chainstate
  log "Setting perms on chaindata"
  chown -R zcash:zcash /home/zcash/.zcash
  log "starting zcashd"
  sleep 3
  systemctl start zcashd.service
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
                # accept any localhost traffic
                iif lo accept
                # accept traffic originated from us
                ct state established,related accept
                # activate the following line to accept common local services
                # tcp/22 == sshd, tcp/8233 == zcashd
                tcp dport { 22, 8233 } ct state new accept
                # count and drop any other traffic
                counter drop
        }
}
EOF

log "Enabling host nftables firewall"
systemctl enable nftables.service
systemctl start nftables.service

log "Installing Zcash from debian package"
if ! apt install -y apt-transport-https wget gnupg2; then
    log "ERROR: Failed to install prerequisites"
    exit 1
fi

# Import Electric Coin GPG key and configure repo
wget -qO zcash.asc https://apt.z.cash/zcash.asc

gpg --dearmor < zcash.asc | tee /etc/apt/trusted.gpg.d/zcash.gpg > /dev/null
rm -f zcash.asc

# Add the Zcash APT repository (for Debian 12/bullseye)
echo "deb [signed-by=/etc/apt/trusted.gpg.d/zcash.gpg] https://apt.z.cash/ bullseye main" | tee /etc/apt/sources.list.d/zcash.list

apt update && apt install -y zcash

log "Configuring zcashd systemd service"
cat <<EOF >/etc/systemd/system/zcashd.service
[Unit]
Description=Zcash Daemon
After=network.target
Requires=network.target

[Service]
User=zcash
Group=zcash
Type=simple
ExecStart=/usr/bin/zcashd -printtoconsole
ExecStop=/usr/bin/zcash-cli stop
RestartSec=30
TimeoutStartSec=300
TimeoutStopSec=300
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=zcashd

# Security hardening
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zcashd.service


log "Checking for existing chaindata"
if [ -d /home/zcash/.zcash/blocks ]; then
  log "/home/zcash/.zcash/blocks directory exists, skipping chaindata restore"
  log "Starting zcashd"
  systemctl start zcashd
else
  log "Restoring chaindata from GCS tarball, if available"
  log "Note that chaindata from GCS via rsync may be more fresh, and can be restored by running /root/restore_rsync.sh"
  /root/restore.sh
fi
