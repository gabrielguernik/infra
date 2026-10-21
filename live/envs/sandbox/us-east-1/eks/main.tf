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
  vpc_id               = data.aws_ssm_parameter.vpc_id.insecure_value
  subnet_ids           = split(",", data.aws_ssm_parameter.private_app_subnet_ids.insecure_value)
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

# ArgoCD's admin password, generated here because ArgoCD runs on this cluster. Ephemeral and written through a
# write-only argument, so it never enters the state. The gitops install pipeline (role ci/argocd-<cluster>, which reads
# <env>/argocd/*) sets it as ArgoCD's admin password. Bump argocd_admin_password_version to rotate it.
ephemeral "random_password" "argocd_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "argocd_admin" {
  name                    = "${var.env}/argocd/${local.name}/admin"
  description             = "ArgoCD admin password of cluster ${local.name} (set by the gitops install pipeline)"
  recovery_window_in_days = 0 # sandbox is destroyed and rebuilt
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id                = aws_secretsmanager_secret.argocd_admin.id
  secret_string_wo         = ephemeral.random_password.argocd_admin.result
  secret_string_wo_version = var.argocd_admin_password_version
}
