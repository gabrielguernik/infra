# One IAM role per CI consumer (each Terraform stack's plan and apply roles, ci-build, ...), assumable only through
# GitHub OIDC. Each role gets:
#   - state:   read/write (or read-only) on its own key prefix in the state bucket (the bucket policy also enforces this);
#   - ssm:     write on its own /<env>/<region>/<stack> path, read on the paths it consumes;
#   - secrets: GetSecretValue on the listed secrets (plan roles: refreshing secret versions needs the value);
#   - service: the AWS permissions its resources need, from policies/<template>.json.tftpl;
#   - managed: AWS managed policies (plan roles: ReadOnlyAccess).

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider."
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  type        = string
}

variable "roles" {
  description = "Role name => settings."
  type = map(object({
    github_subjects     = list(string)          # allowed OIDC 'sub' claims, e.g. repo:owner/infra:pull_request
    policy_template     = optional(string)      # file name in policies/, without .json.tftpl; null = none
    state_prefix        = optional(string)      # null for roles that never touch state (ci-build)
    state_read_only     = optional(bool, false) # plan roles: read state, never write it (plans run with -lock=false)
    ssm_write_prefix    = optional(string)      # e.g. /sandbox/us-east-1/network
    ssm_read_prefixes   = optional(list(string), [])
    secret_read_arns    = optional(list(string), []) # secret ARNs (wildcards allowed) this role may read
    managed_policy_arns = optional(list(string), [])
    template_vars       = optional(map(string), {}) # per-role values for the policy template, over var.template_vars
  }))
}

variable "template_vars" {
  description = "Variables passed to every policy template (account_id, region, domains, ...)."
  type        = map(string)
}

variable "path" {
  description = "IAM path for the roles."
  type        = string
  default     = "/ci/"
}

variable "max_session_duration" {
  description = "Maximum session length in seconds."
  type        = number
  default     = 3600
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_arn_prefix = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter"
}

data "aws_iam_policy_document" "trust" {
  for_each = var.roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.github_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name                 = each.key
  path                 = var.path
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = var.max_session_duration
}

data "aws_iam_policy_document" "base" {
  for_each = { for k, v in var.roles : k => v if v.state_prefix != null || v.ssm_write_prefix != null || length(v.ssm_read_prefixes) > 0 || length(v.secret_read_arns) > 0 }

  # Key names in the state bucket are not sensitive; object access below is what is scoped.
  # The S3 backend lists the bucket during init (workspace discovery), so ListBucket stays unconditional.
  dynamic "statement" {
    for_each = each.value.state_prefix == null ? [] : [1]
    content {
      sid       = "StateList"
      actions   = ["s3:ListBucket"]
      resources = [var.state_bucket_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.state_prefix == null ? [] : [1]
    content {
      sid       = "StateObjects"
      actions   = each.value.state_read_only ? ["s3:GetObject"] : ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${var.state_bucket_arn}/${each.value.state_prefix}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.ssm_write_prefix == null ? [] : [1]
    content {
      sid = "SsmOwnOutputs"
      actions = [
        "ssm:PutParameter",
        "ssm:DeleteParameter",
        "ssm:DeleteParameters",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:AddTagsToResource",
        "ssm:RemoveTagsFromResource",
        "ssm:ListTagsForResource",
      ]
      resources = [
        "${local.ssm_arn_prefix}${each.value.ssm_write_prefix}",
        "${local.ssm_arn_prefix}${each.value.ssm_write_prefix}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.ssm_read_prefixes) == 0 ? [] : [1]
    content {
      sid     = "SsmConsumedOutputs"
      actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = flatten([for p in each.value.ssm_read_prefixes : [
        "${local.ssm_arn_prefix}${p}",
        "${local.ssm_arn_prefix}${p}/*",
      ]])
    }
  }

  dynamic "statement" {
    for_each = length(each.value.secret_read_arns) == 0 ? [] : [1]
    content {
      sid       = "SecretValues"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = each.value.secret_read_arns
    }
  }

  dynamic "statement" {
    for_each = each.value.ssm_write_prefix == null ? [] : [1]
    content {
      sid       = "SsmDescribe"
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "base" {
  for_each = data.aws_iam_policy_document.base

  name   = "state-and-ssm"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json
}

resource "aws_iam_role_policy" "service" {
  for_each = { for k, v in var.roles : k => v if v.policy_template != null }

  name   = "service"
  role   = aws_iam_role.this[each.key].id
  policy = templatefile("${path.module}/policies/${each.value.policy_template}.json.tftpl", merge(var.template_vars, each.value.template_vars))
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = merge([for k, v in var.roles : { for arn in v.managed_policy_arns : "${k}|${arn}" => { role = k, arn = arn } }]...)

  role       = aws_iam_role.this[each.value.role].name
  policy_arn = each.value.arn
}

output "role_arns" {
  description = "Role name => ARN."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}
