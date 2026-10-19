# Parent hosted zone and the registrar delegation pointing at it.
# The zone is created by Route 53 Domains at registration and imported, never recreated:
# a new zone gets new name servers and silently breaks delegation.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "domain_name" {
  description = "Registered domain, e.g. example.click."
  type        = string
}

resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "Parent zone, managed by shared-global"

  lifecycle {
    prevent_destroy = true
  }
}

# Keeps the registrar's name servers equal to the zone's, whatever happens to either.
resource "aws_route53domains_registered_domain" "this" {
  domain_name = var.domain_name
  auto_renew  = true

  admin_privacy      = true
  registrant_privacy = true
  tech_privacy       = true
  billing_privacy    = true

  dynamic "name_server" {
    for_each = aws_route53_zone.this.name_servers
    content {
      name = name_server.value
    }
  }
}

output "zone_id" {
  description = "Parent hosted zone ID."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Parent zone name."
  value       = aws_route53_zone.this.name
}
