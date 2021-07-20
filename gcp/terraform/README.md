# Terraform for running Zcash infrastructure in GCP

## Overview
This folder provides Terraform code that will create a new dedicated project in [Google Cloud Platform](https://cloud.google.com/), and provision and configure a full node running the latest release of [Zcashd](https://github.com/zcash/zcash).

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

8. Use terraform to deploy Zcash infrastructure
    `terraform apply`

    Once the Terraform apply completes in your terminal, you can see progress in the [Google Cloud Logs Explorer](https://console.cloud.google.com/logs/).  Make sure you select the right project, and click on "Stream logs" for realtime progress.
    

## Blockchain synchronization
Once Zcashd is installed, the blockchain will be synchronized over the peer to peer (p2p) network.  As of July 2021 the blockchain is ~25GB and this initial sync takes ~36 hours.  Once the blockchain is synchronized, it will be automatically compressed and archived to GCS once a day (todo: expose backup frequency and method as variables).  Note that this backup process stops Zcashd for several minutes while the tarball backup is created.  Rsync can be used instead, which will perform incremental backups which are much faster.  Until these options are exposed as variables, you can modify [startup.sh](modules/terraform/startup.sh) to enable the Rsync backup method, which is disabled by default.

## Troubleshooting
* If you get "Error retrieving IAM policy for storage bucket" or "Error creating firewall" or "Error creating instance" errors from Terraform, these are likely due to a race condition. Simply re-run terraform apply.


## Planned improvements
* Add support for network privacy using [Tor](https://www.torproject.org/)
* Add support for network privacy using [Nym](https://nymtech.net/)
* Add support for [Zcash Lightwalletd](https://github.com/zcash/lightwalletd/)
* Add support for a Zcash block explorer

## Zcashd Cheatsheet
* Is my node alive? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getinfo" | jq .`
* How many peers am I connected to? `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getnetworkinfo" | jq '.connections'`
* Blockchain info: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getblockchaininfo" | jq .`
* Detailed info on connected peers: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli getpeerinfo" | jq .`
* Create a shielded address: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_getnewaddress"`
* See total balance: `gcloud compute ssh "zcash-fullnode" --command "sudo -u zcash zcash-cli z_gettotalbalance"`