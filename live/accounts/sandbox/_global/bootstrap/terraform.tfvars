account_id     = "965140467182"
region         = "us-east-1"
github_owner   = "gabrielguernik"
infra_repo     = "infra"
app_repo       = "realworld-app"
parent_domain  = "gg-incode.click"
parent_zone_id = "Z0129084A5AOP8NVXZQO"
env            = "sandbox"

# eks, data and platform are added in Phases 2-3.
stacks = {
  shared-global = {
    state_prefix     = "shared/_global/shared-global"
    ssm_write_prefix = "/shared/_global/shared-global"
  }
  shared-regional = {
    state_prefix     = "shared/us-east-1/shared-regional"
    ssm_write_prefix = "/shared/us-east-1/shared-regional"
  }
  account-baseline = {
    state_prefix     = "accounts/sandbox/_global/account-baseline"
    ssm_write_prefix = "/account/_global/account-baseline"
  }
  regional-baseline = {
    state_prefix     = "accounts/sandbox/us-east-1/regional-baseline"
    ssm_write_prefix = "/account/us-east-1/regional-baseline"
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
  edge = {
    state_prefix      = "envs/sandbox/us-east-1/edge"
    ssm_write_prefix  = "/sandbox/us-east-1/edge"
    ssm_read_prefixes = ["/sandbox/_global/dns", "/sandbox/us-east-1/network"]
  }
}
