# Applied by an admin only, never by CI: it creates the roles CI uses.
# First apply runs with local state; see README "Bootstrap" for the migration to S3.

locals {
  state_bucket_name = "tfstate-${var.account_id}-${var.region}"
  infra_subjects = [
    "repo:${var.github_owner}/${var.infra_repo}:ref:refs/heads/main",
    "repo:${var.github_owner}/${var.infra_repo}:pull_request",
  ]

  tf_roles = {
    for name, s in var.stacks : "tf-${name}" => {
      github_subjects   = local.infra_subjects
      policy_template   = name
      state_prefix      = s.state_prefix
      ssm_write_prefix  = s.ssm_write_prefix
      ssm_read_prefixes = s.ssm_read_prefixes
    }
  }

  build_roles = {
    "ci-build" = {
      github_subjects   = ["repo:${var.github_owner}/${var.app_repo}:ref:refs/heads/main"]
      policy_template   = "ci-build"
      state_prefix      = null
      ssm_write_prefix  = null
      ssm_read_prefixes = []
    }
  }
}

module "github_oidc" {
  source = "../../../../../modules/github-oidc"
}

module "ci_roles" {
  source = "../../../../../modules/ci-roles"

  oidc_provider_arn = module.github_oidc.provider_arn
  # Built from the name so roles and bucket policy don't depend on each other.
  state_bucket_arn = "arn:aws:s3:::${local.state_bucket_name}"
  roles            = merge(local.tf_roles, local.build_roles)

  template_vars = {
    account_id     = var.account_id
    region         = var.region
    parent_domain  = var.parent_domain
    parent_zone_id = var.parent_zone_id
    env_domain     = "${var.env}.${var.parent_domain}"
  }
}

module "state_backend" {
  source = "../../../../../modules/tf-state-backend"

  bucket_name = local.state_bucket_name
  prefix_restrictions = {
    for name, role in local.tf_roles : name => {
      role_arn = module.ci_roles.role_arns[name]
      prefix   = role.state_prefix
    }
  }
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/account/_global/bootstrap"
  values = merge(
    {
      state_bucket      = module.state_backend.bucket_name
      oidc_provider_arn = module.github_oidc.provider_arn
    },
    { for name, arn in module.ci_roles.role_arns : "roles/${name}" => arn },
  )
}
