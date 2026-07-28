# zebra-testing Terraform Module

This module provisions one or more Zebra testing nodes on GCE.

- Two install modes, selected per deployment: by default Zebra is installed from the official checksum-verified release binaries published at https://github.com/ZcashFoundation/zebra/releases (`zebra_release_tag` pins a version; `"latest"` resolves the newest release at boot). Setting `zebra_repo_ref` or `zebra_git_fetch_ref` builds from a configurable git repository and ref instead, including forks and explicit PR refs; the source ref wins and `zebra_release_tag` is ignored.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is restored by creating the persistent data disk from a snapshot.
- Recurring snapshot creation is disabled by default for this module.