terraform {
  # Unlike the google provider, digitalocean is not in the hashicorp namespace,
  # so the source address has to be declared or `init` cannot resolve it.
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
  }
}
