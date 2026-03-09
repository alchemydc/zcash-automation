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