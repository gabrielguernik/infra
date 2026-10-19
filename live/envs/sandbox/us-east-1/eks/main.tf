locals {
  name    = "${var.env}-${var.region}"
  network = "/${var.env}/${var.region}/network"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.network}/vpc_id"
}

data "aws_ssm_parameter" "private_app_subnet_ids" {
  name = "${local.network}/private_app_subnet_ids"
}

module "eks" {
  source = "../../../../../modules/eks"

  name                 = local.name
  env                  = var.env
  cluster_version      = var.cluster_version
  vpc_id               = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  subnet_ids           = split(",", nonsensitive(data.aws_ssm_parameter.private_app_subnet_ids.value))
  admin_principal_arns = var.admin_principal_arns
  node_min_size        = var.node_min_size
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/eks"
  values = {
    cluster_name      = module.eks.cluster_name
    cluster_endpoint  = module.eks.cluster_endpoint
    cluster_ca        = module.eks.cluster_ca
    cluster_version   = module.eks.cluster_version
    oidc_provider_arn = module.eks.oidc_provider_arn
    oidc_issuer       = module.eks.oidc_issuer
    app_sg_id         = module.eks.app_sg_id
    cluster_sg_id     = module.eks.cluster_sg_id
    node_role_arn     = module.eks.node_role_arn
  }
}
