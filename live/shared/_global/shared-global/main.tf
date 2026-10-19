import {
  to = module.parent_zone.aws_route53_zone.this
  id = var.registrar_zone_id
}

module "parent_zone" {
  source = "../../../../modules/route53-parent-zone"

  domain_name = var.domain_name
}

module "outputs" {
  source = "../../../../modules/ssm-outputs"

  prefix = "/shared/_global/shared-global"
  values = {
    zone_id   = module.parent_zone.zone_id
    zone_name = module.parent_zone.zone_name
  }
}
