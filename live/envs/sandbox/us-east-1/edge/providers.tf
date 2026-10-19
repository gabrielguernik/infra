terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "realworld"
      Environment = "sandbox"
      Region      = "us-east-1"
      Stack       = "edge"
      ManagedBy   = "terraform"
      Repo        = "gabrielguernik/infra"
    }
  }
}
