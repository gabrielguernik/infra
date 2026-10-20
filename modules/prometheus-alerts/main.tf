# Prometheus alerting rules, evaluated by Amazon Managed Prometheus on the environment's workspace.
#
# Each file in rules/ is a plain Prometheus rules file (lintable with `promtool check rules`) and becomes one rule
# group namespace named after the file. Alerts are not delivered anywhere yet (no AMP alert manager definition):
# firing alerts are visible in Grafana's Alerting view and in the workspace's api/v1/alerts. See the README.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "workspace_id" {
  description = "AMP workspace that evaluates the rules."
  type        = string
}

locals {
  rule_files = { for f in fileset("${path.module}/rules", "*.yaml") : trimsuffix(f, ".yaml") => "${path.module}/rules/${f}" }
}

resource "aws_prometheus_rule_group_namespace" "this" {
  for_each = local.rule_files

  name         = each.key
  workspace_id = var.workspace_id
  data         = file(each.value)
}

output "namespaces" {
  description = "Rule group namespaces created in the workspace."
  value       = keys(aws_prometheus_rule_group_namespace.this)
}
