output "state_bucket" {
  description = "Terraform state bucket."
  value       = module.state_backend.bucket_name
}

output "ci_role_arns" {
  description = "CI role name => ARN."
  value       = module.ci_roles.role_arns
}
