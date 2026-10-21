# Data tier: RDS PostgreSQL, ElastiCache Valkey and the application's secrets.
# Both stores live in the private-data subnets (no internet route) and accept connections only from
# sg-app (pods) and sg-bastion (debugging through the SSM tunnel), found by tag.

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

variable "name" {
  description = "Name prefix, <env>-<region>."
  type        = string
}

variable "env" {
  description = "Environment; used to find other stacks' security groups by tag and to name secrets."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private-data subnets."
  type        = list(string)
}

# --- PostgreSQL settings ---

variable "db_engine_version" {
  description = "PostgreSQL major version; RDS applies minor upgrades automatically."
  type        = string
  default     = "18"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage in GB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB."
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "realworld"
}

variable "rds_multi_az" {
  description = "Multi-AZ standby (prod: true)."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (point-in-time recovery window)."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Deletion protection (prod: true)."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (prod: false)."
  type        = bool
  default     = true
}

variable "slow_query_ms" {
  description = "log_min_duration_statement in milliseconds."
  type        = number
  default     = 500
}

# --- Valkey settings ---

variable "cache_engine_version" {
  description = "Valkey version; matches the valkey/valkey image used by the app's local docker compose."
  type        = string
  default     = "8.1"
}

variable "cache_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_replicas" {
  description = "Read replicas; above 0 enables Multi-AZ automatic failover (prod: 1+)."
  type        = number
  default     = 0
}

variable "log_retention_days" {
  description = "Retention of the RDS log groups."
  type        = number
  default     = 30
}

variable "rotation_generation" {
  description = "Bump to rotate the generated secrets (JWT key, database role passwords) on the next apply."
  type        = number
  default     = 1
}

# --- Security groups ---------------------------------------------------------------

data "aws_security_group" "source" {
  for_each = toset(["app", "bastion"])

  vpc_id = var.vpc_id
  tags = {
    Environment = var.env
    Tier        = each.value
    ManagedBy   = "terraform"
  }
}

locals {
  stores = {
    db    = { port = 5432, description = "PostgreSQL" }
    cache = { port = 6379, description = "Valkey" }
  }

  # store x source => one ingress rule each
  ingress = {
    for pair in setproduct(keys(local.stores), ["app", "bastion"]) : "${pair[0]}-from-${pair[1]}" => {
      store  = pair[0]
      source = pair[1]
    }
  }
}

resource "aws_security_group" "store" {
  for_each = local.stores

  name        = "${var.name}-${each.key}"
  description = each.value.description
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-${each.key}"
    Tier = each.key
  }
}

resource "aws_vpc_security_group_ingress_rule" "store" {
  for_each = local.ingress

  security_group_id            = aws_security_group.store[each.value.store].id
  description                  = "${local.stores[each.value.store].description} from sg-${each.value.source}"
  referenced_security_group_id = data.aws_security_group.source[each.value.source].id
  ip_protocol                  = "tcp"
  from_port                    = local.stores[each.value.store].port
  to_port                      = local.stores[each.value.store].port
}

# --- RDS PostgreSQL ------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-postgres"
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-postgres${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  # Static parameter: RDS only accepts it as pending-reboot (already the default on PostgreSQL 15+, set explicitly).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.slow_query_ms)
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created before the instance so Terraform, not RDS, owns retention.
resource "aws_cloudwatch_log_group" "postgres" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}-postgres/${each.value}"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = "realworld_admin"
  # RDS generates, stores and rotates the password in Secrets Manager; Terraform never sees it.
  manage_master_user_password = true

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # Pinned: the API image trusts exactly this CA's root (Prisma reads a single CA certificate).
  # Rotating it means rebuilding the image with the new root first.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.store["db"].id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.name}-postgres-final"

  auto_minor_version_upgrade      = true
  apply_immediately               = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Performance Insights with the free 7-day retention: top SQL and wait events.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  depends_on = [aws_cloudwatch_log_group.postgres]
}

# --- ElastiCache Valkey -------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-valkey"
  subnet_ids = var.subnet_ids
}

# ElastiCache auth tokens may not contain / " @ or spaces.
resource "random_password" "cache_auth" {
  length  = 48
  special = false
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-valkey"
  description          = "RealWorld API cache"
  engine               = "valkey"
  engine_version       = var.cache_engine_version
  node_type            = var.cache_node_type
  port                 = 6379
  parameter_group_name = "default.valkey${split(".", var.cache_engine_version)[0]}"

  num_cache_clusters         = 1 + var.cache_replicas
  automatic_failover_enabled = var.cache_replicas > 0
  multi_az_enabled           = var.cache_replicas > 0

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.store["cache"].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = random_password.cache_auth.result

  apply_immediately = true
}

# --- Application secrets --------------------------------------------------------------
# Generated passwords never enter the Terraform state: they are ephemeral (new on every run) and written to Secrets
# Manager through write-only arguments, only when the secret's version number changes. The version is derived from the
# secret's other contents, so a new endpoint (a rebuilt cache or database) rewrites the secret, and generates a new
# password with it. To rotate by hand, bump rotation_generation.
# The Valkey auth token is the exception: ElastiCache's auth_token is a regular argument, so it is in state.

locals {
  # Secrets Manager wants a positive integer version; a hash of the non-generated contents gives one that changes
  # with them.
  version_of = { for k, v in {
    app = jsonencode([var.rotation_generation, random_password.cache_auth.result, aws_elasticache_replication_group.this.primary_endpoint_address, aws_elasticache_replication_group.this.port])
    db  = jsonencode([var.rotation_generation, aws_db_instance.this.address, aws_db_instance.this.port, aws_db_instance.this.db_name])
  } : k => parseint(substr(sha256(v), 0, 8), 16) + 1 }
}

ephemeral "random_password" "jwt" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name        = "${var.env}/realworld/app"
  description = "RealWorld API secrets: JWT signing key and Valkey auth token"
  # Sandbox is destroyed and rebuilt; a recovery window would block re-creating the same name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string_wo = jsonencode({
    JWT_SECRET       = ephemeral.random_password.jwt.result
    REDIS_AUTH_TOKEN = random_password.cache_auth.result
    REDIS_HOST       = aws_elasticache_replication_group.this.primary_endpoint_address
    REDIS_PORT       = tostring(aws_elasticache_replication_group.this.port)
  })
  secret_string_wo_version = local.version_of["app"]
}

# --- Database roles -------------------------------------------------------------------
# Workloads never use the RDS-managed master user. These are the passwords for the two roles that the
# platform's db-bootstrap Job creates (as master) in the cluster: the migrator owns the schema, the app has DML only.
# Each secret carries the connection details too, so consumers reference it by name and need no endpoints.

locals {
  db_roles = {
    app      = "${var.db_name}_app"
    migrator = "${var.db_name}_migrator"
  }
}

# Alphanumeric only, so the password can go into a connection URL without encoding.
ephemeral "random_password" "db_role" {
  for_each = local.db_roles

  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "db_role" {
  for_each = local.db_roles

  name                    = "${var.env}/realworld/db-${each.key}"
  description             = "PostgreSQL role ${each.value}: credentials and connection details"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_role" {
  for_each = local.db_roles

  secret_id = aws_secretsmanager_secret.db_role[each.key].id
  secret_string_wo = jsonencode({
    username = each.value
    password = ephemeral.random_password.db_role[each.key].result
    host     = aws_db_instance.this.address
    port     = tostring(aws_db_instance.this.port)
    dbname   = aws_db_instance.this.db_name
  })
  # A new password must reach PostgreSQL too: the platform's db-bootstrap Job sets it on its next sync.
  secret_string_wo_version = local.version_of["db"]
}

# --- Outputs --------------------------------------------------------------------------

output "db_endpoint" {
  description = "RDS hostname."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Application database name."
  value       = aws_db_instance.this.db_name
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "cache_endpoint" {
  description = "Valkey primary endpoint hostname."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "cache_port" {
  description = "Valkey port."
  value       = aws_elasticache_replication_group.this.port
}

output "app_secret_arn" {
  description = "Secrets Manager ARN of the application secrets."
  value       = aws_secretsmanager_secret.app.arn
}

output "db_role_secret_arns" {
  description = "Secrets Manager ARNs of the database role credentials (app, migrator)."
  value       = { for k, s in aws_secretsmanager_secret.db_role : k => s.arn }
}

output "db_instance_arn" {
  description = "RDS instance ARN; the RDS-managed master secret carries it in tag aws:rds:primaryDBInstanceArn."
  value       = aws_db_instance.this.arn
}

output "db_sg_id" {
  description = "sg-db ID."
  value       = aws_security_group.store["db"].id
}

output "cache_sg_id" {
  description = "sg-cache ID."
  value       = aws_security_group.store["cache"].id
}
