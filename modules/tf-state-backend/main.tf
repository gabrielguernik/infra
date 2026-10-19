# Terraform state bucket: one per account and region.
# Locking uses S3 native lockfiles (use_lockfile = true), so there is no DynamoDB table.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "bucket_name" {
  description = "State bucket name, tfstate-<account>-<region>."
  type        = string
}

variable "prefix_restrictions" {
  description = <<-EOT
    CI role name => { role_arn, prefix }: the only state key prefix that role may touch.
    Enforced with an explicit deny in the bucket policy, on top of the roles' own IAM policies.
  EOT
  type = map(object({
    role_arn = string
    prefix   = string
  }))
  default = {}
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep old state versions."
  type        = number
  default     = 90
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # One deny per CI role: any object outside its own prefix is off limits.
  # The prefix also covers the .tflock lockfile next to the state object.
  dynamic "statement" {
    for_each = var.prefix_restrictions

    content {
      sid           = "Deny${replace(title(replace(statement.key, "-", " ")), " ", "")}OutsideOwnPrefix"
      effect        = "Deny"
      actions       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      not_resources = ["${aws_s3_bucket.this.arn}/${statement.value.prefix}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = [statement.value.role_arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

output "bucket_name" {
  description = "State bucket name."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "State bucket ARN."
  value       = aws_s3_bucket.this.arn
}
