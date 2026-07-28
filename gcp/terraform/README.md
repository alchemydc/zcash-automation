# Terraform for running Zcash infrastructure in GCP

## Overview
This folder provides Terraform code that will create a new dedicated project in [Google Cloud Platform](https://cloud.google.com/), and provision and configure a full nodes running the latest releases of [Zcashd](https://github.com/zcash/zcash) and [Zebrad](https://github.com/ZcashFoundation/zebra).

[Terraform](https://www.terraform.io) is a tool by Hashicorp that allows developers to treat _"infrastructure as code"_, which makes the management and repeatibility of the infrastructure much easier.  

Infrastructure and all kinds of cloud resources (such as firewalls, and cloud storage buckets) are defined in modules, and Terraform creates/changes/destroys resources when changes are applied.

Support for GCP's Stackdriver platform has been enabled, which makes it easy to get visibility into how your Zcash infrastructure is performing.

## Quick start
1. Clone this repo
  ```console
  git clone https://github.com/alchemydc/zcash-automation.git
  ```
2. Install dependencies
   * OSX
     (assumes [Brew](https://brew.sh/) is installed):
     ```console
     brew update && brew install terraform google-cloud-sdk
     ```

   * Linux
     * Install [Google Cloud SDK](https://cloud.google.com/sdk/docs/install#linux)

     * Install Terraform:
        ```console
        sudo apt update && sudo apt install terraform
        ```

3. Authenticate the gcloud SDK
    ```console
    gcloud auth login
    ```
    This will spawn a browser window and use Oauth to authenticate the gcloud sdk to your GCP account.  Note that your account must have (at a minimum), permissions to create a new project in your GCP organization.

    You must also ensure that the GCP user you are logging in with to bootstrap the project has permission to create new projects in your GCP org, and also has the `roles/iam.serviceAccountTokenCreator` role as this is needed to create the temporary access tokens that will be used by terraform/opentofu.

4. Run bootstrap.sh
   ```console
    ./bootstrap.sh
   ```
    This will create a template gcloud.env for you, which will store environment variables specific to your GCP organization.

5. Edit gcloud.env and set
    * 'TF_VAR_project' to the name of the GCP project to create
    * 'TF_VAR_org_id' to your gcloud org ID, which can be found by running `gcloud organizations list`
    * 'TF_VAR_billing_account' to your gcloud billing account, which can be found by running `gcloud beta billing accounts list`
    * 'TF_VAR_region' to the gcloud region you want to use. You can enumerate regions by running `gcloud compute regions list`
    * 'TF_VAR_zone' to the gcloud zone you want to use. You can enumerate zones by running `gcloud compute zones list`

6. Run bootstrap.sh again to initialize your new GCP project or prepare an existing one and enable appropriate API's
    ```console
    ./bootstrap.sh
    ```

    For an existing project, set `TF_VAR_project`, `TF_VAR_region`, and `TF_VAR_zone` in `gcloud.env` and re-run `./bootstrap.sh`. `TF_VAR_org_id` and `TF_VAR_billing_account` are only required when the script needs to create a new project.

    Note that when this completes, you need to `source gcloud.env` again in order to import the impersonated access token and the default compute service account which Terraform will use.

7. Initialize terraform
    `terraform init`

    By default this repo now uses a local backend and stores state in `terraform.tfstate` in the working directory. `bootstrap.sh` also defaults to `TF_BACKEND=local`. If you explicitly switch `TF_BACKEND` to `gcs`, bootstrapping will create and configure a GCS-backed remote state bucket instead.

    If you are converting an existing checkout from the older GCS backend to the local backend, migrate the previous remote state before applying. For the historical default bucket this can be done with `gsutil cp gs://z3-dev-17-tfstate/terraform/state/default.tfstate terraform.tfstate`, after first backing up any existing local `terraform.tfstate`.

8. Enable optional node types
    Zcashd node types are enabled via the `replicas` variable, and Zebra/z3 node types via the `zebrad_archivenode_deployments`, `zebra_testing_deployments`, and `z3_deployments` maps in `terraform.tfvars`. All node types are disabled by default. A description of each of the [available infrastructure types](#available-infrastructure) is below.

9. Use terraform to deploy Zcash infrastructure
    `terraform apply`

    Once the Terraform apply completes in your terminal, you can see progress in the [Google Cloud Logs Explorer](https://console.cloud.google.com/logs/).  Make sure you select the right project, and click on "Stream logs" for realtime progress.
    

## Blockchain synchronization
Zcash chain state is synchronized over the peer to peer (p2p) network and can take a substantial amount of time to build from scratch. The Zebra modules in this repo now rely on persistent disks and Compute Engine snapshots rather than GCS tarball or rsync backups. The intended workflow is to let a long-lived archive node maintain fresh chain state and publish snapshots, then restore those snapshots into other nodes that should come up quickly.

## Zebra Roles
The repo now has two distinct Zebra roles with different operational goals:

* `zebrad-archivenode`: the long-lived baseline node. It installs the official zebrad release binary (checksum-verified) from [GitHub releases](https://github.com/ZcashFoundation/zebra/releases), runs with env-first configuration via `ZEBRA_*` variables, keeps chain state on a dedicated persistent disk, and cuts recurring snapshots of that disk on a systemd timer.
* `zebra-testing`: the disposable validation node. It can restore its persistent state disk from a snapshot and is intended for branch and PR testing. By default it installs the official release binary; setting a git ref switches it to building Zebra from source (required for forks, branches, and PRs, which have no published binaries). It does not publish recurring snapshots of its own.

In practice, the archive node is what keeps the snapshot pipeline warm. The testing node is what you point at a candidate branch or PR once you already have a usable archive snapshot.

Both roles are configured through per-deployment maps in `terraform.tfvars`:

* `zebrad_archivenode_deployments`: one entry per network (e.g. `mainnet`, `testnet`). Each entry sets its own `replicas`, `data_disk_name`, `data_disk_size`, `hostname_prefix`, and optionally `zebra_release_tag` (defaulting to `latest`, which resolves the newest published release binary at boot) and `data_disk_snapshot` for restoring a freshly created disk.
* `zebra_testing_deployments`: one entry per test deployment, keyed by a short slug (e.g. `pr-10513`). Each entry defaults to installing the release binary selected by `zebra_release_tag`; setting `zebra_repo_ref` or `zebra_git_fetch_ref` builds from source instead, and `zebra_repo_url` can point at a fork.

By default, SSH to `zebrad-archivenode` and `zebra-testing` is not exposed publicly. Those hosts are reachable on `tcp/22` only through Google Cloud IAP TCP tunneling. If you need direct public SSH for a limited set of source IPs, set `zebra_public_ssh_source_ranges` in `terraform.tfvars`.

## Zebra Workflow
The intended workflow for Zebra development and PR testing is:

1. Run `zebrad-archivenode` against the repo and ref you want to treat as the baseline node.
2. Wait for it to sync and produce a fresh state-disk snapshot.
3. Launch `zebra-testing` using that snapshot as its initial state disk, or leave the snapshot unset if you want it to start with an empty state disk.
4. Point `zebra-testing` at a branch, tag, commit, or PR ref you want to validate (source mode), or at a published release via `zebra_release_tag` (binary mode).

For GitHub pull requests, use `zebra_git_fetch_ref` with a ref like `refs/pull/10513/head`. That allows the instance startup script to fetch the PR ref directly and then check out the fetched commit before building Zebra from source.

Operator checklist:

1. First archive snapshot run: add (or set `replicas = 1` on) an entry in `zebrad_archivenode_deployments`, keep `zebra_testing_deployments` entries at `replicas = 0`, apply, wait for the archive node to reach a useful sync point, then wait for or manually trigger creation of the state snapshot (see [Archivenode snapshots](#archivenode-snapshots)).
2. First testing run: add a `zebra_testing_deployments` entry, optionally point its `data_disk_snapshot` at the archive snapshot, set the repo and ref you want to test, then apply again.
3. Subsequent PR runs: keep the archive node running so snapshots stay fresh, add or edit a testing entry's `zebra_repo_ref` / `zebra_git_fetch_ref` for the candidate you want to test, then re-apply.
4. Commit-SHA validation runs: set `zebra_repo_ref` to the exact commit SHA and leave `zebra_git_fetch_ref` empty unless you need an explicit non-branch fetch.

Example `terraform.tfvars` blocks for a mainnet archive node plus a testing node for Zebra PR [#10513](https://github.com/ZcashFoundation/zebra/pull/10513):

```hcl
zebrad_archivenode_deployments = {
  mainnet = {
    network         = "Mainnet"
    replicas        = 1
    data_disk_name  = "zebra-data"
    data_disk_size  = 350
    hostname_prefix = "zebra-archivenode"
    # zebra_release_tag omitted -> latest published release binary
  }
}

zebra_testing_deployments = {
  pr-10513 = {
    network             = "Mainnet"
    replicas            = 1
    data_disk_name      = "zebra-testing-pr10513-data"
    data_disk_size      = 350
    hostname_prefix     = "zebra-testing-pr10513"
    zebra_git_fetch_ref = "refs/pull/10513/head"
    data_disk_snapshot  = "zebra-data-0-snapshot-latest"
  }
}

zebra_archivenode_snapshot_on_calendar = "*-*-* 04:20:00"
zebra_metrics_endpoint_addr            = "0.0.0.0:9999"
```

If the archive node has not yet produced `zebra-data-0-snapshot-latest`, either wait for the scheduled snapshot, trigger one manually (see below), or omit `data_disk_snapshot` so the testing node starts with an empty disk.

Example `zebra_testing_deployments` entry for testing a specific Zebra commit SHA:

```hcl
  commit-9f3c2f8 = {
    network            = "Mainnet"
    replicas           = 1
    data_disk_name     = "zebra-testing-9f3c2f8-data"
    data_disk_size     = 350
    hostname_prefix    = "zebra-testing-9f3c2f8"
    zebra_repo_ref     = "9f3c2f8f4b8d6a1f6d9e7f0a1234567890abcdef"
    data_disk_snapshot = "zebra-data-0-snapshot-latest"
  }
```

If the commit is not reachable from the default remote refs you fetched previously, set `zebra_git_fetch_ref` to an explicit ref that contains it before applying.

## Archivenode snapshots

Each `zebrad-archivenode` instance installs a snapshot helper and a systemd timer during startup:

* `/usr/local/bin/zebra-create-snapshot`: deletes the previous snapshot of the same name, stops `zebrad`, snapshots the state disk, then restarts `zebrad`. The snapshot is named `<state-disk>-snapshot-latest` (e.g. `zebra-data-0-snapshot-latest` for mainnet, `zebra-testnet-data-0-snapshot-latest` for testnet) and labeled `purpose=zebra-state`, `network=<lowercased network>`, `source-disk=<state-disk>` so downstream consumers (z3, `zebra-testing`) can discover it.
* `zebra-snapshot.timer`: runs the helper (via `zebra-snapshot.service`) on the schedule set by `zebra_archivenode_snapshot_on_calendar` (default: daily at 04:20).

Note that `zebrad` is stopped for the duration of the snapshot creation and restarted afterward, so expect a brief sync interruption.

### Taking a snapshot manually via the CLI

To cut a snapshot on demand — for example right after the initial sync completes, without waiting for the timer — start the oneshot service over IAP-tunneled SSH (substitute the instance name for your deployment):

```console
gcloud compute ssh zebra-archivenode-testnet-0 --tunnel-through-iap \
  --command "sudo systemctl start zebra-snapshot.service"
```

`systemctl start` blocks until the snapshot request has been submitted and `zebrad` has been restarted. Prefer the service over invoking `/usr/local/bin/zebra-create-snapshot` directly so the run is logged to the journal, where you can review it afterward:

```console
gcloud compute ssh zebra-archivenode-testnet-0 --tunnel-through-iap \
  --command "sudo journalctl -u zebra-snapshot.service --no-pager -n 20"
```

Verify the snapshot from your workstation:

```console
gcloud compute snapshots list --filter="labels.purpose=zebra-state" \
  --format="table(name,labels.network,diskSizeGb,creationTimestamp,status)"
```

To check when the next scheduled snapshot will run:

```console
gcloud compute ssh zebra-archivenode-testnet-0 --tunnel-through-iap \
  --command "systemctl list-timers zebra-snapshot.timer --no-pager"
```

## Available Infrastructure
By default, all node types are disabled. Zcashd node types are enabled by toggling the corresponding value in the `replicas` map between 0 (disabled) and 1 (enabled):

```hcl
replicas = {
  zcashd-archivenode = 0
  zcashd-fullnode    = 0
  zcashd-privatenode = 0
}
```

Zebra and z3 node types are enabled per-deployment by setting `replicas` inside the corresponding entry of the `zebrad_archivenode_deployments`, `zebra_testing_deployments`, or `z3_deployments` maps (see [variables.tf](./variables.tf) for the full schemas and defaults).

A decription of each of the different types of infrastructure available follows:

* zcashd-archivenode: a [Zcashd](https://github.com/zcash/zcash) full node, which advertises its (natted) public IP to the p2p network and accepts incoming connections from other nodes on the Zcash network on tcp/8223.  The zcashd-archivenode also stops zcashd at regularly scheduled intervals in order to backup the chaindata (26GB as of July 2021) to a snapshot, via rsync, and also as a .tgz to GCS.
* zcashd-fullnode: a Zcashd full node which connects via Tor to other publicly reachable Zcashd nodes.  Note that inbound connections from other Tor nodes to a hidden service address is not presently enabled due to lack of support for v3 onion addresses. Fullnodes ordinarily *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.  The zcashd-fullnode accepts incoming connections on tcp/8233, but *only from the private VPC network*.
* zcashd-privatenode: a Zcashd full node which connects via the non-routable private VPC network to the zcashd-fullnode, and is not directly exposed to the Internet.  privatenodes ordinarly *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.
* zebrad-archivenode: a [Zebrad](https://github.com/ZcashFoundation/zebra) full node which installs the official checksum-verified release binary from GitHub releases (pinned via `zebra_release_tag`, defaulting to the latest release), configures Zebra primarily via `ZEBRA_*` environment variables, stores chain state on a persistent disk, and snapshots that disk on a systemd timer.
* zebra-testing: a Zebra test node intended for branch and PR validation. It installs the official release binary by default, or builds Zebra from a configurable git repo/ref when one is set. It restores its state disk from a snapshot, but does not create recurring snapshots of its own.
* z3: a Docker-based [Z3](https://github.com/zcashfoundation/z3) host that installs Docker Engine, clones the z3 repo, installs `rage`, mounts a dedicated persistent disk for Zebra chain data, pulls the pinned container images, and starts Zebra first so it can complete its initial sync before the rest of the stack is brought up. If a matching archivenode-produced snapshot exists for its network, the Zebra data disk is restored from it. A Rust toolchain for the `z3` app user (only needed for the opt-in source-build overlay) can be enabled globally via `z3_install_rust_toolchain` or per-deployment via `install_rust_toolchain`.


## Warning
This project is not designed to automate the management of Zcashd wallets.  If you use this infrastructure to receive funds to the Zcash addresses you generate, **you are responsible for securely backing up your keys and/or wallet.dat files!**


## Troubleshooting
* If you get "Error retrieving IAM policy for storage bucket" or "Error creating firewall" or "Error creating instance" errors from Terraform, these are likely due to a race condition. Simply re-run terraform apply.


## Planned improvements
- [x] Add support for network privacy using [Tor](https://www.torproject.org/)
- [ ] Add support for backing up and restoring blockchain data to/from IPFS
- [ ] Add support for [Zcash Lightwalletd](https://github.com/zcash/lightwalletd/)
- [ ] Add support for Prometheus + Grafana metrics collection and display
- [ ] Add support for network privacy using [Nym](https://nymtech.net/)
- [ ] Add support for a Zcash block explorer
- [ ] Stackdriver log parsers and monitoring and alerting and dashboards
- [ ] Add support for multiple Zebrad node types.  Hardwire the Zcash and Zebrad nodes to each other as trusted peers.


## Q&A
  * Q: Why didn't you use containers?
  * A: We love Docker and K8's as much as anybody.  [Docker artifacts for Zcashd](https://hub.docker.com/r/electriccoinco/zcashd) exist, but Zebra docker is still in the works.  Stay tuned!


  * Q: Google is evil, why are you targeting GCP initially?
  * A: Google may or may not be evil, but their public cloud platform is pretty amazing.  Pull requests are welcome for other public clouds, particularly DigitalOcean :)


  * Q: Has this project been audited for security issues?
  * A: No!  Please do not use this project for critical production workloads and/or mainnet funds without thoroughly understanding how it works and understanding the security tradeoffs.
 

## Zebra Cheatsheet
Every Zebra host (zebrad-archivenode, zebra-testing, z3) installs curl+jq helper functions for the node's localhost JSON-RPC endpoint via `/etc/profile.d/zebra-rpc.sh`; run `zebra-rpc-help` on the instance for the full list.
* Is my node synced? `gcloud compute ssh "zebra-archivenode-0" --command "bash -lc zebra-sync"`
* How many peers am I connected to? `gcloud compute ssh "zebra-archivenode-0" --command "bash -lc zebra-peers" | jq '.count'`
* Blockchain info: `gcloud compute ssh "zebra-archivenode-0" --command "bash -lc zebra-chain"`
* Fetch a block: `gcloud compute ssh "zebra-archivenode-0" --command "bash -lc 'zebra-block 1234567'"`
* Any RPC method: `gcloud compute ssh "zebra-archivenode-0" --command "bash -lc 'zebra-rpc getdifficulty'"`

## Zcashd Cheatsheet
* Is my node alive? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getinfo" | jq .`
* How many peers am I connected to? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getnetworkinfo" | jq '.connections'`
* Blockchain info: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getblockchaininfo" | jq .`
* Detailed info on connected peers: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getpeerinfo" | jq .`
* Create a shielded address: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_getnewaddress"`
* See total balance: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_gettotalbalance"`

---

