module "ecr" {
  source = "../../../../modules/ecr-repos"

  repositories     = ["realworld-api"]
  pull_account_ids = [var.account_id]
}

module "log_archive" {
  source = "../../../../modules/log-archive"

  bucket_name = "logs-${var.account_id}-${var.region}"
}

module "outputs" {
  source = "../../../../modules/ssm-outputs"

  prefix = "/shared/${var.region}/shared-regional"
  values = {
    ecr_api_url     = module.ecr.repository_urls["realworld-api"]
    log_bucket_name = module.log_archive.bucket_name
    log_bucket_arn  = module.log_archive.bucket_arn
  }
}
