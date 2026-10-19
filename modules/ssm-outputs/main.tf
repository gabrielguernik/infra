# Publishes a stack's interface to SSM Parameter Store under /<env>/<region>/<stack>/.
# Consumers read these paths; nobody reads another stack's state.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "prefix" {
  description = "Path prefix, e.g. /sandbox/us-east-1/network (no trailing slash)."
  type        = string

  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+[^/]$", var.prefix))
    error_message = "prefix must start with / and must not end with /."
  }
}

variable "values" {
  description = "Scalar outputs: name => value."
  type        = map(string)
  default     = {}
}

variable "list_values" {
  description = "List outputs, stored as StringList: name => list."
  type        = map(list(string))
  default     = {}
}

resource "aws_ssm_parameter" "string" {
  for_each = var.values

  name  = "${var.prefix}/${each.key}"
  type  = "String"
  value = each.value
}

resource "aws_ssm_parameter" "list" {
  for_each = var.list_values

  name  = "${var.prefix}/${each.key}"
  type  = "StringList"
  value = join(",", each.value)
}

output "names" {
  description = "All parameter names written."
  value       = concat([for p in aws_ssm_parameter.string : p.name], [for p in aws_ssm_parameter.list : p.name])
}
