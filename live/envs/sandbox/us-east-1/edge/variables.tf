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

variable "enable_waf" {
  description = "WAF web ACL in front of the ALB."
  type        = bool
}
