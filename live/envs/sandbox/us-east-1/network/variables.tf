variable "account_id" {
  description = "AWS account this stack may run against (guards against applying with the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Provider region. Global stacks use the primary region."
  type        = string
}

variable "env" {
  description = "Environment name."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR from docs/cidr-plan.md."
  type        = string
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs."
  type        = bool
}

variable "enable_interface_endpoints" {
  description = "Interface endpoints for ECR, STS, Logs and Secrets Manager."
  type        = bool
}
