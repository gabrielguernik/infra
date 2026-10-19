terraform {
  backend "s3" {
    bucket       = "tfstate-965140467182-us-east-1"
    key          = "envs/sandbox/us-east-1/bastion/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
