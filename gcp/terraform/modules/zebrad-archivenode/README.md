# zebrad-archivenode Terraform Module

This module provisions one or more source-built Zebra archive nodes on GCE.

- Zebra is cloned from a configurable git repository and ref.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is stored on a dedicated persistent disk.
- The JSON-RPC endpoint is enabled by default on `127.0.0.1:8232` with cookie authentication disabled. It is localhost-only: the port is not opened in the host firewall or any GCP firewall rule. Set `rpc_listen_addr = ""` to disable it.
- Snapshotting is handled by a host-side systemd timer; GCS tarball and rsync backups are not used.
