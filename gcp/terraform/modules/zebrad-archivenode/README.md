# zebrad-archivenode Terraform Module

This module provisions one or more source-built Zebra archive nodes on GCE.

- Zebra is cloned from a configurable git repository and ref.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is stored on a dedicated persistent disk.
- Snapshotting is handled by a host-side systemd timer; GCS tarball and rsync backups are not used.
