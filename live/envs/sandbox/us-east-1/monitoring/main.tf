locals {
  name = "${var.env}-${var.region}"
}

module "monitoring" {
  source = "../../../../../modules/monitoring"

  name = local.name
  env  = var.env
}

# Alerts are managed with the Prometheus workspace that evaluates them, in their own module.
module "prometheus_alerts" {
  source = "../../../../../modules/prometheus-alerts"

  workspace_id = module.monitoring.workspace_id
}

module "outputs" {
  source = "../../../../../modules/ssm-outputs"

  prefix = "/${var.env}/${var.region}/monitoring"
  values = {
    amp_workspace_id   = module.monitoring.workspace_id
    amp_workspace_arn  = module.monitoring.workspace_arn
    amp_endpoint       = module.monitoring.prometheus_endpoint
    log_group_name     = module.monitoring.log_group_name
    log_group_arn      = module.monitoring.log_group_arn
    grafana_secret_arn = module.monitoring.grafana_secret_arn
  }
}
