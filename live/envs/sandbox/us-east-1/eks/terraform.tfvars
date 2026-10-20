account_id      = "965140467182"
region          = "us-east-1"
env             = "sandbox"
cluster_version = "1.36"
node_min_size   = 2

# The gitops pipeline's role installs ArgoCD (CRDs, ClusterRoles), so it needs cluster-admin.
# tf-platform needs no entry: the platform stack is IAM only.
admin_principal_arns = [
  "arn:aws:iam::965140467182:user/gabriel_guernik",
  "arn:aws:iam::965140467182:role/ci/argocd-sandbox-us-east-1",
]
