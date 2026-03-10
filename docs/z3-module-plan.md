# Z3 GCP Module Plan

## Goal

Add a new `z3` Terraform module to the GCP automation in this repository, reusing the stronger bootstrap and VM provisioning patterns from the vote-server infrastructure while fitting the current module layout under `gcp/terraform`.

This plan is scoped to the following outcomes:

1. Upgrade `bootstrap.sh` so it can initialize either a new GCP project or an existing one.
2. Install Docker on the provisioned VM.
3. Clone the `z3` repository during startup.
4. Install runtime and build dependencies, including `rage`.
5. Provision and mount a separate persistent data disk for large Zebra data volumes.

## External Pattern Source

The vote-server GCP automation provides the main reference pattern for this work:

- bootstrap supports existing-project onboarding as well as new-project creation
- short-lived impersonated access tokens are refreshed by sourcing `gcloud.env`
- startup configuration is broken into clear phases with strong logging and idempotent install steps
- repo checkout and update logic is handled on the VM, not pre-baked into the image
- security and operational tooling are installed early in the startup flow

## Current Local Baseline

The current GCP Terraform code already has a useful shape for `z3`:

- `gcp/terraform/main.tf` already instantiates node-specific modules
- `gcp/terraform/variables.tf` already models per-module replica counts and instance types
- `gcp/terraform/modules/zebrad-archivenode` already provisions separate persistent disks and mounts them in `startup.sh`

That means the `z3` module should follow the `zebrad-archivenode` structure rather than introducing a completely new Terraform pattern.

## Proposed Architecture

## 1. Bootstrap Refactor

Refactor `gcp/terraform/bootstrap.sh` into a mode-driven bootstrap script.

### Required behavior

- If `TF_VAR_project` does not exist, create it, link billing, create the terraform service account, enable APIs, and create the state bucket.
- If `TF_VAR_project` already exists, skip project creation and billing setup, then ensure the terraform service account, IAM bindings, APIs, token refresh line, and optional state bucket are present.
- Keep support for both `terraform` and `tofu`.
- Preserve the current `gcloud.env` workflow, but generate it from a template that is safe for both new and existing projects.

### Concrete changes

- Add a `project_exists()` helper using `gcloud projects describe`.
- Add an `ensure_service_account()` helper instead of assuming creation is always required.
- Add an `ensure_project_iam_bindings()` loop that is safe to re-run.
- Add an `ensure_required_apis()` loop that is safe to re-run.
- Add an `ensure_state_bucket()` helper that only creates the bucket and `backend.tf` if they do not already exist.
- Generate or update the short-lived token export line in `gcloud.env` without duplicating it.
- Detect and reuse the default Compute Engine service account for the project instead of assuming a fresh project lifecycle.

### Bootstrap design decisions

- Do not require a separate script for existing projects; one script with idempotent helpers is simpler.
- Keep the service-account impersonation model from vote-server. It is materially better than managing long-lived keys.
- Keep the current `gcloud.env` approach because it already matches how this repo expects Terraform credentials to be sourced.

## 2. New `z3` Terraform Module

Add a new module at `gcp/terraform/modules/z3`.

### Suggested file set

- `gcp/terraform/modules/z3/main.tf`
- `gcp/terraform/modules/z3/variables.tf`
- `gcp/terraform/modules/z3/outputs.tf`
- `gcp/terraform/modules/z3/startup.sh`
- `gcp/terraform/modules/z3/README.md`

### Suggested Terraform resources

- one static external IP if the service must be reachable publicly
- one static internal IP in the existing subnetwork
- one boot disk from the configured Debian image
- one persistent repo or app disk only if needed later
- one dedicated persistent Zebra data disk sized for chain growth
- one `google_compute_instance` using `metadata_startup_script = templatefile(...)`

### Root module integration

Update `gcp/terraform/variables.tf`:

- add `z3 = 0` to `replicas`
- add `z3` instance type entry to `instance_types`
- add `z3_repo_url`
- add `z3_repo_ref`
- add `z3_data_disk_name`
- add `z3_data_disk_size`
- add any `z3`-specific ports or feature toggles

Update `gcp/terraform/main.tf`:

- instantiate `module "z3"`
- pass shared network, project, region, zone, service-account, image, and subnetwork variables
- pass the new `z3` repository and disk variables
- add firewall rules only for ports that actually need inbound access

## 3. Startup Script Design

The `z3` startup script should use the vote-server style of explicit phases, logging, and idempotent installs.

### Recommended phase order

1. Install base packages and logging agents.
2. Install Docker.
3. Create the service user.
4. Format and mount the Zebra data disk.
5. Install Rust and native build dependencies.
6. Install `rage`.
7. Clone or update the `z3` repository.
8. Install application dependencies.
9. Write systemd units and environment files.
10. Start or enable services.

### Startup script requirements

- use `set -euo pipefail`
- log each major phase through `logger` and a local log file
- make all install steps safe to re-run
- avoid formatting disks that are already formatted correctly
- clone the repo if absent, otherwise fetch and check out the target ref
- avoid assuming an interactive shell profile is loaded

### Docker installation

Install Docker explicitly rather than relying on distro defaults.

Preferred approach:

- install Docker Engine from Docker's Debian repository
- enable and start `docker.service`
- add the application user to the `docker` group only if the runtime genuinely needs non-root Docker access

This is preferable to a minimal `apt install docker.io` because it is closer to the vote-server pattern of explicit, versionable dependencies.

## 4. Repo Checkout And Dependency Installation

The `z3` startup script should manage source checkout in an idempotent way.

### Recommended repo logic

- clone `${z3_repo_url}` into `/opt/z3` if the directory does not exist
- if the directory exists, run `git fetch --tags origin`, `git checkout ${z3_repo_ref}`, and `git pull --ff-only`
- ensure ownership is set to the application user after clone or update

### Dependencies to install

Base packages:

- `git`
- `curl`
- `jq`
- `build-essential`
- `pkg-config`
- `libssl-dev`
- `clang`
- `llvm`
- any repo-specific native libraries discovered from the `z3` build instructions

Rust toolchain:

- install via `rustup`
- source the cargo environment explicitly in non-interactive shell contexts

`rage`:

- prefer `cargo install rage` if the repo expects the Rust implementation
- if the repo depends on a packaged binary with a pinned version, install that exact release instead

The exact `rage` installation method should be validated against the `z3` repository instructions before implementation. The Terraform plan should expose a version variable if the tool is operationally important.

## 5. Separate Data Disk Strategy

The large-volume requirement maps cleanly onto the existing Zebra pattern in this repo.

### Terraform pattern

- create a dedicated persistent disk such as `${var.z3_data_disk_name}`
- attach it to the VM as a separate data disk
- mount it to the path where Zebra stores chain state

### Startup script pattern

- locate the disk with `/dev/disk/by-id/google-${z3_data_disk_name}`
- check filesystem type before formatting
- format as `ext4` if needed
- mount using `UUID=` in `/etc/fstab`
- use mount options suitable for large, frequently written data volumes such as `defaults` and optionally `noatime`
- set ownership for the service user after mount

### Path decision

The mount point should be whichever path `z3` uses for Zebra state. If `z3` delegates to Zebra defaults, mount directly onto the service user's Zebra cache or state directory. If `z3` supports an explicit data directory, prefer a dedicated path such as `/var/lib/z3/zebra` and point the app there.

## 6. Security And Operations

Reuse the stronger operational stance from vote-server where it fits.

### Apply now

- install Google Ops Agent during startup
- make SSH access explicit instead of assumed
- only expose public ports that are needed by `z3`
- prefer idempotent systemd setup and deterministic repo refs

### Defer unless required for first pass

- Tailscale integration
- cleanup script parity with vote-server
- snapshot schedules for the `z3` data disk
- aggressive SSH hardening and fail2ban

These are good follow-up items, but they are not required to land the initial `z3` module.

## 7. Implementation Sequence

Recommended order of work:

1. Refactor `bootstrap.sh` for idempotent new-project or existing-project initialization.
2. Add root Terraform variables and module wiring for `z3`.
3. Create the `gcp/terraform/modules/z3` Terraform resources using the zebrad module as the base template.
4. Implement `modules/z3/startup.sh` with phased logging, Docker install, repo clone, dependency install, and data-disk mount.
5. Add minimal documentation for configuration inputs and startup behavior.
6. Run `terraform validate` and test against an existing non-production GCP project.

## 8. Open Questions Before Implementation

These should be answered from the `z3` repository before coding the startup script:

- What is the canonical `z3` repository URL?
- Which branch, tag, or commit should the automation pin by default?
- Does `z3` run as a binary, a container, or both?
- What exact native packages are required to build or run it?
- Where does it store Zebra chain state by default?
- Does it require any secrets, age keys, or `rage` workflows at boot time?
- Which ports, if any, must be publicly reachable?

## 9. Acceptance Criteria

The work is complete when:

- `bootstrap.sh` can be run safely against both a new project and an existing project
- Terraform can enable a `z3` replica through the root `replicas` map
- the `z3` VM installs Docker and all required dependencies automatically
- the `z3` repo is cloned or updated at boot to a configured ref
- `rage` is installed and available in the VM path
- a dedicated persistent data disk is mounted to the Zebra data path and survives reboots
- the VM comes up with a reproducible systemd-managed `z3` runtime

## 10. Recommended First Implementation Defaults

Unless the `z3` repository says otherwise, start with:

- OS image: Debian 12, to stay aligned with the existing repo
- machine type: `e2-standard-4`
- boot disk: `20GB`
- `z3` data disk: `500GB`
- disk type: `pd-standard` initially, upgrade to `pd-ssd` only if sync or runtime IOPS demand it
- `z3_repo_ref`: a pinned tag or commit, not a floating branch, for production use

This keeps the first implementation close to the existing repo while still adopting the strongest operational improvements from vote-server.