# Applied by an admin only, never by CI: it creates the roles CI uses.
# First apply runs with local state; see README "Bootstrap" for the migration to S3.

locals {
  state_bucket_name = "tfstate-${var.account_id}-${var.region}"
  # GitHub's immutable OIDC subjects (default for new repos): owner and repo carry their numeric IDs, so a
  # deleted-and-recreated repo with the same name cannot inherit this trust.
  infra_prefix  = "repo:${var.github_owner}@${var.github_owner_id}/${var.infra_repo.name}@${var.infra_repo.id}"
  app_prefix    = "repo:${var.github_owner}@${var.github_owner_id}/${var.app_repo.name}@${var.app_repo.id}"
  gitops_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.gitops_repo.name}@${var.gitops_repo.id}"

  # Terraform CI (infra repo, .github/workflows/terraform-*.yml). Two roles per stack:
  # - tf-<stack>:      writes. Trusted only from jobs in the GitHub environment "<env>" (deployment branch main, and
  #                    the approval gate), whose OIDC subject is ...:environment:<env>. A pull request can't reach it.
  # - tf-<stack>-plan: read-only (ReadOnlyAccess, which includes every SSM parameter; its state read-only, the bucket
  #                    policy denying every other prefix; the stack's secret values for refresh). Used by PR plans, the
  #                    plan before the gate on main, and the drift check. Plans run with -lock=false.
  #                    Every pull request can assume these roles, so PR authors can read plan_secrets (README).
  tf_roles = {
    for name, s in var.stacks : "tf-${name}" => {
      github_subjects   = ["${local.infra_prefix}:environment:${var.env}"]
      policy_template   = name
      state_prefix      = s.state_prefix
      ssm_write_prefix  = s.ssm_write_prefix
      ssm_read_prefixes = s.ssm_read_prefixes
    }
  }

  tf_plan_roles = {
    for name, s in var.stacks : "tf-${name}-plan" => {
      github_subjects     = ["${local.infra_prefix}:ref:refs/heads/main", "${local.infra_prefix}:pull_request"]
      managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      state_prefix        = s.state_prefix
      state_read_only     = true
      secret_read_arns    = [for p in s.plan_secrets : "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${p}"]
    }
  }

  build_roles = {
    "ci-build" = {
      github_subjects   = ["${local.app_prefix}:ref:refs/heads/main"]
      policy_template   = "ci-build"
      state_prefix      = null
      ssm_write_prefix  = null
      ssm_read_prefixes = []
    }
  }

  # Read-only: the gitops repo's checks verify that every AWS resource a cluster folder references still exists.
  gitops_check_roles = {
    "gitops-check" = {
      github_subjects   = ["${local.gitops_prefix}:ref:refs/heads/main", "${local.gitops_prefix}:pull_request"]
      policy_template   = "gitops-check"
      state_prefix      = null
      ssm_write_prefix  = null
      ssm_read_prefixes = []
    }
  }

  # The gitops pipeline's install job runs in a GitHub environment named after the cluster, so the OIDC subject is
  # ...:environment:<cluster> (not :ref:...). Only jobs that pass that environment's protection rules get the role.
  # Clusters of this env, named <env>-<region>; the SSM paths come from that name.
  argocd_roles = {
    for c in var.argocd_clusters : "argocd-${c}" => {
      github_subjects   = ["${local.gitops_prefix}:environment:${c}"]
      policy_template   = "argocd"
      template_vars     = { cluster_name = c }
      state_prefix      = null
      ssm_write_prefix  = null
      ssm_read_prefixes = ["/${var.env}/${trimprefix(c, "${var.env}-")}/eks", "/${var.env}/${trimprefix(c, "${var.env}-")}/bastion"]
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
  roles            = merge(local.tf_roles, local.tf_plan_roles, local.build_roles, local.argocd_roles, local.gitops_check_roles)

  template_vars = {
    account_id     = var.account_id
    region         = var.region
    parent_domain  = var.parent_domain
    parent_zone_id = var.parent_zone_id
    env_domain     = "${var.env}.${var.parent_domain}"
    env            = var.env
    cluster_name   = "${var.env}-${var.region}" # argocd roles override it with their own cluster
  }
}

module "state_backend" {
  source = "../../../../../modules/tf-state-backend"

  bucket_name = local.state_bucket_name
  prefix_restrictions = {
    for name, role in merge(local.tf_roles, local.tf_plan_roles) : name => {
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
