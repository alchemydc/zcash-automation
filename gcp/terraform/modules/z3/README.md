# z3 Terraform Module

This module provisions a GCE VM for the Z3 stack and configures it during startup to:

- install Docker Engine and the Docker Compose plugin
- configure Docker to use the `journald` log driver by default
- clone the z3 repository
- install `rage` and `rage-keygen`
- optionally install a Rust toolchain (`rustup`, `cargo`, `rustfmt`, `clippy`) for the `z3` app user (off by default; only needed for the opt-in source-build overlay)
- provision and mount a dedicated persistent data disk for Zebra chain state
- pull the pinned container images
- start the initial Zebra-only sync phase via systemd

## Provisioning Behavior

On first boot the startup script drives upstream z3's documented production flow:

1. mount the persistent disk and point Zebra chain state at it via
   `Z3_CHAIN_DATA_PATH` (written to the gitignored `/opt/z3/.env`)
2. clone and update the z3 repo under `/opt/z3`
3. run `scripts/setup-network.sh <network>` to materialize the per-network
   config (`config/<network>/zaino.toml`, `zallet.toml`, regtest `zebra.toml`)
   and generate the Zallet identity (`config/<network>/zallet_identity.txt`)
   with `rage-keygen`
4. pull the pinned Zebra/Zaino/Zallet images (no local image build; source
   builds are an opt-in upstream overlay)
5. start only Zebra so it can complete the initial sync

Network selection is by env file: every compose invocation uses
`--env-file .env.<network> --env-file .env`, layering the host's
`Z3_CHAIN_DATA_PATH` override on top of the committed per-network env file.

Once Zebra is near tip, operators can bring up the full stack with the
convenience wrapper:

```console
sudo /usr/local/bin/z3-start-full-stack
```

## SSH and VS Code Remote Access

This module is configured for direct SSH login as the shared `z3` app user so operators can use VS Code Remote-SSH without sudo user switching.

- OS Login is disabled for this module's VM instances.
- Project-wide SSH keys are blocked at the instance level.
- SSH firewall access for `z3` is restricted to Google IAP TCP forwarding (`35.235.240.0/20`).
- Operators should connect through IAP and add/manage keys with `gcloud compute ssh`.
- The z3 P2P port remains publicly exposed on the instance public IP via the `z3-firewall` rule.

Example first connection:

```console
gcloud compute ssh z3@z3-0 --project YOUR_PROJECT --zone YOUR_ZONE --tunnel-through-iap
```

Example SSH config entry for VS Code Remote-SSH:

```sshconfig
Host z3-0
	HostName z3-0
	User z3
	IdentityFile ~/.ssh/google_compute_engine
	ProxyCommand gcloud compute start-iap-tunnel z3-0 22 --listen-on-stdin --project YOUR_PROJECT --zone YOUR_ZONE
```

Security tradeoff: using a shared Unix user improves operator ergonomics in VS Code but reduces per-user Unix-level audit attribution.

## Optional Rust Toolchain

Set `install_rust_toolchain = true` to install a working Rust environment for the `z3` app user during startup.

- includes `rustup`, `cargo`, stable toolchain, `rustfmt`, and `clippy`
- setup is idempotent and skipped when disabled