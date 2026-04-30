# zebra-testing Terraform Module

This module provisions one or more source-built Zebra testing nodes on GCE.

- Zebra is cloned from a configurable git repository and ref, including explicit PR refs.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is restored by creating the persistent data disk from a snapshot.
- Recurring snapshot creation is disabled by default for this module.