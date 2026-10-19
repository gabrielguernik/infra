data "aws_ssm_parameter" "zone_id" {
  name = "/${var.env}/_global/dns/zone_id"
}

data "aws_ssm_parameter" "zone_name" {
  name = "/${var.env}/_global/dns/zone_name"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "/${var.env}/${var.region}/network/vpc_id"
}

module "edge" {
  source = "../../../../../modules/edge"

  name       = "${var.env}-${var.region}"
  domain     = nonsensitive(data.aws_ssm_parameter.zone_name.value)
  zone_id    = nonsensitive(data.aws_ssm_parameter.zone_id.value)
  vpc_id     = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  enable_waf = var.enable_waf
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/edge"
  values = merge(
    {
      certificate_arn = module.edge.certificate_arn
      alb_sg_id       = module.edge.alb_sg_id
    },
    var.enable_waf ? { waf_acl_arn = module.edge.waf_acl_arn } : {},
  )
}
