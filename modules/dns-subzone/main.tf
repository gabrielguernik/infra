# Environment subzone, delegated from the parent zone. ExternalDNS is later scoped to this zone only.

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
  description = "Subzone FQDN, e.g. sandbox.example.click."
  type        = string
}

variable "parent_zone_id" {
  description = "Parent hosted zone ID."
  type        = string
}

variable "delegation_ttl" {
  description = "TTL of the NS delegation record. Short while building, 172800 once stable."
  type        = number
  default     = 300
}

resource "aws_route53_zone" "this" {
  name    = var.name
  comment = "Environment zone, managed by dns"
}

resource "aws_route53_record" "delegation" {
  zone_id = var.parent_zone_id
  name    = var.name
  type    = "NS"
  ttl     = var.delegation_ttl
  records = aws_route53_zone.this.name_servers
}

output "zone_id" {
  description = "Subzone ID."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Subzone name."
  value       = aws_route53_zone.this.name
}
