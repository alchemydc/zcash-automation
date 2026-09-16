# zcash-automation

## Overview

[Zcash](https://z.cash) is a censorship resistant, fixed supply, privacy preserving cryptocurrency. Launched in 2016, Zcash is the first cryptocurrency to operationalize zero knowledge cryptography to create a secure, private, digital currency,

This repository contains tools and frameworks to enable provisioning, configuration, management and monitoring of Zcash infrastructure in public clouds.

The first provider targeted is [Google Cloud Platform](https://cloud.google.com/), using [Terraform](https://www.terraform.io/). Most infrastructure lives there — see the [README](gcp/terraform/README.md) in the gcp/terraform folder to get started.

The Shielded-Vote validator runs on [DigitalOcean](https://www.digitalocean.com/) instead, because GCP was dropping Tor-sourced traffic to its helper API and voters need to reach it over Tor. See the [README](do/terraform/README.md) in the do/terraform folder, which also carries the operator runbook.

