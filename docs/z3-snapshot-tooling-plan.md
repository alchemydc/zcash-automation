# Z3 Snapshot And Restore Tooling Plan

## Goal

Add z3-specific tooling that:

1. creates periodic snapshots of the persistent Zebra data disk after Zebra is stopped cleanly
2. restores a newly provisioned z3 data disk from the most recent matching snapshot when one exists

This plan is intentionally narrower than the original z3 module rollout plan. It focuses on the z3 data disk lifecycle, host-side operational tooling, and the IAM needed for the VM to manage Compute Engine snapshots.

## Current Baseline

The current z3 module in [gcp/terraform/modules/z3/main.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/main.tf) always creates a blank persistent disk and attaches it to each VM.

- the disk is created by `google_compute_disk.z3_data`
- the instance uses the default Compute Engine service account because the `service_account` block sets scopes only and does not set `email`
- the startup flow in [gcp/terraform/modules/z3/startup.sh](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/startup.sh) mounts and formats the data disk but does not create snapshots or restore from one

The repo already contains an older snapshot pattern in [gcp/terraform/modules/zebrad-archivenode/startup.sh](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/zebrad-archivenode/startup.sh) and snapshot-based restore in [gcp/terraform/modules/zcashd-fullnode/main.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/zcashd-fullnode/main.tf), but that pattern depends on deleting and recreating a fixed `-snapshot-latest` name and uses ad hoc cron jobs. For z3, the safer approach is to keep immutable timestamped snapshots and resolve the newest one at provisioning time.

## Recommended Design

## 1. Host-Side Snapshot Tooling

Extend [gcp/terraform/modules/z3/startup.sh](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/startup.sh) so it installs a dedicated snapshot helper on the VM.

### Files to drop on the host

- `/usr/local/bin/z3-create-data-snapshot`
- `/etc/systemd/system/z3-data-snapshot.service`
- `/etc/systemd/system/z3-data-snapshot.timer`

### Why systemd timer instead of cron

- matches the rest of the z3 host lifecycle, which is already systemd-based
- gives explicit service logs in journald
- is easier to start, stop, inspect, and override with `systemctl`
- avoids a second scheduling mechanism on the machine

### Helper script behavior

The helper should:

1. discover instance metadata needed for snapshot naming and API calls
2. determine the attached z3 data disk name and zone
3. stop Zebra cleanly before snapshotting
4. create a snapshot through the Compute Engine API
5. restart Zebra and report status
6. optionally prune old snapshots beyond a retention count

### Stop/start semantics

Prefer service-scoped container control rather than stopping the whole VM stack.

Recommended first pass:

- `cd /opt/z3`
- `docker compose stop zebra`
- wait for the container to stop cleanly
- perform the snapshot
- `docker compose start zebra`

This is sufficient for the current scope. Snapshotting Zaino state can be added later as a separate enhancement if needed.

### Snapshot creation mechanism

Prefer direct Compute Engine REST calls with `curl` plus the instance metadata token.

Why:

- no dependency on `gcloud` or `gsutil` on the host
- no large CLI install in the VM boot path
- uses the exact same instance service account identity that the VM already has
- makes required IAM permissions explicit

The script should:

- fetch an access token from the metadata server
- call `POST https://compute.googleapis.com/compute/v1/projects/$PROJECT/global/snapshots`
- pass `sourceDisk`, `name`, `labels`, and optionally `storageLocations`
- poll the returned operation until completion

`gsutil` is not required for Compute Engine snapshots. Startup should only install the Google Cloud CLI if the implementation later chooses to rely on `gcloud compute snapshots ...` for operator convenience.

### Snapshot naming and labels

Use immutable timestamped names rather than deleting and recreating one fixed snapshot.

Recommended name format:

- `${data_disk_name}-z3-${timestamp}`

Recommended labels:

- `managed-by = terraform`
- `stack = z3`
- `deployment = <deployment_name>`
- `network = <z3_network>`
- `role = zebra-data`
- `source-disk = <data_disk_name>`

This makes it straightforward to query the latest snapshot for one deployment and also lets multiple z3 deployments coexist in one project without colliding.

### Retention policy

Have the helper prune old snapshots after a successful create.

Recommended defaults:

- keep the newest `7` snapshots by default
- keep retention count configurable through Terraform

Pruning can use the same REST API path and should only delete snapshots that match the z3 deployment labels.

If a platform-managed retention policy can be applied cleanly to the z3 snapshot set, prefer that over host-managed deletion. Host-side pruning is an acceptable first implementation fallback if policy-based retention is awkward for the per-deployment design.

## 2. Terraform Restore Path

Update [gcp/terraform/modules/z3/main.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/main.tf) so the data disk is created from the newest matching snapshot when one is available, otherwise from blank storage.

### Required behavior

- if a suitable snapshot exists for the deployment, use it as the `snapshot` source for `google_compute_disk.z3_data`
- if no snapshot exists, create a blank disk exactly as today
- the restore path must be optional and non-failing for first-time deployments

### Discovery strategy

Use a Terraform `external` data source to resolve the latest snapshot before disk creation.

Why this is the best fit here:

- the built-in `google_compute_snapshot` data source fails if the snapshot does not exist
- z3 needs conditional behavior, not hard failure, for the bootstrap case
- the repo already depends on `gcloud` during operator bootstrap, so using it from Terraform-side discovery is acceptable

Suggested behavior for the external helper:

- call `gcloud compute snapshots list --project "$PROJECT" --filter ... --sort-by=~creationTimestamp --limit=1 --format=json`
- filter by the deployment labels or by a safe name prefix derived from `data_disk_name`
- emit `{"snapshot_name":"..."}` when found, otherwise `{"snapshot_name":""}`

Terraform can then set:

- `snapshot = local.z3_restore_snapshot_name != "" ? local.z3_restore_snapshot_name : null`

### Alternative if avoiding `external`

If local shell execution in Terraform is undesirable, expose a manual override variable such as `restore_snapshot_name` and make restore opt-in. This is simpler but loses the desired automatic “if available” behavior.

## 3. New z3 Module Inputs

Add module variables in [gcp/terraform/modules/z3/variables.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/variables.tf) and root wiring in [gcp/terraform/variables.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/variables.tf) and [gcp/terraform/main.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/main.tf).

Recommended inputs:

- `snapshot_enabled` default `true`
- `snapshot_schedule` default something like `weekly`
- `snapshot_timer_on_calendar` default something like `Sun *-*-* 04:20:00`
- `snapshot_retention_count` default `7`
- `restore_from_latest_snapshot` default `true`
- `snapshot_storage_locations` optional list

The root `z3_deployments` object can optionally gain per-deployment overrides for:

- `snapshot_enabled`
- `restore_from_latest_snapshot`
- `snapshot_retention_count`
- `snapshot_timer_on_calendar`

That keeps mainnet and testnet policies independent if needed.

Recommended defaults by network:

- mainnet: snapshots enabled, weekly cadence by default
- testnet: snapshots enabled, weekly cadence by default unless overridden
- regtest: snapshots disabled by default because the chain data is expendable

## 4. IAM And Service Account Changes

Because z3 instances use the default Compute Engine service account, the host-side snapshot helper needs permissions on that service account identity.

The existing bootstrap logic in [gcp/terraform/bootstrap.sh](/Users/dc/Projects/zcash-automation/gcp/terraform/bootstrap.sh) currently grants the default Compute Engine service account only logging and monitoring roles. That is not enough for snapshots.

### Minimum permissions needed by the VM

For create-only snapshots:

- `compute.disks.createSnapshot`
- `compute.snapshots.create`
- `compute.snapshots.get`
- `compute.snapshots.list`
- `compute.globalOperations.get`

For retention cleanup as well:

- `compute.snapshots.delete`

### Recommended first implementation

Grant `roles/compute.storageAdmin` to the default Compute Engine service account in `bootstrap.sh`.

Why:

- it covers disk and snapshot management cleanly
- it is straightforward to apply in the current bootstrap pattern
- it avoids blocking implementation on a custom-role rollout

The project default Compute Engine service account remains the intended identity for z3 VMs. A dedicated z3-specific VM service account is not required for this feature.

### Longer-term hardening option

Replace `roles/compute.storageAdmin` with a custom project role limited to the exact snapshot operations above once the feature is proven.

### Scope requirements

No additional OAuth scope change should be required because [gcp/terraform/variables.tf](/Users/dc/Projects/zcash-automation/gcp/terraform/variables.tf) already gives instances the `cloud-platform` scope.

## 5. Startup Script Changes

The z3 startup path should be extended in a separate helper phase, not merged into the main provisioning logic.

Recommended additions to [gcp/terraform/modules/z3/startup.sh](/Users/dc/Projects/zcash-automation/gcp/terraform/modules/z3/startup.sh):

1. add helper functions for metadata access and JSON API calls
2. add an `install_snapshot_tooling()` phase after Docker and repo setup
3. write the snapshot script and systemd unit files
4. enable the timer only when `snapshot_enabled = true`
5. keep the provisioning-complete marker logic unchanged

This should remain idempotent so re-running startup on reboot does not recreate or duplicate timers unnecessarily.

## 6. Restore-Time Safety Checks

When restoring from snapshot, the module should avoid accidental cross-deployment restores.

The discovery logic should match on at least:

- deployment name
- z3 network
- source disk label or exact disk-name prefix

It should not restore from:

- a snapshot belonging to a different z3 deployment
- a snapshot created for a different blockchain network
- a snapshot whose disk size exceeds the requested target disk size

The plan should either:

- require `data_disk_size` to be greater than or equal to the source snapshot size, or
- normalize the requested disk size upward to the snapshot size when restoring

The first option is simpler and more explicit.

## 7. Recommended Implementation Sequence

1. Add bootstrap IAM for the default Compute Engine service account.
2. Add z3 Terraform variables for snapshot schedule, retention, and restore behavior.
3. Add the Terraform-side snapshot discovery helper and conditional disk restore logic.
4. Extend z3 startup to install the snapshot helper, service, and timer.
5. Test first-boot behavior with no snapshots present.
6. Run the snapshot helper manually on an existing z3 host and verify Zebra stops, snapshot completes, and Zebra restarts.
7. Re-provision a z3 deployment and verify the data disk is created from the discovered snapshot.

## 8. Validation Checklist

The work is complete when all of the following are true:

- a z3 VM has a runnable host command for creating a data snapshot
- the host can create a snapshot without manual credentials or SSH session-local auth
- Zebra is stopped and restarted cleanly during the snapshot window
- old snapshots are retained according to policy
- a brand-new z3 deployment creates its data disk from the newest matching snapshot when one exists
- a first-ever z3 deployment still succeeds when no snapshot exists
- `bootstrap.sh` grants the required snapshot privileges to the service account actually used by z3 instances

## 9. Resolved Decisions

- Snapshot cadence should be configurable per deployment, with a weekly default.
- Regtest snapshots should be disabled by default.
- `docker compose stop zebra` is sufficient for the current snapshot boundary.
- Prefer retention by policy if it fits the implementation cleanly; otherwise host-side pruning is acceptable.
- The project default Compute Engine service account remains the VM identity for z3.

## Recommendation Summary

The cleanest first implementation is:

- host-side snapshot creation via `curl` to the Compute Engine API using metadata-server credentials
- scheduling via a per-deployment-configurable systemd timer, with a weekly default and regtest disabled by default
- immutable timestamped snapshots with labels, not delete-and-recreate `-latest` snapshots
- Terraform restore via a conditional lookup of the newest matching snapshot
- `roles/compute.storageAdmin` added in `bootstrap.sh` to the default Compute Engine service account used by z3 instances

That gets automatic backup and fast restore without pulling the full Google Cloud CLI into the z3 boot path and without making first-time deployment depend on a snapshot already existing.