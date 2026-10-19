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
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "realworld"
      Environment = "account"
      Region      = "global"
      Stack       = "bootstrap"
      ManagedBy   = "terraform"
      Repo        = "gabrielguernik/infra"
    }
  }
}
