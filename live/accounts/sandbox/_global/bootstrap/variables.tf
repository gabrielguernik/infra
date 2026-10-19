variable "account_id" {
  description = "AWS account this stack may run against (guards against applying with the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Primary region; the state bucket lives here."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repos."
  type        = string
}

variable "infra_repo" {
  description = "Repo holding the Terraform code."
  type        = string
}

variable "app_repo" {
  description = "Repo holding the application; its CI pushes images."
  type        = string
}

variable "parent_domain" {
  description = "Registered parent domain."
  type        = string
}

variable "parent_zone_id" {
  description = "Hosted zone ID of the parent domain (created by Route 53 Domains, imported by shared-global)."
  type        = string
}

variable "env" {
  description = "Environment whose stacks get CI roles."
  type        = string
}

variable "stacks" {
  description = <<-EOT
    Terraform stacks that get a CI role (tf-<name>). state_prefix is the stack's folder under live/,
    ssm_write_prefix its own SSM path, ssm_read_prefixes the SSM paths it consumes.
  EOT
  type = map(object({
    state_prefix      = string
    ssm_write_prefix  = string
    ssm_read_prefixes = optional(list(string), [])
  }))
}
