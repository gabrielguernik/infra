locals {
  name = "${var.env}-${var.region}"
  eks  = "/${var.env}/${var.region}/eks"
}

data "aws_ssm_parameter" "oidc_provider_arn" {
  name = "${local.eks}/oidc_provider_arn"
}

data "aws_ssm_parameter" "oidc_issuer" {
  name = "${local.eks}/oidc_issuer"
}

data "aws_ssm_parameter" "zone_id" {
  name = "/${var.env}/_global/dns/zone_id"
}

data "aws_ssm_parameter" "db_instance_arn" {
  name = "/${var.env}/${var.region}/data/db_instance_arn"
}

data "aws_ssm_parameter" "amp_workspace_arn" {
  name = "/${var.env}/${var.region}/monitoring/amp_workspace_arn"
}

data "aws_ssm_parameter" "log_group_arn" {
  name = "/${var.env}/${var.region}/monitoring/log_group_arn"
}

module "platform" {
  source = "../../../../../modules/platform"

  name              = local.name
  env               = var.env
  oidc_provider_arn = nonsensitive(data.aws_ssm_parameter.oidc_provider_arn.value)
  oidc_issuer       = nonsensitive(data.aws_ssm_parameter.oidc_issuer.value)
  zone_id           = nonsensitive(data.aws_ssm_parameter.zone_id.value)
  db_instance_arn   = nonsensitive(data.aws_ssm_parameter.db_instance_arn.value)
  amp_workspace_arn = nonsensitive(data.aws_ssm_parameter.amp_workspace_arn.value)
  log_group_arn     = nonsensitive(data.aws_ssm_parameter.log_group_arn.value)
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/platform"
  values = { for k, arn in module.platform.role_arns : "irsa/${k}" => arn }
}
