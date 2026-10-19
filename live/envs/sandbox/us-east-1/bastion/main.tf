locals {
  network = "/${var.env}/${var.region}/network"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.network}/vpc_id"
}

data "aws_ssm_parameter" "vpc_cidr" {
  name = "${local.network}/vpc_cidr"
}

data "aws_ssm_parameter" "private_app_subnet_ids" {
  name = "${local.network}/private_app_subnet_ids"
}

module "bastion" {
  source = "../../../../../modules/bastion"

  name      = "${var.env}-${var.region}"
  vpc_id    = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  vpc_cidr  = nonsensitive(data.aws_ssm_parameter.vpc_cidr.value)
  subnet_id = split(",", nonsensitive(data.aws_ssm_parameter.private_app_subnet_ids.value))[0]
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/bastion"
  values = {
    instance_id = module.bastion.instance_id
    sg_id       = module.bastion.sg_id
  }
}
