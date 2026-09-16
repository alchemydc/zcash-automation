terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
  }
}

provider "digitalocean" {
  # No token argument on purpose. The provider reads DIGITALOCEAN_ACCESS_TOKEN
  # (or DIGITALOCEAN_TOKEN) from the environment, and giving it a Terraform
  # variable as well would add a second path to the credential -- one that can
  # land in a tfvars file, a shell history, or a CI variable. There is nothing
  # to gain from it: a DigitalOcean PAT is a long-lived bearer token whose
  # scopes are per resource *type*, never per instance, so the fewer places it
  # can come to rest, the better.
  #
  # On the dev boxes it is forwarded over ssh and injected per-process by
  # `do-run` (ansible-toolbox, dev_server role), so it never touches disk here.
  # Prefer DIGITALOCEAN_ACCESS_TOKEN: doctl reads only that spelling, while the
  # provider accepts either.
}
