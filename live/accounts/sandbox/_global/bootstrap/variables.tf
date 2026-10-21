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

variable "github_owner_id" {
  description = "Numeric ID of the GitHub owner (gh api users/<owner> --jq .id); part of immutable OIDC subjects."
  type        = string
}

variable "infra_repo" {
  description = "Repo holding the Terraform code: name and numeric ID (gh api repos/<owner>/<name> --jq .id)."
  type = object({
    name = string
    id   = string
  })
}

variable "app_repo" {
  description = "Repo holding the application, whose CI pushes images: name and numeric ID."
  type = object({
    name = string
    id   = string
  })
}

variable "gitops_repo" {
  description = "Repo holding the GitOps config and the ArgoCD install pipeline: name and numeric ID."
  type = object({
    name = string
    id   = string
  })
}

variable "argocd_clusters" {
  description = "EKS clusters (<env>-<region>) whose ArgoCD install job in the gitops repo gets a role, ci/argocd-<cluster>."
  type        = list(string)
  default     = []
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
    Terraform stacks that get CI roles (tf-<name> and tf-<name>-plan), in apply order: the Terraform workflows read
    this map (scripts/ci/stacks.py) for the stack list and the order. state_prefix is the stack's folder under live/,
    ssm_write_prefix its own SSM path, ssm_read_prefixes the SSM paths it consumes, plan_secrets the secrets
    (name patterns) whose values a plan reads when refreshing secret versions.
  EOT
  type = map(object({
    state_prefix      = string
    ssm_write_prefix  = string
    ssm_read_prefixes = optional(list(string), [])
    plan_secrets      = optional(list(string), [])
  }))
}
