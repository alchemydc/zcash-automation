# z3 Terraform Module

This module provisions a GCE VM for the Z3 stack and configures it during startup to:

- install Docker Engine and the Docker Compose plugin
- clone the z3 repository
- install `rage` and `rage-keygen`
- provision and mount a dedicated persistent data disk for Zebra chain state
- build the required container images
- start the initial Zebra-only sync phase via systemd

## Provisioning Behavior

On first boot the startup script performs the repo's documented production flow:

1. mount the persistent disk at the configured Zebra data path
2. clone and update the z3 repo under `/opt/z3`
3. generate TLS certificates for Zaino if they do not exist
4. generate `config/zallet_identity.txt` with `rage-keygen` if it does not exist
5. build the required Docker images for Zaino and Zallet
6. start only Zebra so it can complete the initial sync

Once Zebra is near tip, operators can bring up the full stack with:

```console
sudo systemctl start z3-stack.service
```

Or with the convenience wrapper:

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