# Input variables. Supply values via tfvars.env (gitignored) or 1Password —
# never commit real secrets. Mark anything sensitive with `sensitive = true`.

# Nothing references this yet, and TFLint's terraform_unused_declarations rule
# (task lint:terraform:tflint) fails a declared-but-unused variable — which would
# make a fresh scaffold's very first `task check` red. The scoped ignore keeps
# the declaration real (deleting it would break repos already using
# `var.environment`) while leaving the rule enabled everywhere else. Drop the
# ignore line once something references this variable.
# tflint-ignore: terraform_unused_declarations
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
