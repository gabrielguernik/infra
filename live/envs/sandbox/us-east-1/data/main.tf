locals {
  network = "/${var.env}/${var.region}/network"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.network}/vpc_id"
}

data "aws_ssm_parameter" "private_data_subnet_ids" {
  name = "${local.network}/private_data_subnet_ids"
}

module "data" {
  source = "../../../../../modules/data"

  name              = "${var.env}-${var.region}"
  env               = var.env
  vpc_id            = data.aws_ssm_parameter.vpc_id.insecure_value
  subnet_ids        = split(",", data.aws_ssm_parameter.private_data_subnet_ids.insecure_value)
  db_instance_class = var.db_instance_class
  cache_node_type   = var.cache_node_type
  rds_multi_az      = var.rds_multi_az
  cache_replicas    = var.cache_replicas
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/data"
  values = {
    db_endpoint            = module.data.db_endpoint
    db_port                = tostring(module.data.db_port)
    db_name                = module.data.db_name
    db_master_secret_arn   = module.data.db_master_secret_arn
    cache_endpoint         = module.data.cache_endpoint
    cache_port             = tostring(module.data.cache_port)
    app_secret_arn         = module.data.app_secret_arn
    db_app_secret_arn      = module.data.db_role_secret_arns["app"]
    db_migrator_secret_arn = module.data.db_role_secret_arns["migrator"]
    db_instance_arn        = module.data.db_instance_arn
    db_sg_id               = module.data.db_sg_id
    cache_sg_id            = module.data.cache_sg_id
  }
}
