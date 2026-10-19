terraform {
  backend "s3" {
    bucket       = "tfstate-965140467182-us-east-1"
    key          = "shared/_global/shared-global/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
