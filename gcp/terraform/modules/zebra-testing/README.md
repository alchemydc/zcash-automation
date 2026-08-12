# zebra-testing Terraform Module

This module provisions one or more Zebra testing nodes on GCE.

- Two install modes, selected per deployment: by default Zebra is installed from the official checksum-verified release binaries published at https://github.com/ZcashFoundation/zebra/releases (`zebra_release_tag` pins a version; `"latest"` resolves the newest release at boot). Setting `zebra_repo_ref` or `zebra_git_fetch_ref` builds from a configurable git repository and ref instead, including forks and explicit PR refs; the source ref wins and `zebra_release_tag` is ignored.
- Runtime configuration is managed primarily via `ZEBRA_*` environment variables in a systemd environment file.
- Chain state is restored by creating the persistent data disk from a snapshot.
- The JSON-RPC endpoint is enabled by default on `127.0.0.1:8232` with cookie authentication disabled. It is localhost-only: the port is not opened in the host firewall or any GCP firewall rule. Set `rpc_listen_addr = ""` to disable it.
- Shell helpers for the RPC endpoint (`zebra-sync`, `zebra-peers`, `zebra-block`, the generic `zebra-rpc <method>`, and more) are installed to `/etc/profile.d/zebra-rpc.sh` and available in any interactive shell (login and non-login, via an `/etc/bash.bashrc` hook); run `zebra-rpc-help` for the full list. On already-provisioned hosts they appear after the next reboot or a manual `sudo google_metadata_script_runner startup`.
- Each node advertises its reserved public IP to the P2P network via `ZEBRA_NETWORK__EXTERNAL_ADDR` (Zebra never advertises the unspecified `0.0.0.0` listen address, and behind GCE NAT it cannot discover its own public IP), so it accepts inbound peer connections on the P2P port.
- Recurring snapshot creation is disabled by default for this module.

## Source-build flags

These apply only in source mode (`zebra_repo_ref` or `zebra_git_fetch_ref` set) and are ignored when installing a release binary.

| Variable | Default | Purpose |
| --- | --- | --- |
| `cargo_build_features` | `"prometheus"` | Value passed to `--features` for the `zebrad` build. Set to `""` to omit `--features` entirely, which is what you want when `cargo_build_args` already carries `--all-features`. |
| `cargo_build_args` | `""` | Appended verbatim to the `cargo build` invocation and word-split by the shell, e.g. `"--all-features"`. |
| `fuzz_build` | `false` | Also build the `cargo-fuzz` harnesses after the `zebrad` build. |
| `fuzz_build_args` | `""` | Appended to `cargo +nightly fuzz build`, e.g. `"-O"` for the release + ASan mode OSS-Fuzz uses. |
| `fuzz_dir` | `"zebra-fuzz/fuzz"` | Fuzz directory relative to the repository root. |

Notes:

- The `zebrad` build always includes `--bin zebrad`, so `cargo_build_args` narrows or extends that build rather than replacing it. This module builds a node; it is not a general-purpose `cargo` runner.
- `fuzz_build` installs a **nightly** toolchain and `cargo-fuzz` on first use, because libFuzzer's sanitizers need `-Z` flags. The `zebrad` build stays on stable. The install is guarded by its own marker file, so it happens once per host.
- `zebra-fuzz/fuzz` declares its own `[workspace]` and its own `Cargo.lock`, so it is never built by the root `cargo build`; it needs the explicit `--fuzz-dir` invocation this flag adds.
- If `fuzz_dir` does not exist at the checked-out ref, the fuzz build logs and skips rather than failing the startup script.
- A build that produces no `zebrad` binary no longer aborts provisioning: the install and `systemctl restart zebrad.service` steps are skipped and logged, leaving a build-only box.

## Sizing

`instance_type` and `boot_disk_size` are settable per deployment in the root `zebra_testing_deployments` map (both default to the global values when omitted). The git checkout and its `target/` directory live on the **boot disk**, not the persistent state disk, so a full-feature or fuzz build needs a much larger boot disk than the 20 GB global default — 15 fuzz targets built with ASan produce a large `target/` tree.