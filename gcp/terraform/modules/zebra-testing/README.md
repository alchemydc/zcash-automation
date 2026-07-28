# zebra-testing Terraform Module

This module provisions one or more Zebra testing nodes on GCE.

- Two install modes, selected per deployment: by default Zebra is installed from the official checksum-verified release binaries published at https://github.com/ZcashFoundation/zebra/releases (`zebra_release_tag` pins a version; `"latest"` resolves the newest release at boot). Setting `zebra_repo_ref` or `zebra_git_fetch_ref` builds from a configurable git repository and ref instead, including forks and explicit PR refs; the source ref wins and `zebra_release_tag` is ignored.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is restored by creating the persistent data disk from a snapshot.
- The JSON-RPC endpoint is enabled by default on `127.0.0.1:8232` with cookie authentication disabled. It is localhost-only: the port is not opened in the host firewall or any GCP firewall rule. Set `rpc_listen_addr = ""` to disable it.
- Shell helpers for the RPC endpoint (`zebra-sync`, `zebra-peers`, `zebra-block`, the generic `zebra-rpc <method>`, and more) are installed to `/etc/profile.d/zebra-rpc.sh` and available in any interactive shell (login and non-login, via an `/etc/bash.bashrc` hook); run `zebra-rpc-help` for the full list. On already-provisioned hosts they appear after the next reboot or a manual `sudo google_metadata_script_runner startup`.
- Each node advertises its reserved public IP to the P2P network via `ZEBRA_NETWORK__EXTERNAL_ADDR` (Zebra never advertises the unspecified `0.0.0.0` listen address, and behind GCE NAT it cannot discover its own public IP), so it accepts inbound peer connections on the P2P port.
- Recurring snapshot creation is disabled by default for this module.