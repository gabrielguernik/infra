locals {
  network = "/${var.env}/${var.region}/network"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.network}/vpc_id"
}

data "aws_ssm_parameter" "private_data_subnet_ids" {
  name = "${local.network}/private_data_subnet_ids"
}

data "aws_subnet" "data" {
  for_each = toset(split(",", data.aws_ssm_parameter.private_data_subnet_ids.insecure_value))
  id       = each.key
}

data "aws_ssm_parameter" "private_app_subnet_ids" {
  name = "${local.network}/private_app_subnet_ids"
}

module "bastion" {
  source = "../../../../../modules/bastion"

  name       = "${var.env}-${var.region}"
  vpc_id     = data.aws_ssm_parameter.vpc_id.insecure_value
  data_cidrs = sort([for s in data.aws_subnet.data : s.cidr_block])
  subnet_id  = split(",", data.aws_ssm_parameter.private_app_subnet_ids.insecure_value)[0]
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/bastion"
  values = {
    instance_id = module.bastion.instance_id
    sg_id       = module.bastion.sg_id
  }
}
