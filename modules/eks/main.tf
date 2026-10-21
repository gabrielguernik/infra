# EKS cluster with a private-only API endpoint, a small managed system node group, IRSA and the core add-ons.
#
# Security groups:
#   - cluster SG (created by EKS): control plane <-> nodes. This module adds 443 from sg-bastion.
#   - sg-app (Tier=app, owned here): attached to nodes (and so to pods). Ingress from itself and from sg-alb.
# Nodes get both groups through the launch template.

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
  description = "Cluster name, <env>-<region>."
  type        = string
}

variable "env" {
  description = "Environment; used to find other stacks' security groups by tag."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private-app subnets for the control plane ENIs and the nodes."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM principals granted cluster-admin through access entries."
  type        = list(string)
}

variable "app_ports" {
  description = "Pod ports the ALB may reach (target type ip)."
  type        = list(number)
  default     = [3000]
}

variable "node_instance_type" {
  description = "System node instance type (the account SCP allows t2/t3/t3a up to medium)."
  type        = string
  default     = "t3.medium"
}

variable "node_min_size" {
  description = "Minimum system nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum system nodes."
  type        = number
  default     = 3
}

variable "node_max_pods" {
  description = "kubelet maxPods; 110 is the recommended cap with prefix delegation."
  type        = number
  default     = 110
}

variable "imds_hop_limit" {
  description = "IMDSv2 hop limit. 1 keeps pods away from node credentials (IRSA only); 2 is the fallback if an add-on insists on IMDS."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Retention of the control plane log group."
  type        = number
  default     = 30
}

data "aws_partition" "current" {}

locals {
  policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

# --- Security groups owned by other stacks (found by tag) --------------------------

data "aws_security_group" "alb" {
  vpc_id = var.vpc_id
  tags = {
    Environment = var.env
    Tier        = "alb"
    ManagedBy   = "terraform"
  }
}

data "aws_security_group" "bastion" {
  vpc_id = var.vpc_id
  tags = {
    Environment = var.env
    Tier        = "bastion"
    ManagedBy   = "terraform"
  }
}

# --- Cluster ---------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  path               = "/eks/"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "${local.policy_prefix}/AmazonEKSClusterPolicy"
}

# Created before the cluster so Terraform, not EKS, owns its retention.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Never drift into paid extended support; upgrade instead.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

locals {
  cluster_sg_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# The private endpoint's ENIs use the cluster SG; this is the only way in from outside the cluster.
resource "aws_vpc_security_group_ingress_rule" "api_from_bastion" {
  security_group_id            = local.cluster_sg_id
  description                  = "Kubernetes API from the SSM bastion"
  referenced_security_group_id = data.aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# --- Access ----------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# --- sg-app ----------------------------------------------------------------------

# Defined independently of the cluster so a cluster rebuild keeps it (data's rules reference it).
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "EKS nodes and pods"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-app"
    Tier = "app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_self" {
  security_group_id            = aws_security_group.app.id
  description                  = "Node to node and pod to pod"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each = toset([for p in var.app_ports : tostring(p)])

  security_group_id            = aws_security_group.app.id
  description                  = "App port ${each.value} from the ALB"
  referenced_security_group_id = data.aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- IRSA ------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  irsa_roles = {
    vpc-cni = {
      service_account = "kube-system:aws-node"
      policy          = "AmazonEKS_CNI_Policy"
    }
    ebs-csi = {
      service_account = "kube-system:ebs-csi-controller-sa"
      policy          = "service-role/AmazonEBSCSIDriverPolicy"
    }
  }
}

data "aws_iam_policy_document" "irsa_assume" {
  for_each = local.irsa_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_roles

  name               = "${var.name}-${each.key}"
  path               = "/eks/"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.key].json
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = local.irsa_roles

  role       = aws_iam_role.irsa[each.key].name
  policy_arn = "${local.policy_prefix}/${each.value.policy}"
}

# --- Add-ons -----------------------------------------------------------------------

data "aws_eks_addon_version" "this" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"])

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = false # the default version for this Kubernetes release
}

# Created before the nodes so they start with prefix delegation and network policy enforcement.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  service_account_role_arn    = aws_iam_role.irsa["vpc-cni"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  depends_on = [aws_iam_role_policy_attachment.irsa]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# These need running nodes.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  service_account_role_arn    = aws_iam_role.irsa["ebs-csi"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system, aws_iam_role_policy_attachment.irsa]
}

# --- System node group -------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  path               = "/eks/"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# No AmazonEKS_CNI_Policy here: the CNI has its own IRSA role. No AmazonSSMManagedInstanceCore either: nodes are not
# an entry point (no Session Manager shell on them); the bastion is the only one.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_prefix}/${each.value}"
}

resource "aws_launch_template" "system" {
  name_prefix = "${var.name}-system-"

  vpc_security_group_ids = [local.cluster_sg_id, aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  # AL2023 nodeadm configuration, merged by EKS with its own bootstrap config.
  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: ${var.node_max_pods}

    --BOUNDARY--
  EOT
  )

  # The provider's default tags don't reach the instances and volumes the node group launches: copy them here.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.aws_default_tags.this.tags, { Name = "${var.name}-system" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(data.aws_default_tags.this.tags, { Name = "${var.name}-system" })
  }
}

data "aws_default_tags" "this" {}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = [var.node_instance_type]

  # Terraform owns desired_size (= min) while there is no autoscaler. With Karpenter or Cluster Autoscaler, ignore
  # changes to it instead.
  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = {
    "node-role" = "system"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

# --- Outputs -----------------------------------------------------------------------

output "cluster_name" {
  description = "Cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Private API endpoint URL."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "Base64 cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version."
  value       = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer" {
  description = "OIDC issuer host (no scheme), as used in IRSA trust conditions."
  value       = local.oidc_issuer_host
}

output "app_sg_id" {
  description = "sg-app ID."
  value       = aws_security_group.app.id
}

output "cluster_sg_id" {
  description = "EKS-created cluster security group ID."
  value       = local.cluster_sg_id
}

output "node_role_arn" {
  description = "System node IAM role ARN."
  value       = aws_iam_role.node.arn
}
