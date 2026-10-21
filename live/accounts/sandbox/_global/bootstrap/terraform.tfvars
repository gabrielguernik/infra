account_id      = "965140467182"
region          = "us-east-1"
github_owner    = "gabrielguernik"
github_owner_id = "35024789"
infra_repo      = { name = "infra", id = "1425953183" }
app_repo        = { name = "realworld-app", id = "1425953552" }
gitops_repo     = { name = "gitops", id = "1426997794" }
parent_domain   = "gg-incode.click"
parent_zone_id  = "Z0129084A5AOP8NVXZQO"
env             = "sandbox"

# In apply order: CI applies affected stacks in this order (scripts/ci/stacks.py). bootstrap comes first: it creates
# the roles and permissions the other stacks' CI runs use.
stacks = {
  bootstrap = {
    state_prefix     = "accounts/sandbox/_global/bootstrap"
    ssm_write_prefix = "/account/_global/bootstrap"
  }
  shared-global = {
    state_prefix     = "shared/_global/shared-global"
    ssm_write_prefix = "/shared/_global/shared-global"
  }
  shared-regional = {
    state_prefix     = "shared/us-east-1/shared-regional"
    ssm_write_prefix = "/shared/us-east-1/shared-regional"
  }
  account-baseline = {
    state_prefix = "accounts/sandbox/_global/account-baseline"
  }
  regional-baseline = {
    state_prefix = "accounts/sandbox/us-east-1/regional-baseline"
  }
  dns = {
    state_prefix      = "envs/sandbox/_global/dns"
    ssm_write_prefix  = "/sandbox/_global/dns"
    ssm_read_prefixes = ["/shared/_global/shared-global"]
  }
  network = {
    state_prefix      = "envs/sandbox/us-east-1/network"
    ssm_write_prefix  = "/sandbox/us-east-1/network"
    ssm_read_prefixes = ["/shared/us-east-1/shared-regional"]
  }
  bastion = {
    state_prefix      = "envs/sandbox/us-east-1/bastion"
    ssm_write_prefix  = "/sandbox/us-east-1/bastion"
    ssm_read_prefixes = ["/sandbox/us-east-1/network"]
  }
  edge = {
    state_prefix      = "envs/sandbox/us-east-1/edge"
    ssm_write_prefix  = "/sandbox/us-east-1/edge"
    ssm_read_prefixes = ["/sandbox/_global/dns", "/sandbox/us-east-1/network"]
  }
  eks = {
    state_prefix      = "envs/sandbox/us-east-1/eks"
    ssm_write_prefix  = "/sandbox/us-east-1/eks"
    ssm_read_prefixes = ["/sandbox/us-east-1/network"]
  }
  data = {
    state_prefix      = "envs/sandbox/us-east-1/data"
    ssm_write_prefix  = "/sandbox/us-east-1/data"
    ssm_read_prefixes = ["/sandbox/us-east-1/network"]
    plan_secrets      = ["sandbox/realworld/*"]
  }
  monitoring = {
    state_prefix     = "envs/sandbox/us-east-1/monitoring"
    ssm_write_prefix = "/sandbox/us-east-1/monitoring"
    plan_secrets     = ["sandbox/monitoring/*"]
  }
  platform = {
    state_prefix      = "envs/sandbox/us-east-1/platform"
    ssm_write_prefix  = "/sandbox/us-east-1/platform"
    ssm_read_prefixes = ["/sandbox/_global/dns", "/sandbox/us-east-1/eks", "/sandbox/us-east-1/data", "/sandbox/us-east-1/monitoring"]
  }
}

# Clusters whose ArgoCD is installed by the gitops pipeline (role ci/argocd-<cluster>).
argocd_clusters = ["sandbox-us-east-1"]
