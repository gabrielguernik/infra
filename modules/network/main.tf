# Three-tier VPC across N AZs:
#   public       - ALB and NAT gateways
#   private-app  - nodes and pods (large: the VPC CNI gives every pod a VPC IP)
#   private-data - RDS and ElastiCache; no route to the internet

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "name" {
  description = "Name prefix, <env>-<region>."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR (/16), from docs/cidr-plan.md."
  type        = string
}

variable "az_count" {
  description = "Number of AZs."
  type        = number
  default     = 3
}

variable "cluster_name" {
  description = "EKS cluster that will use this VPC; tags subnets for the ALB controller and Karpenter."
  type        = string
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (sandbox) instead of one per AZ (prod)."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Interface endpoints for ECR, STS, Logs and Secrets Manager (cost per AZ; prod: true)."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Services that get an interface endpoint when enabled."
  type        = set(string)
  default     = ["ecr.api", "ecr.dkr", "sts", "logs", "secretsmanager"]
}

variable "flow_log_destination_arn" {
  description = "S3 ARN (bucket/prefix) for VPC flow logs."
  type        = string
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 layout: public /24 at .0-.2, data /24 at .10-.12, app /19 at .32, .64, .96.
  public_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i)]
  data_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, 10 + i)]
  app_cidrs    = [for i in range(var.az_count) : cidrsubnet(var.cidr, 3, 1 + i)]

  nat_count = var.single_nat_gateway ? 1 : var.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

# Lock down the default SG so nothing uses it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# --- Subnets -----------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.public_cidrs[count.index]

  tags = {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "app" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.app_cidrs[count.index]

  tags = {
    Name                              = "${var.name}-app-${local.azs[count.index]}"
    Tier                              = "app"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

resource "aws_subnet" "data" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.data_cidrs[count.index]

  tags = {
    Name = "${var.name}-data-${local.azs[count.index]}"
    Tier = "data"
  }
}

# --- Routing -------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

# One table per AZ so switching to per-AZ NAT only changes routes, not associations.
resource "aws_route_table" "app" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-app-${local.azs[count.index]}" }
}

resource "aws_route" "app_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "app" {
  count = var.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Data tier: local routes only.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-data" }
}

resource "aws_route_table_association" "data" {
  count = var.az_count

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# --- Endpoints -------------------------------------------------------------------

# Free; keeps ECR layer pulls (served from S3) off the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id

  tags = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "vpce" {
  name        = "${var.name}-vpce"
  description = "Interface VPC endpoints: HTTPS from the private-app subnets"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name}-vpce"
    Tier = "vpce"
  }
}

# By CIDR rather than sg-app, so network does not depend on eks.
resource "aws_vpc_security_group_ingress_rule" "vpce_https" {
  count = var.az_count

  security_group_id = aws_security_group.vpce.id
  description       = "HTTPS from private-app ${local.azs[count.index]}"
  cidr_ipv4         = local.app_cidrs[count.index]
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? var.interface_endpoint_services : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.vpce.id]

  tags = { Name = "${var.name}-${each.key}" }
}

# --- Flow logs -------------------------------------------------------------------

# To the log archive in S3 (Parquet, hourly partitions): far cheaper than CloudWatch Logs; query with Athena.
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = var.flow_log_destination_arn
  max_aggregation_interval = 600

  destination_options {
    file_format                = "parquet"
    per_hour_partition         = true
    hive_compatible_partitions = true
  }

  tags = { Name = "${var.name}-flow-logs" }
}

# --- Outputs ---------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZs in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private-app subnet IDs."
  value       = aws_subnet.app[*].id
}

output "private_data_subnet_ids" {
  description = "Private-data subnet IDs."
  value       = aws_subnet.data[*].id
}

output "private_app_cidrs" {
  description = "Private-app subnet CIDRs."
  value       = local.app_cidrs
}

output "vpce_sg_id" {
  description = "Security group of the interface endpoints."
  value       = aws_security_group.vpce.id
}

output "nat_public_ips" {
  description = "NAT gateway public IPs (egress IPs for allow-lists)."
  value       = aws_eip.nat[*].public_ip
}
