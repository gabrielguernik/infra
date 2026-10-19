variable "account_id" {
  description = "AWS account this stack may run against (guards against applying with the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Provider region. Global stacks use the primary region."
  type        = string
}

variable "domain_name" {
  description = "Registered parent domain."
  type        = string
}

variable "registrar_zone_id" {
  description = "ID of the hosted zone Route 53 Domains created at registration; imported, not recreated."
  type        = string
}
