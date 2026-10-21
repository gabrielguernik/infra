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
  domain     = data.aws_ssm_parameter.zone_name.insecure_value
  zone_id    = data.aws_ssm_parameter.zone_id.insecure_value
  vpc_id     = data.aws_ssm_parameter.vpc_id.insecure_value
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
