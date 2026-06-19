# Input variables. Supply values via tfvars.env (gitignored) or 1Password —
# never commit real secrets. Mark anything sensitive with `sensitive = true`.

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

# TODO: add provider tokens / config as sensitive variables, e.g.:
# variable "cloudflare_api_token" {
#   description = "Cloudflare API token."
#   type        = string
#   sensitive   = true
# }
