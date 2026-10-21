# Per-environment observability backends: the Amazon Managed Prometheus workspace that Grafana Alloy writes to and
# Grafana reads from, the CloudWatch log group that Fluent Bit ships container logs to, saved Logs Insights queries,
# and Grafana's admin credentials. The in-cluster parts (Alloy, Grafana, Fluent Bit) are installed by ArgoCD from
# the gitops repo; their IRSA roles are in the platform stack. Alert rules are in modules/prometheus-alerts.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

variable "name" {
  description = "Name prefix, <env>-<region> (also the EKS cluster name)."
  type        = string
}

variable "env" {
  description = "Environment; Secrets Manager names are <env>/..."
  type        = string
}

variable "grafana_password_version" {
  description = "Version of the Grafana admin password; bump to generate and store a new one."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Retention of the container log group."
  type        = number
  default     = 30
}

resource "aws_prometheus_workspace" "this" {
  alias = var.name
}

# Terraform owns the group (Fluent Bit may not create groups), so a teardown leaves no orphaned log groups.
resource "aws_cloudwatch_log_group" "containers" {
  name              = "/eks/${var.name}/containers"
  retention_in_days = var.log_retention_days
}

# Fluent Bit merges each JSON log line into the record, so the API's fields (reqId, res.statusCode, responseTime,
# req.url) are top-level and queryable. Log streams are <namespace>.<pod>.
locals {
  queries = {
    "request-by-reqid" = {
      title = "Request by reqId"
      query = <<-EOT
        fields @timestamp, level, msg, req.method, req.url, res.statusCode, responseTime, err.message
        | filter reqId = "REPLACE_WITH_REQ_ID"
        | sort @timestamp asc
      EOT
    }
    "api-5xx" = {
      title = "API 5xx"
      query = <<-EOT
        fields @timestamp, reqId, req.method, req.url, res.statusCode, responseTime, err.message
        | filter service = "realworld-api" and res.statusCode >= 500
        | sort @timestamp desc
        | limit 100
      EOT
    }
    "slow-requests" = {
      title = "Slow requests (> 1 s)"
      query = <<-EOT
        fields @timestamp, reqId, req.method, req.url, res.statusCode, responseTime
        | filter service = "realworld-api" and responseTime > 1000
        | sort responseTime desc
        | limit 100
      EOT
    }
  }
}

resource "aws_cloudwatch_query_definition" "this" {
  for_each = local.queries

  name            = "${var.name}/${each.value.title}"
  log_group_names = [aws_cloudwatch_log_group.containers.name]
  query_string    = each.value.query
}

# Ephemeral, written through a write-only argument: the password never enters the Terraform state. Bump
# grafana_password_version to rotate it.
ephemeral "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name        = "${var.env}/monitoring/grafana"
  description = "Grafana admin credentials (read by External Secrets in the monitoring namespace)"
  # Sandbox is destroyed and rebuilt; a recovery window would block re-creating the same name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string_wo = jsonencode({
    admin-user     = "admin"
    admin-password = ephemeral.random_password.grafana_admin.result
  })
  secret_string_wo_version = var.grafana_password_version
}

output "workspace_id" {
  description = "AMP workspace ID (ws-...). Hardcoded in the gitops Alloy and Grafana Applications."
  value       = aws_prometheus_workspace.this.id
}

output "workspace_arn" {
  description = "AMP workspace ARN; scopes the Alloy and Grafana IRSA policies."
  value       = aws_prometheus_workspace.this.arn
}

output "prometheus_endpoint" {
  description = "AMP Prometheus-compatible endpoint (ends with /)."
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "log_group_name" {
  description = "Container log group."
  value       = aws_cloudwatch_log_group.containers.name
}

output "log_group_arn" {
  description = "Container log group ARN (without the :* suffix)."
  value       = aws_cloudwatch_log_group.containers.arn
}

output "grafana_secret_arn" {
  description = "Grafana admin credentials secret."
  value       = aws_secretsmanager_secret.grafana.arn
}
