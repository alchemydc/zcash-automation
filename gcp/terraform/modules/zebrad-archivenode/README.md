# zebrad-archivenode Terraform Module

This module provisions one or more Zebra archive nodes on GCE.

- Zebra is installed from the official checksum-verified release binaries published at https://github.com/ZcashFoundation/zebra/releases. `zebra_release_tag` pins a version (e.g. `"v6.2.3"`); the default `"latest"` resolves the newest published release at boot.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is stored on a dedicated persistent disk.
- The JSON-RPC endpoint is enabled by default on `127.0.0.1:8232` with cookie authentication disabled. It is localhost-only: the port is not opened in the host firewall or any GCP firewall rule. Set `rpc_listen_addr = ""` to disable it.
- Shell helpers for the RPC endpoint (`zebra-sync`, `zebra-peers`, `zebra-block`, the generic `zebra-rpc <method>`, and more) are installed to `/etc/profile.d/zebra-rpc.sh` and available in any interactive shell (login and non-login, via an `/etc/bash.bashrc` hook); run `zebra-rpc-help` for the full list. On already-provisioned hosts they appear after the next reboot or a manual `sudo google_metadata_script_runner startup`.
- Each node advertises its reserved public IP to the P2P network via `ZEBRA_NETWORK__EXTERNAL_ADDR` (Zebra never advertises the unspecified `0.0.0.0` listen address, and behind GCE NAT it cannot discover its own public IP), so it accepts inbound peer connections on the P2P port.
- Snapshotting is handled by a host-side systemd timer; GCS tarball and rsync backups are not used.
