data "aws_ssm_parameter" "parent_zone_id" {
  name = "/shared/_global/shared-global/zone_id"
}

data "aws_ssm_parameter" "parent_zone_name" {
  name = "/shared/_global/shared-global/zone_name"
}

module "zone" {
  source = "../../../../../modules/dns-subzone"

  name           = "${var.env}.${data.aws_ssm_parameter.parent_zone_name.insecure_value}"
  parent_zone_id = data.aws_ssm_parameter.parent_zone_id.insecure_value
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/_global/dns"
  values = {
    zone_id   = module.zone.zone_id
    zone_name = module.zone.zone_name
  }
}
