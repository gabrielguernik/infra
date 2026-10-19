data "aws_ssm_parameter" "parent_zone_id" {
  name = "/shared/_global/shared-global/zone_id"
}

data "aws_ssm_parameter" "parent_zone_name" {
  name = "/shared/_global/shared-global/zone_name"
}

module "zone" {
  source = "../../../../../modules/dns-subzone"

  name           = "${var.env}.${nonsensitive(data.aws_ssm_parameter.parent_zone_name.value)}"
  parent_zone_id = nonsensitive(data.aws_ssm_parameter.parent_zone_id.value)
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/_global/dns"
  values = {
    zone_id   = module.zone.zone_id
    zone_name = module.zone.zone_name
  }
}
