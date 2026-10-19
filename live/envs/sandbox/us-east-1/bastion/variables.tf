variable "account_id" {
  description = "AWS account this stack may run against (guards against applying with the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Provider region."
  type        = string
}

variable "env" {
  description = "Environment name."
  type        = string
}
