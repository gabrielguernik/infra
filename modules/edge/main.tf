# Internet edge of an environment: wildcard certificate, ALB security group and optional WAF.
# The ALB itself is created later by the AWS Load Balancer Controller, which uses these.

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
  description = "Name prefix, <env>-<region>."
  type        = string
}

variable "domain" {
  description = "Environment domain, e.g. sandbox.example.click; the certificate covers it and *.domain."
  type        = string
}

variable "zone_id" {
  description = "Hosted zone of the environment domain, for DNS validation."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the ALB security group."
  type        = string
}

variable "enable_waf" {
  description = "Create a WAF web ACL with AWS managed rules (prod: true)."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes per IP before blocking."
  type        = number
  default     = 2000
}

# --- Certificate -------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  domain_name               = "*.${var.domain}"
  subject_alternative_names = [var.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The wildcard and the apex share one validation record, hence allow_overwrite.
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# --- ALB security group ---------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Internet-facing ALB"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-alb"
    Tier = "alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { https = 443, http = 80 } # HTTP only to redirect to HTTPS

  security_group_id = aws_security_group.alb.id
  description       = "${upper(each.key)} from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# Egress stays open on the source side; destination SGs (sg-app) own the ingress rules.
resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id = aws_security_group.alb.id
  description       = "All egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- WAF ---------------------------------------------------------------------------

locals {
  managed_rule_groups = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesAmazonIpReputationList"]
}

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name  = "${var.name}-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value
      priority = rule.key + 1

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-alb"
    sampled_requests_enabled   = true
  }
}

output "certificate_arn" {
  description = "Validated certificate ARN."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "alb_sg_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "waf_acl_arn" {
  description = "WAF web ACL ARN, or null when disabled."
  value       = one(aws_wafv2_web_acl.this[*].arn)
}
