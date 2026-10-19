variable "account_id" {
  description = "AWS account this stack may run against (guards against applying with the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Provider region. Global stacks use the primary region."
  type        = string
}

variable "account_alias" {
  description = "Account alias (globally unique)."
  type        = string
}
