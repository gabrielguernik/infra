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

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "cache_node_type" {
  description = "ElastiCache node type."
  type        = string
}

variable "rds_multi_az" {
  description = "Multi-AZ RDS standby."
  type        = bool
}

variable "cache_replicas" {
  description = "Valkey read replicas (above 0 enables failover)."
  type        = number
}
