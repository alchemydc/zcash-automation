terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
  }
}

provider "digitalocean" {
  # Reads DIGITALOCEAN_TOKEN from the environment. Source it from do.env, which
  # .gitignore already covers via *.env -- the token must never be committed,
  # and DigitalOcean scopes are per resource type rather than per resource, so a
  # leaked token reaches everything of that type in the team.
  token = var.do_token
}
