#!/bin/bash
set -x

apt update && apt install -y screen htop nftables pigz

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
useradd -m zcash -s /bin/bash

# ---- Set Up Persistent Disk for .zcash dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${data_disk_name})
DATA_DIR=/home/zcash/.zcash

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

echo "Creating zcash.conf" | logger
cat <<'EOF' > $DATA_DIR/zcash.conf
externalip=${external_ip_address}
testnet=0
listen=1
maxconnections=20
EOF
chown -R zcash:zcash /home/zcash


# ---- Set Up Persistent Disk for .zcash-params dir ----

# gives a path similar to `/dev/sdb`
DISK_PATH=$(readlink -f /dev/disk/by-id/google-${params_disk_name})
DATA_DIR=/home/zcash/.zcash-params

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
chown -R zcash:zcash $DATA_DIR

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
# This script stops zcashd, tars up the chaindata (with bzip compression), and copies it to GCS.
# The 'chaindata' GCS bucket has versioning enabled, so if a corrupted tarball is uploaded, an older version can be selected for restore.
# This takes quit some time, and takes quite a bit of local disk.
# The rsync variant (below) is more efficient, but tarballs are more portable.
set -x

echo "Starting chaindata backup" | logger
echo "Stopping zcashd" | logger
systemctl stop zcashd.service
sleep 5
echo "Tarring up chainstate and blocks" | logger
mkdir /home/zcash/.zcash/backup
tar -I "pigz --fast" -C /home/zcash/.zcash -cvf /home/zcash/.zcash/backup/chaindata.tgz blocks chainstate
echo "copying tarball to GCS" | logger
gsutil cp /home/zcash/.zcash/backup/chaindata.tgz gs://${gcloud_project}-chaindata
echo "removing tarball from local fs" | logger
rm -f /home/zcash/.zcash/backup/chaindata.tgz
echo "Chaindata backup completed" | logger
sleep 3
echo "starting zcashd" | logger
systemctl start zcashd.service
EOF
chmod u+x /root/backup.sh

# ---- Create rsync backup script
echo "Creating rsync chaindata backup script" | logger
cat <<'EOF' > /root/backup_rsync.sh
#!/bin/bash
# This script stops zcashd, and uses rsync to copy chaindata to GCS.
set -x

echo "Starting rsync chaindata backup" | logger
echo "Stopping zcashd" | logger
systemctl stop zcashd.service
sleep 5
echo "rsyncing .zcash to GCS" | logger
gsutil -m rsync -d -r /home/zcash/.zcash gs://${gcloud_project}-chaindata-rsync
echo "rsync chaindata backup completed" | logger
sleep 3
echo "starting zcashd" | logger
systemctl start zcashd.service
EOF
chmod u+x /root/backup_rsync.sh

# ---- Add backups to cron

cat <<'EOF' > /root/backup.crontab
# m h  dom mon dow   command
# backup full tarball once a day at 00:57
57 0 * * * /root/backup.sh | logger
# backup via rsync run every six hours at 00:17 past the hour
17 */6 * * * /root/backup_rsync.sh | logger
EOF
/usr/bin/crontab /root/backup.crontab

# ---- Create restore script
echo "Creating chaindata restore script" | logger
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
  echo "downloading chaindata from gs://${gcloud_project}-chaindata/chaindata.tgz" | logger
  gsutil cp gs://${gcloud_project}-chaindata/chaindata.tgz /home/zcash/.zcash/restore/chaindata.tgz
  echo "stopping zcashd to untar chaindata" | logger
  systemctl stop zcashd.service
  sleep 3
  echo "Deleting old chaindata" | logger
  rm -rf /home/zcash/.zcash/blocks/*
  rm -rf /home/zcash/.zcash/chainstate/*
  echo "untarring chaindata" | logger
  tar xvf /home/zcash/.zcash/restore/chaindata.tgz -I pigz --directory /home/zcash/.zcash
  echo "Setting perms on chaindata" | logger
  chown -R zcash:zcash /home/zcash/.zcash
  echo "removing chaindata tarball" | logger
  rm -rf /home/zcash/.zcash/restore/chaindata.tgz
  sleep 3
  echo "starting zcashd" | logger
  systemctl start zcashd.service
  else
    echo "No chaindata.tgz found in bucket gs://${gcloud_project}-chaindata, aborting warp restore" | logger
    echo "Starting zcashd" | logger
    systemctl start zcashd
  fi
EOF
chmod u+x /root/restore.sh

# ---- Create rsync restore script
echo "Creating rsync chaindata restore script" | logger
cat <<'EOF' > /root/restore_rsync.sh
#!/bin/bash
set -x

# test to see if chaindata exists in the rsync chaindata bucket
gsutil -q stat gs://${gcloud_project}-chaindata-rsync/blocks
if [ $? -eq 0 ]
then
  #chaindata exists in bucket
  echo "stopping zcashd" | logger
  systemctl stop zcashd.service
  echo "downloading chaindata via rsync from gs://${gcloud_project}-chaindata-rsync" | logger
  mkdir -p /home/zcash/.zcash
  gsutil -m rsync -d -r gs://${gcloud_project}-chaindata-rsync /home/zcash/.zcash
  echo "Setting perms on chaindata" | logger
  chown -R zcash:zcash /home/zcash/.zcash
  echo "starting zcashd" | logger
  sleep 3
  systemctl start zcashd.service
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

echo "Installing Zcash from debian package" | logger
sudo apt install -y apt-transport-https wget gnupg2
wget -qO - https://apt.z.cash/zcash.asc | gpg --import
gpg --export 3FE63B67F85EA808DE9B880E6DEF3BAF272766C0 | sudo apt-key add -
echo "deb [arch=amd64] https://apt.z.cash/ stretch main" | sudo tee /etc/apt/sources.list.d/zcash.list
apt update && apt install -y zcash

echo "Configuring zcashd systemd service" | logger
cat <<EOF >/etc/systemd/system/zcashd.service
[Unit]
Description=Zcashd
Requires=zcashd.service

[Service]
User=zcash
Group=zcash
ExecStart=/usr/bin/zcashd -printtoconsole
ExecStop=/usr/bin/zcash-cli stop
Restart=on-failure
RestartSec=30
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=zcashd

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zcashd.service

echo "Checking for existing paramaters" | logger
if [ -f /home/zcash/.zcash-params/sapling-output.params ] && [ -f sapling-spend.params ] && [ -f sprout-groth16.params ]; then
  echo "/home/zcash/.zcash-params exist, skipping params download" | logger
else
  echo "Fetching zcash params" | logger
  sudo -u zcash zcash-fetch-params
fi

echo "Checking for existing chaindata" | logger
if [ -d /home/zcash/.zcash/blocks ]; then
  echo "/home/zcash/.zcash/blocks directory exists, skipping chaindata restore"
  echo "Starting zcashd" | logger
  systemctl start zcashd
else
  echo "Restoring chaindata from GCS tarball, if available" | logger
  echo "Note that chaindata from GCS via rsync may be more fresh, and can be restored by running /root/restore_rsync.sh" | logger
  /root/restore.sh
fi