# Terraform entrypoint.
# Run formatting/validation via `task lint:terraform` / `task validate`.

terraform {
  required_version = ">= 1.9"

  # TODO: declare the providers this project uses, pinned to a major version.
  # required_providers {
  #   cloudflare = {
  #     source  = "cloudflare/cloudflare"
  #     version = "~> 5.0"
  #   }
  # }

  # TODO: configure remote state (recommended) instead of local state.
  # backend "s3" {}
}

# TODO: add resources, or split them into per-concern .tf files
# (e.g. network.tf, compute.tf). Keep provider tokens in sensitive variables.
