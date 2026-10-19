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

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "realworld"
      Environment = "sandbox"
      Region      = "us-east-1"
      Stack       = "data"
      ManagedBy   = "terraform"
      Repo        = "gabrielguernik/infra"
    }
  }
}
