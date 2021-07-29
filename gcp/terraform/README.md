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

6. Run bootstrap.sh again to initialize your new GCP project and enable appropriate API's
    ```console
    ./bootstrap.sh
    ```

    Note that when this completes, you need to `source gcloud.env` again in order to import the newly created GCP service account which Terraform will use.

7. Initialize terraform
    `terraform init`

    This will download the Terraform provider for GCP, and configure the Google Cloud Storage (GCS) bucket that was created during bootstrapping to store Terraform state.  State can be stored locally, but this makes it harder for multiple developers to manage Terraform infrastructure together.

8. Enable optional node types
    [variables.tf](./variables.tf) includes a variable called replicas, which allows you to enable and disable a variety of different kinds of Zcash infrastructure.
    By default, zcashd and zebrad archive nodes will be created.  A decription of each of the (#Available-Infrastructure) is below.

9. Use terraform to deploy Zcash infrastructure
    `terraform apply`

    Once the Terraform apply completes in your terminal, you can see progress in the [Google Cloud Logs Explorer](https://console.cloud.google.com/logs/).  Make sure you select the right project, and click on "Stream logs" for realtime progress.
    

## Blockchain synchronization
Once Zcashd is installed, the blockchain will be synchronized over the peer to peer (p2p) network.  As of July 2021 the blockchain is ~26GB and this initial sync takes ~36 hours with Zcashd, and several hours with Zebrad.  Once the blockchain is synchronized, it will be automatically compressed and archived to GCS once a week.  Note that these backup process stops Zcashd and Zebrad for several minutes while the tarball backup is created.  Rsync is thus used instead for daily backups, and will perform incremental backups which are much faster.  Snapshots of the chaindata volumes are cut nightly and are used to create all of the other node types, which should make them sync to the chain tip very quickly.

## Available Infrastructure
[variables.tf](./variables.tf) includes a variable called replicas, which allows you to enable and disable a variety of different kinds of Zcash infrastructure.
By default, a single zcashd "archivenode" will be created.  You can enable/disable each of these node types by toggling the value for each between 0 (disabled) or 1 (enabled).

```
variable replicas {
    description = "The replica number for each component"
    type        = map(number)

    default = {
        zcashd-archivenode         = 1
        zcashd-fullnode            = 0
        zcashd-privatenode         = 0 
        zebrad-archivenode         = 1 
    }
}
```

A decription of each of the different types of infrastructure available follows:

* zcashd-archivenode: a [Zcashd](https://github.com/zcash/zcash) full node, which advertises its (natted) public IP to the p2p network and accepts incoming connections from other nodes on the Zcash network on tcp/8223.  The zcashd-archivenode also stops zcashd at regularly scheduled intervals in order to backup the chaindata (26GB as of July 2021) to a snapshot, via rsync, and also as a .tgz to GCS.
* zcashd-fullnode: a Zcashd full node which connects via Tor to other publicly reachable Zcashd nodes.  Note that inbound connections from other Tor nodes to a hidden service address is not presently enabled due to lack of support for v3 onion addresses. Fullnodes ordinarily *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.  The zcashd-fullnode accepts incoming connections on tcp/8233, but *only from the private VPC network*.
* zcashd-privatenode: a Zcashd full node which connects via the non-routable private VPC network to the zcashd-fullnode, and is not directly exposed to the Internet.  privatenodes ordinarly *do not need to sync the blockchain via the p2p network*, because their blockchain data volume is created from a snapshot of the zcashd-archivenode.
* zebrad-archivenode: a [Zebrad](https://github.com/ZcashFoundation/zebra) full node, which advertises its (natted) public IP to the p2p network and accepts incoming connections from other nodes on the Zcash network on tcp/8223.  The zebrad-archivenode also stops zebrad at regularly scheduled intervals in order to backup the chaindata (32GB as of July 2021) to a snapshot, via rsync, and also as a .tgz to GCS.   


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