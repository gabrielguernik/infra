terraform {
  backend "s3" {
    bucket       = "tfstate-965140467182-us-east-1"
    key          = "shared/us-east-1/shared-regional/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
