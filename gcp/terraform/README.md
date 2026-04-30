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
    [variables.tf](./variables.tf) includes a variable called replicas, which allows you to enable and disable a variety of different kinds of Zcash infrastructure.
    By default, zcashd and zebrad archive nodes will be created.  A decription of each of the (#Available-Infrastructure) is below.

9. Use terraform to deploy Zcash infrastructure
    `terraform apply`

    Once the Terraform apply completes in your terminal, you can see progress in the [Google Cloud Logs Explorer](https://console.cloud.google.com/logs/).  Make sure you select the right project, and click on "Stream logs" for realtime progress.
    

## Blockchain synchronization
Zcash chain state is synchronized over the peer to peer (p2p) network and can take a substantial amount of time to build from scratch. The Zebra modules in this repo now rely on persistent disks and Compute Engine snapshots rather than GCS tarball or rsync backups. The intended workflow is to let a long-lived archive node maintain fresh chain state and publish snapshots, then restore those snapshots into other nodes that should come up quickly.

## Zebra Roles
The repo now has two distinct source-built Zebra roles with different operational goals:

* `zebrad-archivenode`: the long-lived baseline node. It clones a configurable Zebra repo and ref, runs with env-first configuration via `ZEBRA_*` variables, keeps chain state on a dedicated persistent disk, and cuts recurring snapshots of that disk on a systemd timer.
* `zebra-testing`: the disposable validation node. It can restore its persistent state disk from a snapshot, builds Zebra from a configurable repo and ref, and is intended for branch and PR testing. It does not publish recurring snapshots of its own.

In practice, the archive node is what keeps the snapshot pipeline warm. The testing node is what you point at a candidate branch or PR once you already have a usable archive snapshot.

`zebrad-archivenode` now always checks out the latest tagged Zebra release from the official `ZcashFoundation/zebra` repository. The `zebra_repo_url`, `zebra_repo_ref`, and `zebra_git_fetch_ref` variables are used only by `zebra-testing`.

By default, SSH to `zebrad-archivenode` and `zebra-testing` is not exposed publicly. Those hosts are reachable on `tcp/22` only through Google Cloud IAP TCP tunneling. If you need direct public SSH for a limited set of source IPs, set `zebra_public_ssh_source_ranges` in `terraform.tfvars`.

## Zebra Workflow
The intended workflow for Zebra development and PR testing is:

1. Run `zebrad-archivenode` against the repo and ref you want to treat as the baseline node.
2. Wait for it to sync and produce a fresh state-disk snapshot.
3. Launch `zebra-testing` using that snapshot as its initial state disk, or leave the snapshot unset if you want it to start with an empty state disk.
4. Point `zebra-testing` at a branch, tag, commit, or PR ref you want to validate.

For GitHub pull requests, use `zebra_git_fetch_ref` with a ref like `refs/pull/10513/head`. That allows the instance startup script to fetch the PR ref directly and then check out the fetched commit before building Zebra from source.

Operator checklist:

1. First archive snapshot run: enable `zebrad-archivenode`, keep `zebra-testing` disabled, apply Terraform, wait for the archive node to reach a useful sync point, then wait for or trigger creation of `zebra-data-0-snapshot-latest`.
2. First testing run: enable `zebra-testing`, optionally point `zebra_testing_data_disk_snapshot` at the archive snapshot, set the repo and ref you want to test, then apply Terraform again.
3. Subsequent PR runs: keep the archive node running so snapshots stay fresh, change only `zebra_repo_ref` and `zebra_git_fetch_ref` for the candidate you want to test, then re-apply.
4. Commit-SHA validation runs: set `zebra_repo_ref` to the exact commit SHA and leave `zebra_git_fetch_ref` empty unless you need an explicit non-branch fetch.

Example `terraform.tfvars` block for Zebra PR [#10513](https://github.com/ZcashFoundation/zebra/pull/10513):

```hcl
zebra_repo_url      = "https://github.com/ZcashFoundation/zebra"
zebra_repo_ref      = "pr-10513"
zebra_git_fetch_ref = "refs/pull/10513/head"

replicas = {
    zcashd-archivenode = 0
    zcashd-fullnode    = 0
    zcashd-privatenode = 0
    zebrad-archivenode = 1
    zebra-testing      = 1
}

instance_types = {
    zcashd-archivenode = "e2-standard-4"
    zcashd-fullnode    = "n1-standard-2"
    zcashd-privatenode = "n1-standard-2"
    zebrad-archivenode = "e2-standard-4"
    zebra-testing      = "e2-standard-4"
}

zebra_archivenode_snapshot_on_calendar = "*-*-* 04:20:00"
zebra_testing_data_disk_snapshot       = "zebra-data-0-snapshot-latest"
zebra_metrics_endpoint_addr            = "0.0.0.0:9999"
```

If the archive node has not yet produced `zebra-data-0-snapshot-latest`, either wait for the scheduled snapshot, set `zebra_archivenode_snapshot_on_calendar` more aggressively for your test cycle, or leave `zebra_testing_data_disk_snapshot` unset so `zebra-testing` starts with an empty disk.

Example `terraform.tfvars` block for testing a specific Zebra commit SHA:

```hcl
zebra_repo_url      = "https://github.com/ZcashFoundation/zebra"
zebra_repo_ref      = "9f3c2f8f4b8d6a1f6d9e7f0a1234567890abcdef"
zebra_git_fetch_ref = ""

replicas = {
    zcashd-archivenode = 0
    zcashd-fullnode    = 0
    zcashd-privatenode = 0
    zebrad-archivenode = 1
    zebra-testing      = 1
}

instance_types = {
    zcashd-archivenode = "e2-standard-4"
    zcashd-fullnode    = "n1-standard-2"
    zcashd-privatenode = "n1-standard-2"
    zebrad-archivenode = "e2-standard-4"
    zebra-testing      = "e2-standard-4"
}

zebra_testing_data_disk_snapshot = "zebra-data-0-snapshot-latest"
```

If the commit is not reachable from the default remote refs you fetched previously, set `zebra_git_fetch_ref` to an explicit ref that contains it before applying.

## Available Infrastructure
[variables.tf](./variables.tf) includes a variable called replicas, which allows you to enable and disable a variety of different kinds of Zcash infrastructure.
By default, all node types are disabled. You can enable or disable each node type by toggling the corresponding value between 0 (disabled) or 1 (enabled).

```
variable replicas {
    description = "The replica number for each component"
    type        = map(number)

    default = {
        zcashd-archivenode         = 1
        zcashd-fullnode            = 0
        zcashd-privatenode         = 0 
        zebrad-archivenode         = 1
        zebra-testing              = 0
    }
}
```

A decription of each of the different types of infrastructure available follows:

* zcashd-archivenode: a [Zcashd](https://github.com/zcash/zcash) full node, which advertises its (natted) public IP to the p2p network and accepts incoming connections from other nodes on the Zcash network on tcp/8223.  The zcashd-archivenode also stops zcashd at regularly scheduled intervals in order to backup the chaindata (26GB as of July 2021) to a snapshot, via rsync, and also as a .tgz to GCS.
* zcashd-fullnode: a Zcashd full node which connects via Tor to other publicly reachable Zcashd nodes.  Note that inbound connections from other Tor nodes to a hidden service address is not presently enabled due to lack of support for v3 onion addresses. Fullnodes ordinarily *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.  The zcashd-fullnode accepts incoming connections on tcp/8233, but *only from the private VPC network*.
* zcashd-privatenode: a Zcashd full node which connects via the non-routable private VPC network to the zcashd-fullnode, and is not directly exposed to the Internet.  privatenodes ordinarly *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.
* zebrad-archivenode: a source-built [Zebrad](https://github.com/ZcashFoundation/zebra) full node which clones a configurable Zebra git repo/ref, configures Zebra primarily via `ZEBRA_*` environment variables, stores chain state on a persistent disk, and snapshots that disk on a systemd timer.
* zebra-testing: a source-built Zebra test node intended for branch and PR validation. It restores its state disk from a snapshot, but does not create recurring snapshots of its own.
* z3: a Docker-based [Z3](https://github.com/zcashfoundation/z3) host that installs Docker Engine, clones the z3 repo, installs `rage`, mounts a dedicated persistent disk for Zebra chain data, builds the required images, and starts Zebra first so it can complete its initial sync before the rest of the stack is brought up. It can optionally install a Rust toolchain for the `z3` app user via `z3_install_rust_toolchain=true`.


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
 

## Zcashd Cheatsheet
* Is my node alive? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getinfo" | jq .`
* How many peers am I connected to? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getnetworkinfo" | jq '.connections'`
* Blockchain info: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getblockchaininfo" | jq .`
* Detailed info on connected peers: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getpeerinfo" | jq .`
* Create a shielded address: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_getnewaddress"`
* See total balance: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_gettotalbalance"`

---

