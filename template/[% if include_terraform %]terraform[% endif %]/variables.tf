# Input variables. Supply values via tfvars.env (gitignored) or 1Password —
# never commit real secrets. Mark anything sensitive with `sensitive = true`.

# Commented out until something references it: TFLint's
# terraform_unused_declarations rule (task lint:terraform:tflint) fails on a
# declared-but-unused variable, so a live example here would make the very first
# `task check` of a fresh scaffold red.
# variable "environment" {
#   description = "Deployment environment (e.g. dev, staging, prod)."
#   type        = string
#   default     = "dev"
# }

# TODO: add provider tokens / config as sensitive variables, e.g.:
# variable "cloudflare_api_token" {
#   description = "Cloudflare API token."
#   type        = string
#   sensitive   = true
# }
