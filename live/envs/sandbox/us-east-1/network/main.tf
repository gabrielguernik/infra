data "aws_ssm_parameter" "log_bucket_arn" {
  name = "/shared/${var.region}/shared-regional/log_bucket_arn"
}

locals {
  name = "${var.env}-${var.region}"
}

module "network" {
  source = "../../../../../modules/network"

  name                       = local.name
  cidr                       = var.vpc_cidr
  cluster_name               = local.name
  single_nat_gateway         = var.single_nat_gateway
  enable_interface_endpoints = var.enable_interface_endpoints
  flow_log_destination_arn   = "${data.aws_ssm_parameter.log_bucket_arn.insecure_value}/vpc-flow-logs/${var.env}/${var.region}"
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/network"
  values = {
    vpc_id     = module.network.vpc_id
    vpc_cidr   = module.network.vpc_cidr
    vpce_sg_id = module.network.vpce_sg_id
  }
  list_values = {
    azs                     = module.network.azs
    public_subnet_ids       = module.network.public_subnet_ids
    private_app_subnet_ids  = module.network.private_app_subnet_ids
    private_data_subnet_ids = module.network.private_data_subnet_ids
    private_app_cidrs       = module.network.private_app_cidrs
    nat_public_ips          = module.network.nat_public_ips
  }
}
