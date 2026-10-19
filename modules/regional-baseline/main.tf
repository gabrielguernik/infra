# Per-region account guardrails.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}
