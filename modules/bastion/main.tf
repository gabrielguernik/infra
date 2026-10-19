# Session Manager bastion: the only way into the private network for people and CI.
# No inbound rules, no public IP, no SSH key. Port forwarding through SSM reaches the private EKS API, RDS and Valkey.

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

variable "vpc_id" {
  description = "VPC of the bastion."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR; the bastion may reach the data tier ports inside it."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the instance."
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    Instance type (the account SCP allows t2/t3/t3a up to medium). Not t3.nano: the organization's
    Amazon Inspector associations install agents on every instance, which exhausts a nano's 0.5 GiB
    and CPU credits and takes the SSM agent offline.
  EOT
  type        = string
  default     = "t3.micro"
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-bastion"
  path               = "/bastion/"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-bastion"
  path = "/bastion/"
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = "${var.name}-bastion"
  description = "SSM bastion: no ingress"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-bastion"
    Tier = "bastion"
  }
}

# SSM agent (through the NAT gateway) and the private EKS API endpoint.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS: SSM and the EKS API"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "data" {
  for_each = { postgres = 5432, valkey = 6379 }

  security_group_id = aws_security_group.this.id
  description       = "${each.key} inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# A new Amazon Linux release replaces the instance instead of patching it in place; it holds no state.
resource "aws_instance" "this" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "${var.name}-bastion" }
}

output "instance_id" {
  description = "Bastion instance ID (SSM target)."
  value       = aws_instance.this.id
}

output "sg_id" {
  description = "Bastion security group ID."
  value       = aws_security_group.this.id
}
