#!/bin/bash
set -x

apt update && apt install -y screen htop nftables pigz clang libclang1 libclang-dev build-essential llvm 

# ---- Configure logrotate ----
echo "Configuring logrotate" | logger
cat <<'EOF' > '/etc/logrotate.d/rsyslog'
/var/log/syslog
/var/log/mail.info
/var/log/mail.warn
/var/log/mail.err
/var/log/mail.log
/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/lpr.log
/var/log/cron.log
/var/log/debug
/var/log/messages
{
        rotate 3
        daily
        missingok
        notifempty
        delaycompress
        compress
        sharedscripts
        postrotate
                #invoke-rc.d rsyslog rotate > /dev/null   # does not work on debian10
                kill -HUP `pidof rsyslogd`
        endscript
}
EOF

# zcashd -printtoconsole emits ANSI colors in logs, which won't render properly without this
echo '$EscapeControlCharactersOnReceive off' >> /etc/rsyslog.conf

# ---- Restart rsyslogd
echo "Restarting rsyslogd"
systemctl restart rsyslog


# ---- Useful aliases ----
echo "Configuring aliases" | logger
echo "alias ll='ls -laF'" >> /etc/skel/.bashrc
echo "alias ll='ls -laF'" >> /root/.bashrc


# ---- Install Stackdriver Agent
echo "Installing Stackdriver agent" | logger
curl -sSO https://dl.google.com/cloudagents/add-monitoring-agent-repo.sh
bash add-monitoring-agent-repo.sh
apt update -y
apt install -y stackdriver-agent
systemctl restart stackdriver-agent

# ---- Install Fluent Log Collector
echo "Installing google fluent log collector agent" | logger
curl -sSO https://dl.google.com/cloudagents/add-logging-agent-repo.sh
bash add-logging-agent-repo.sh
apt update -y
apt install -y google-fluentd
apt install -y google-fluentd-catch-all-config-structured
systemctl restart google-fluentd

# add zcash user
useradd -m zebra -s /bin/bash

# ---- Set Up Persistent Disk for .zebra dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${data_disk_name})
DATA_DIR=/home/zebra/.cache

echo "Setting up persistent disk ${data_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

echo "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

# If the disk has already been formatted previously (this will happen
# if this instance has been recreated with the same disk), we skip formatting
if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  echo "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  echo "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

# Mounting the volume
echo "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR
chown -R zebra:zebra $DATA_DIR

# ---- Set Up Persistent Disk for .cargo dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${params_disk_name})
DATA_DIR=/home/zebra/.cargo

echo "Setting up persistent disk ${params_disk_name} at $DISK_PATH..."

DISK_FORMAT=ext4
CURRENT_DISK_FORMAT=$(lsblk -i -n -o fstype $DISK_PATH)

echo "Checking if disk $DISK_PATH format $CURRENT_DISK_FORMAT matches desired $DISK_FORMAT..."

# If the disk has already been formatted previously (this will happen
# if this instance has been recreated with the same disk), we skip formatting
if [[ $CURRENT_DISK_FORMAT == $DISK_FORMAT ]]; then
  echo "Disk $DISK_PATH is correctly formatted as $DISK_FORMAT"
else
  echo "Disk $DISK_PATH is not formatted correctly, formatting as $DISK_FORMAT..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $DISK_PATH
fi

# Mounting the volume
echo "Mounting $DISK_PATH onto $DATA_DIR"
mkdir -p $DATA_DIR
DISK_UUID=$(blkid $DISK_PATH | cut -d '"' -f2)
echo "UUID=$DISK_UUID     $DATA_DIR   auto    discard,defaults    0    0" >> /etc/fstab
mount $DATA_DIR
chown -R zebra:zebra $DATA_DIR

# ---- Setup swap
echo "Setting up swapfile" | logger
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
swapon -s

# ---- Config /etc/screenrc ----
echo "Configuring /etc/screenrc" | logger
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
echo "Creating chaindata backup script" | logger
cat <<'EOF' > /root/backup.sh
#!/bin/bash
# This script stops zebrad, tars up the chaindata (with gzip compression), and copies it to GCS.
# The 'chaindata' GCS bucket has versioning enabled, so if a corrupted tarball is uploaded, an older version can be selected for restore.
# This takes quit some time, and takes quite a bit of local disk.
# The rsync variant (below) is more efficient, but tarballs are more portable.
set -x

echo "Starting chaindata backup" | logger
echo "Stopping zebrad" | logger
systemctl stop zebrad.service
sleep 5
echo "Tarring up chainstate and blocks" | logger
mkdir /home/zebra/.cache/backup
tar -I "pigz --fast" --exclude='IDENTITY' -C /home/zebra/.cache -cvf /home/zebra/.cache/backup/zebra_chaindata.tgz zebra
echo "copying tarball to GCS" | logger
gsutil cp /home/zebra/.cache/backup/zebra_chaindata.tgz gs://${gcloud_project}-chaindata
echo "removing tarball from local fs" | logger
rm -f /home/zebra/.cache/backup/zebra_chaindata.tgz
echo "Chaindata backup completed" | logger
sleep 3
echo "starting zebrad" | logger
systemctl start zebrad.service
EOF
chmod u+x /root/backup.sh

# ----- Create snapshot script
cat <<EOF > /root/backup_snapshot.sh
#!/bin/bash
# This script stops zebrad, deletes snapshots from GCS, and then snapshots the
# disk containing the Zebra cargo dir, as well as the disk containing the Zcash blockchain
# and supporting data.

set -x
echo "Deleting snapshots" | logger
echo 'y' | gcloud compute snapshots delete ${data_disk_name}-snapshot-latest 
echo 'y' | gcloud compute snapshots delete ${params_disk_name}-snapshot-latest
echo "Taking snapshot of Zebra cargo disk" | logger
gcloud compute disks snapshot ${params_disk_name} --snapshot-names=${params_disk_name}-snapshot-latest --zone=${gcloud_zone}
echo "Stopping zebrad"
systemctl stop zebrad
sleep 5
echo "Taking snapshot of Zebrad data disk" | logger
gcloud compute disks snapshot ${data_disk_name} --snapshot-names=${data_disk_name}-snapshot-latest --zone=${gcloud_zone}
sleep 3
echo "starting zebrad" | logger
systemctl start zebrad.service
EOF
chmod u+x /root/backup_snapshot.sh

# ---- Create rsync backup script
echo "Creating rsync chaindata backup script" | logger
cat <<'EOF' > /root/backup_rsync.sh
#!/bin/bash
# This script stops zebrad, and uses rsync to copy chaindata to GCS.
set -x

echo "Starting rsync chaindata backup" | logger
echo "Stopping zebrad" | logger
systemctl stop zebrad.service
sleep 5
echo "rsyncing Zebra state to GCS" | logger
gsutil -m rsync -d -r /home/zebra/.cache/zebra gs://${gcloud_project}-chaindata-rsync/zebra
echo "rsync chaindata backup completed" | logger
sleep 3
echo "starting zebrad" | logger
systemctl start zebrad.service
EOF
chmod u+x /root/backup_rsync.sh

# ---- Add backups to cron

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

# ---- Create restore script
echo "Creating chaindata restore script" | logger
cat <<'EOF' > /root/restore.sh
#!/bin/bash
set -x

# test to see if chaindata exists in bucket
gsutil -q stat gs://${gcloud_project}-chaindata/zebra_chaindata.tgz
if [ $? -eq 0 ]
then
  #chaindata exists in bucket
  mkdir -p /home/zebra/.cache
  mkdir -p /home/zebra/.cache/restore
  echo "downloading chaindata from gs://${gcloud_project}-chaindata/zebra_chaindata.tgz" | logger
  gsutil cp gs://${gcloud_project}-chaindata/zebra_chaindata.tgz /home/zebra/.cache/restore/zebra_chaindata.tgz
  echo "stopping zebrad to untar chaindata" | logger
  systemctl stop zebrad.service
  sleep 3
  echo "Deleting old chaindata" | logger
  rm -rf /home/zebra/.cache/*
  echo "untarring chaindata" | logger
  tar xvf /home/zebra/.cache/restore/zebra_chaindata.tgz -I pigz --directory /home/zebra/.cache
  echo "Setting perms on chaindata" | logger
  chown -R zebra:zebra /home/zebra/.cache
  echo "removing chaindata tarball" | logger
  rm -rf /home/zebra/.cache/restore/zebra_chaindata.tgz
  sleep 3
  echo "starting zebrad" | logger
  systemctl start zebrad.service
  else
    echo "No zebra_chaindata.tgz found in bucket gs://${gcloud_project}-chaindata, aborting warp restore" | logger
    echo "Starting zebrad" | logger
    systemctl start zebrad
  fi
EOF
chmod u+x /root/restore.sh

# ---- Create rsync restore script
echo "Creating rsync chaindata restore script" | logger
cat <<'EOF' > /root/restore_rsync.sh
#!/bin/bash
set -x

# test to see if chaindata exists in the rsync chaindata bucket
gsutil -q stat gs://${gcloud_project}-chaindata-rsync/zebra
if [ $? -eq 0 ]
then
  #chaindata exists in bucket
  echo "stopping zebrad" | logger
  systemctl stop zebrad.service
  echo "downloading Zebra state via rsync from gs://${gcloud_project}-chaindata-rsync/zebra" | logger
  mkdir -p /home/zebra/.cache/zebra
  gsutil -m rsync -d -r gs://${gcloud_project}-chaindata-rsync/zebra /home/zebra/.cache/zebra
  echo "Setting perms on state" | logger
  chown -R zebra:zebra /home/zebra/.cache
  echo "starting zebrad" | logger
  sleep 3
  systemctl start zebrad.service
  else
    echo "No chaindata found in bucket gs://${gcloud_project}-chaindata-rsync, aborting warp restore" | logger
  fi
EOF
chmod u+x /root/restore_rsync.sh

echo "Configuring firewall rules" | logger
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

echo "Enabling host nftables firewall" | logger
systemctl enable nftables.service
systemctl start nftables.service

echo "Creating Zebra install script in /home/zebra" | logger
tee << 'EOF' > /dev/null /home/zebra/install_zebra.sh
#!/bin/bash
set -x
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. /home/zebra/.cargo/env
cargo install --locked --git https://github.com/ZcashFoundation/zebra --tag v1.0.0-alpha.13 zebrad
zebrad generate > /home/zebra/zebrad.conf
EOF

echo "Creating systemd unit for zebrad" | logger
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

echo "Setting perms on zebra installer" | logger
chown -R zebra:zebra /home/zebra
chmod u+x /home/zebra/install_zebra.sh
echo "Running zebra installer as zebra user" | logger
sudo -u zebra /home/zebra/install_zebra.sh

echo "Enabling zebrad via systemd" | logger
systemctl daemon-reload
systemctl enable zebrad.service

echo "Creating zebrad.conf" | logger
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
checkpoint_sync = false

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
#listen_addr = '${external_ip_address}:8233'    # note this does NOT work presently [known issue, can't advertise addr not bound to]
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
lookahead_limit = 2000
max_concurrent_block_requests = 50

[tracing]
use_color = true
use_journald = false
EOF
echo "Setting perms on zebra config" | logger
chown -R zebra:zebra /home/zebra

echo "Starting zebrad" | logger
systemctl start zebrad