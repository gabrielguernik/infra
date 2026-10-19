terraform {
  backend "s3" {
    bucket       = "tfstate-965140467182-us-east-1"
    key          = "accounts/sandbox/_global/account-baseline/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
