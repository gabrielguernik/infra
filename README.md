# infra

Terraform for the RealWorld sandbox on AWS. The code is split into layered stacks: each has its own state, CI role and a small published interface in SSM Parameter Store.

> Account 965140467182 is limited to **us-east-1** by an organization SCP, so every regional stack lives in us-east-1.

## Layout

```
modules/   reusable modules (no backend, no provider config)
live/      one folder per stack instance; backend, provider, module calls, SSM reads/writes, tfvars
  accounts/sandbox/_global/{bootstrap,account-baseline}
  accounts/sandbox/us-east-1/regional-baseline
  shared/_global/shared-global
  shared/us-east-1/shared-regional
  envs/sandbox/_global/dns
  envs/sandbox/us-east-1/{network,edge}
  envs/prod/...   stub tfvars showing the prod toggles; never applied
docs/      cidr-plan.md
```

## Stack catalogue

| Stack | Path | Contents | Reads from SSM |
|---|---|---|---|
| bootstrap | `accounts/sandbox/_global/bootstrap` | State bucket, GitHub OIDC provider, CI roles | — |
| shared-global | `shared/_global/shared-global` | Parent zone `gg-incode.click` (imported), registrar name servers | — |
| shared-regional | `shared/us-east-1/shared-regional` | ECR repos, log archive bucket | — |
| account-baseline | `accounts/sandbox/_global/account-baseline` | Account alias, S3 account-level Block Public Access | — |
| regional-baseline | `accounts/sandbox/us-east-1/regional-baseline` | EBS encryption by default | — |
| dns | `envs/sandbox/_global/dns` | `sandbox.gg-incode.click` zone + delegation | shared-global |
| network | `envs/sandbox/us-east-1/network` | VPC, subnets, NAT, S3 gateway + interface endpoints, `sg-vpce`, flow logs | shared-regional |
| edge | `envs/sandbox/us-east-1/edge` | Wildcard ACM certificate, `sg-alb`, optional WAF | dns, network |

Every stack publishes its outputs under `/<env>/<region>/<stack>/<name>` (`env` is `account`, `shared` or the environment; `region` is `_global` for global stacks).
List them with:

```bash
aws ssm get-parameters-by-path --path /sandbox --recursive --query 'Parameters[].[Name,Value]' --output table
```

## Running a stack

Plain Terraform, one stack at a time:

```bash
S=live/envs/sandbox/us-east-1/network
terraform -chdir=$S init -input=false
terraform -chdir=$S plan -input=false -out=tfplan
terraform -chdir=$S apply -input=false tfplan
```

Each provider sets `allowed_account_ids`, so a stack refuses to run against any other account.

### Apply order

1. `live/accounts/sandbox/_global/bootstrap`: admin only, see below
2. `live/shared/_global/shared-global`
3. `live/shared/us-east-1/shared-regional`
4. `live/accounts/sandbox/_global/account-baseline`
5. `live/accounts/sandbox/us-east-1/regional-baseline`
6. `live/envs/sandbox/_global/dns`
7. `live/envs/sandbox/us-east-1/network`
8. `live/envs/sandbox/us-east-1/edge`

### Destroy order (environment, between work sessions)

```bash
terraform -chdir=live/envs/sandbox/us-east-1/edge destroy
terraform -chdir=live/envs/sandbox/us-east-1/network destroy
```

`dns` and everything above it stay up: they cost almost nothing, and keeping them keeps delegation stable.
Destroying network removes the NAT gateway (about $35/month) and the interface endpoints (5 services × 3 AZs, about
$110/month), the main running costs of Phase 1.

## Setup from zero

1. **Domain.** Register it in Route 53 Domains (us-east-1 API). Registration creates a hosted zone; put its ID in
   `shared-global/terraform.tfvars` (`registrar_zone_id`) and in `bootstrap/terraform.tfvars` (`parent_zone_id`).
2. **Bootstrap**, with admin credentials:
   ```bash
   S=live/accounts/sandbox/_global/bootstrap
   mv $S/backend.tf $S/backend.tf.off          # first run uses local state: the bucket doesn't exist yet
   terraform -chdir=$S init && terraform -chdir=$S apply
   mv $S/backend.tf.off $S/backend.tf
   terraform -chdir=$S init -migrate-state      # copies local state into the new bucket
   rm $S/terraform.tfstate*
   ```
   CI never applies bootstrap: it creates the roles CI uses.
3. Apply the remaining stacks in order.

## State

- Bucket `tfstate-965140467182-us-east-1`: versioning, SSE-S3, Block Public Access, TLS-only, old versions expire after 90 days.
- Locking with S3 native lockfiles (`use_lockfile = true`), so there is no DynamoDB table.
- The key equals the stack's folder under `live/`.
- The bucket policy denies each `tf-<stack>` role every object outside its own prefix, so no CI role can read another stack's state.

## CI roles

GitHub Actions authenticates through OIDC. There are no long-lived keys.

| Role | Trusted subjects | Can do |
|---|---|---|
| `ci/tf-<stack>` | `repo:gabrielguernik/infra` on `main` and pull requests | Its own state prefix, its own SSM path, the SSM paths it reads, and the service actions in `modules/ci-roles/policies/<stack>.json.tftpl` |
| `ci/ci-build` | `repo:gabrielguernik/realworld-app` on `main` | Push to the two ECR repos |

Notable scoping: `tf-dns` can only write the `sandbox.gg-incode.click` NS record in the parent zone, and `tf-edge` only
`_*.sandbox.gg-incode.click` CNAMEs (certificate validation).

## Module sources

Live stacks reference modules by relative path (`../../../../../modules/network`). Modules and stacks live in the same
repo, so a module change and its effect land in one commit, and CI plans every stack that uses the changed module.
Environments are still separated by their own folders, tfvars, state and CI roles, and sandbox is applied before prod.

**When to version modules:** once modules move to their own repo or a private registry shared by several teams, live stacks
pin them (`?ref=vX.Y.Z` or a registry version constraint). A module change then reaches each stack only when its pin is
bumped, so environments can be promoted one at a time.

## Lint

```bash
terraform fmt -recursive -check
tflint --init && tflint --recursive
checkov -d .        # optional
pre-commit run -a   # all of the above
```

## Log archive cost

Logs expire after 365 days and stay in S3 Standard the whole time. Storage-class transitions were left out on purpose: at
sandbox volume the bucket holds a few GB, and the cheaper classes would not pay for themselves:

- Standard-IA and Glacier Instant Retrieval bill every object as at least 128 KB, and most flow-log and ALB-log objects are smaller.
- Each transition is charged per object (per 1,000 requests), and log buckets hold many small objects.
- Standard-IA bills a minimum of 30 days of storage, and Glacier IR a minimum of 90 days.

At production volume (hundreds of GB per month) a rule such as Standard → Standard-IA at 30 days → Glacier IR at 90 days
roughly halves storage cost. Add it together with an `object_size_greater_than` filter (e.g. 128 KB) so small objects stay in Standard.

## Future considerations

- **CloudTrail.** A multi-region trail to the log archive (management events, log file validation), optionally with
  CloudWatch Logs for alerting on API activity. It is not in the sandbox; in a multi-account setup it becomes an organization trail
  in a dedicated log-archive account.
- **Detection:** GuardDuty and Security Hub, enabled organization-wide from a delegated administrator account.
- **WAF:** the edge module already supports a web ACL (`enable_waf`); turn it on for prod.

## Known gaps (Phase 1)

- Single NAT gateway (toggle in `network/terraform.tfvars`, prod value in the prod stub).
- No CloudTrail trail managed here (see Future considerations).
- No IAM password policy; the account's password rules are left to its owner. CI never uses passwords or keys (OIDC roles only).
- The log archive bucket has no S3 server access logging of its own.
- The CI roles for network and edge use broad `ec2:*` / `acm:*` / `wafv2:*` service actions; instance launches are denied for `tf-network`.
- One account and one region stand in for a multi-account, multi-region organization.
