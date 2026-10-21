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

variable "cluster_version" {
  description = "Kubernetes version."
  type        = string
}

variable "admin_principal_arns" {
  description = "IAM principals with cluster-admin access entries."
  type        = list(string)
}

variable "node_min_size" {
  description = "Minimum system nodes."
  type        = number
}

variable "argocd_admin_password_version" {
  description = "Version of the ArgoCD admin password; bump to generate and store a new one."
  type        = number
  default     = 1
}
