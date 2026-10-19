# Added after the first apply (which used local state); see README "Bootstrap".
terraform {
  backend "s3" {
    bucket       = "tfstate-965140467182-us-east-1"
    key          = "accounts/sandbox/_global/bootstrap/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
