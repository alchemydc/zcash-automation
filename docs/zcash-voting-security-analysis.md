# Zcash Vote Validator — Security Analysis

This document covers the security trade-offs in the `zcash-vote-validator` Terraform module, which deploys CometBFT-based vote validator nodes for the Zcash on-chain voting system. The upstream setup instructions (by hhanh00) assume a manual install on a bare VM. We productionized this into a Terraform module with systemd and journald, but several risks remain.

## A. Supply chain risks — `vote-cometbft` binary

The `vote-cometbft` binary is downloaded directly from GitHub releases with no checksum or signature verification. The source repository (`github.com/hhanh00/zcv`) is a personal repo, not an org-maintained project. There is no reproducible build process documented.

**Mitigation (applied):** We pin to a specific release tag (`zcv_release_tag` variable) rather than `latest`.

**Recommendation:** Verify SHA256 of the downloaded binary against a known-good hash. Ideally, build from source with pinned dependencies.

## B. Supply chain risks — `install.sh`

The original upstream approach downloads and executes a shell script from GitHub (`install.sh`), which in turn downloads and runs binaries from GitHub releases without integrity checks.

**Mitigation (applied):** We do NOT execute `install.sh`. We inlined its logic into our `startup.sh`, pinned to a specific release tag, and can audit every step.

## C. Process management and logging

The upstream setup uses `nohup` and `pkill` — no supervision, no automatic restart, no structured logging. Logs go to a file (`vote.log`) with no rotation, which will fill the disk over time. `pkill cometbft` is a broad pattern match that could kill unrelated processes.

**Mitigation (applied):** We use systemd services (`cometbft.service`, `vote-cometbft.service`) with journald logging, automatic restart on failure, and proper process supervision.

**Remaining gap:** The `vote-cometbft` binary's internal logging format and verbosity are unknown and not configurable by us.

## D. Network exposure

CometBFT RPC (26657) and gRPC (9010) listen on all interfaces by default.

**Mitigation (applied):** No public IP. No GCP firewall rules expose any ports. All p2p peering happens over Tailscale. SSH is restricted to IAP tunnel only (`35.235.240.0/20`).

**Remaining consideration:** Tailscale ACLs should restrict which tailnet nodes can reach ports 26656, 26657, and 9010.

## E. Binary provenance and trust

`vote-cometbft` is a minimally-documented binary from a personal GitHub account. There is no audit trail for what the binary does at runtime. It runs with full user permissions and could exfiltrate data or open network connections.

**Accepted risk:** Trusted based on the author's standing in the Zcash community and time pressure for the voting system deployment.

## F. CometBFT configuration

The default `config.toml` has permissive settings (e.g., RPC listening on `0.0.0.0`). The validator key (`priv_validator_key.json`) is stored unencrypted on disk.

**Recommendation:** Restrict RPC listen address to `127.0.0.1`. Back up the validator key securely and consider encrypting at rest.

## G. Tailscale auth key handling

The auth key is passed as a Terraform variable and ends up in the instance's startup script metadata. GCP metadata is readable by anyone with `compute.instances.get` permission on the project.

**Recommendation:** Use a short-lived, single-use Tailscale auth key. Rotate after provisioning. Consider using GCP Secret Manager instead of instance metadata.

## H. Recommendations for future hardening

- Build `vote-cometbft` from source with pinned dependencies
- Add SHA256 checksum verification for all downloaded binaries
- Restrict CometBFT RPC bind address to localhost
- Add monitoring and alerting for service health
- Consider running services in a more restricted sandbox (dedicated user with limited capabilities, seccomp profiles)
- Implement log-based alerting for consensus failures
- Use Tailscale ACLs to restrict port access between nodes
- Move Tailscale auth key to GCP Secret Manager
