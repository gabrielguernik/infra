# IRSA roles for the in-cluster platform components that ArgoCD installs from the gitops repo.
#
# IAM only: no Kubernetes or Helm providers, so CI can plan and apply this stack without reaching the private API.
# Role names are fixed (<name>-<component>, path /irsa/) because the gitops repo hardcodes their ARNs; a rebuild of
# this stack produces the same ARNs and needs no gitops commit.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
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

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer host without scheme, as used in IRSA trust conditions."
  type        = string
}

variable "zone_id" {
  description = "Route 53 zone ExternalDNS may write to (the environment subzone)."
  type        = string
}

variable "db_instance_arn" {
  description = "RDS instance ARN; scopes access to its RDS-managed master secret (tag aws:rds:primaryDBInstanceArn)."
  type        = string
}

variable "amp_workspace_arn" {
  description = "Amazon Managed Prometheus workspace that Alloy writes to and Grafana reads from."
  type        = string
}

variable "log_group_arn" {
  description = "Container log group (monitoring stack) that Fluent Bit writes to and Grafana queries."
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  secret_arn_prefix = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.env}/realworld"

  # Secrets Manager appends a random 6-character suffix to secret ARNs.
  role_secrets = ["${local.secret_arn_prefix}/db-app-??????", "${local.secret_arn_prefix}/db-migrator-??????"]

  roles = {
    aws-load-balancer-controller = {
      service_account = "kube-system:aws-load-balancer-controller"
      # Vendored unchanged from the controller release that gitops pins (docs/install/iam_policy.json, v3.6.0),
      # so upgrades are a file replace and a diff.
      policy = jsonencode(jsondecode(file("${path.module}/policies/aws-load-balancer-controller.json")))
    }

    external-dns = {
      service_account = "external-dns:external-dns"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "OwnZoneOnly"
            Effect   = "Allow"
            Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
            Resource = "arn:aws:route53:::hostedzone/${var.zone_id}"
          },
          {
            Sid      = "Discovery"
            Effect   = "Allow"
            Action   = ["route53:ListHostedZones"]
            Resource = "*"
          },
        ]
      })
    }

    # The app namespace: its own secrets only. It cannot read the RDS master secret.
    secrets-realworld = {
      service_account = "realworld:secrets-reader"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "AppSecrets"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = concat(["${local.secret_arn_prefix}/app-??????"], local.role_secrets)
        }]
      })
    }

    # db-bootstrap: the master secret (to create roles) plus the two role secrets (to set their passwords).
    secrets-db-admin = {
      service_account = "db-admin:secrets-reader"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "RoleSecrets"
            Effect   = "Allow"
            Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
            Resource = local.role_secrets
          },
          {
            # The master secret's name and ARN change whenever the instance is recreated; its tag doesn't.
            Sid       = "MasterSecret"
            Effect    = "Allow"
            Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
            Resource  = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:rds!*"
            Condition = { StringEquals = { "secretsmanager:ResourceTag/aws:rds:primaryDBInstanceArn" = var.db_instance_arn } }
          },
          {
            # External Secrets finds the master secret by that tag with BatchGetSecretValue (filters), which needs
            # these unscoped actions; each secret it returns is still authorized by GetSecretValue above.
            Sid      = "FindByTag"
            Effect   = "Allow"
            Action   = ["secretsmanager:ListSecrets", "secretsmanager:BatchGetSecretValue"]
            Resource = "*"
          },
        ]
      })
    }

    # --- Observability -------------------------------------------------------------------------------------------

    # Grafana Alloy scrapes the app's /metrics, reads the API load balancer's metrics from CloudWatch (user-facing
    # errors, including the 503s the ALB answers itself when no pod is ready), and remote-writes both to AMP.
    alloy = {
      service_account = "monitoring:alloy"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "RemoteWrite"
            Effect   = "Allow"
            Action   = ["aps:RemoteWrite"]
            Resource = var.amp_workspace_arn
          },
          {
            # CloudWatch metrics and the tagging API (resource discovery by tag) have no resource-level permissions.
            # The exporter also labels metrics with the account alias.
            Sid      = "ReadCloudWatchMetrics"
            Effect   = "Allow"
            Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "tag:GetResources", "iam:ListAccountAliases"]
            Resource = "*"
          },
        ]
      })
    }

    # Grafana: read-only on AMP (including AMP's rules and alerts), CloudWatch metrics and the container logs.
    grafana = {
      service_account = "monitoring:grafana"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "QueryPrometheus"
            Effect   = "Allow"
            Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata", "aps:ListRules", "aps:ListAlerts"]
            Resource = var.amp_workspace_arn
          },
          {
            # CloudWatch metrics have no resource-level permissions.
            Sid      = "ReadCloudWatchMetrics"
            Effect   = "Allow"
            Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
            Resource = "*"
          },
          {
            Sid      = "QueryContainerLogs"
            Effect   = "Allow"
            Action   = ["logs:StartQuery", "logs:GetLogEvents", "logs:GetLogGroupFields", "logs:FilterLogEvents"]
            Resource = [var.log_group_arn, "${var.log_group_arn}:*"]
          },
          {
            Sid      = "LogsUnscoped"
            Effect   = "Allow"
            Action   = ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StopQuery", "logs:DescribeQueries"]
            Resource = "*"
          },
          {
            # Used by the CloudWatch data source to list resources and regions in its query editor. No EC2 instance
            # lookups: the dashboards cover the ALB, RDS, Valkey and NAT, not instances.
            Sid      = "Discovery"
            Effect   = "Allow"
            Action   = ["tag:GetResources", "ec2:DescribeRegions"]
            Resource = "*"
          },
        ]
      })
    }

    # Fluent Bit writes container logs to the one Terraform-owned log group; it can't create groups.
    fluent-bit = {
      service_account = "logging:fluent-bit"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "WriteContainerLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = [var.log_group_arn, "${var.log_group_arn}:*"]
        }]
      })
    }

    # The monitoring namespace's secrets: Grafana's admin credentials only (Secrets Manager appends a 6-character suffix).
    secrets-monitoring = {
      service_account = "monitoring:secrets-reader"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "MonitoringSecrets"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.env}/monitoring/grafana-??????"
        }]
      })
    }
  }
}

data "aws_iam_policy_document" "assume" {
  for_each = local.roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name               = "${var.name}-${each.key}"
  path               = "/irsa/"
  description        = "IRSA for ${each.value.service_account}"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
}

resource "aws_iam_role_policy" "this" {
  for_each = local.roles

  name   = each.key
  role   = aws_iam_role.this[each.key].id
  policy = each.value.policy
}

output "role_arns" {
  description = "Component => IRSA role ARN."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}
