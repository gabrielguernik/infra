# Account-wide guardrails: account alias and S3 account-level Block Public Access.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "account_alias" {
  description = "Account alias (globally unique)."
  type        = string
}

resource "aws_iam_account_alias" "this" {
  account_alias = var.account_alias
}

resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
