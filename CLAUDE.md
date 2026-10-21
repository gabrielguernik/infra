# CLAUDE.md

Guidance for coding agents working in this repo. Humans: start with the [README](README.md); the procedures are in
[docs/operations.md](docs/operations.md), CI in [docs/ci.md](docs/ci.md).

## Hard rules

- **Plain Terraform only**: `terraform -chdir=<stack> ...`. No Makefile, wrapper scripts or Terragrunt.
- **AWS account 965140467182, us-east-1 only.** Use the default credentials. Never use other AWS profiles or GitHub
  logins on this machine: they belong to an unrelated employer. GitHub owner: `gabrielguernik`; all repos stay private.
- The default kubeconfig has unrelated contexts. Before any `kubectl`, point it at the tunnel's kubeconfig in the
  **same** shell command (each command starts a fresh shell).
- **The sandbox stays up.** Don't destroy stacks unless asked.
- **Don't apply `bootstrap` locally or merge PRs**: bootstrap is applied by CI after a merge, and the user merges.
- **Out of scope by decision** (don't add them unasked): spot instances, CloudTrail, GuardDuty, IAM password policy,
  a frontend, Makefiles, git-tag module pinning.
- **Organization SCP limits:** EC2 limited to t2/t3/t3a up to `medium` (amd64 images only); AWS Backup is denied.
  Check any new service or instance type with a read-only or dry-run call before designing around it.

## Repo conventions

- **Stack layout:** `live/accounts/<account>/<region>/<stack>/`, `live/shared/<region>/<stack>/` or
  `live/envs/<env>/<region>/<stack>/` (`_global` for global stacks), with `backend.tf`, `providers.tf`, `variables.tf`,
  `main.tf`, `terraform.tfvars`. Stacks contain wiring only (SSM reads, module calls, SSM writes); logic lives in
  `modules/`, referenced by relative path (`../../../../../modules/<name>`). Modules have no backend or provider block.
- **Stacks talk only through SSM** under `/<env>/<region>/<stack>/<name>` (`env` is `account`, `shared` or the
  environment; `region` is `_global` for global stacks). Write outputs with `modules/ssm-outputs`; read them with
  `data "aws_ssm_parameter"`, using `insecure_value` (not `nonsensitive(...value)`). Never use `terraform_remote_state`.
- **Providers** set `allowed_account_ids` and `default_tags` with `Project`, `Environment = var.env`,
  `Region = var.region`, `Stack`, `ManagedBy`, `Repo`. Use `var.env` and `var.region`; don't hardcode them.
- **Terraform version** is in `.terraform-version` (1.16.6). After changing a provider version, lock for CI's platform
  too, or CI's `init -lockfile=readonly` fails:
  `terraform -chdir=<stack> providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64`.
- **Generated secrets never enter state.** Use an `ephemeral "random_password"` with `secret_string_wo` and
  `secret_string_wo_version`. The version is a hash of the non-secret content plus a `rotation_generation`-style
  variable, so bumping that variable rotates the secret. The only exception is the Valkey `auth_token`.
- **Security groups referenced across stacks** are looked up by tag, not ID.
- **Pods get AWS access only through IRSA** (`modules/platform`, roles under `/irsa/`, trust limited to one service
  account). Nodes use IMDSv2 with hop limit 1. Any add-on that would discover the region or VPC from IMDS must get them
  explicitly: the region via `AWS_REGION` and the tool's config, the VPC via the Load Balancer Controller's `vpcTags`.
  Raising `imds_hop_limit` to 2 lets every pod use the node role: avoid it.

## Adding or changing a stack

1. Add the stack to the `stacks` map in `live/accounts/sandbox/_global/bootstrap/terraform.tfvars`, in apply order.
   That map is the stack list for CI (`scripts/ci/stacks.py`) and creates its roles `ci/tf-<stack>` and
   `ci/tf-<stack>-plan`.
2. Write the write role's permissions in `modules/ci-roles/policies/<stack>.json.tftpl`, scoped by name, path, tag or
   condition (see existing templates). Plan roles are `ReadOnlyAccess` plus their own state, read-only.
3. Bootstrap must be applied (by CI, after merge) before the new stack's CI can run.
4. Update the stack table in the README.

A stack's CI runs only when its own folder or a module it calls (transitively) changes. Changes under
`.github/workflows`, `scripts/ci` or `.terraform-version` plan every stack.

## Checks before a PR

```bash
terraform fmt -recursive -check
tflint --init && tflint --recursive --minimum-failure-severity=warning
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml .
actionlint                                   # after editing workflows
pre-commit run -a                            # the same checks, from .pre-commit-config.yaml
TF_CI_SKIP_ASSUME=1 ACCOUNT_ID=965140467182 scripts/ci/tf.sh plan <stack>   # CI's plan, with your credentials
```

Accepted Trivy findings go in `.trivyignore.yaml` with a reason. Diagrams: edit `docs/architecture/architecture.py`
and re-render with Docker (`docs/architecture/README.md`); commit the PNGs.

## Pitfalls already paid for

- **CI permission gaps surface on the first CI apply of a new resource type** (e.g. tagging SG rules, RunInstances for
  launch template updates). Decode denials with `aws sts decode-authorization-message`, fix the policy template, then
  re-run terraform-apply with `apply=true`.
- **GitHub OIDC trust uses immutable subjects**: `repo:gabrielguernik@35024789/<repo>@<repo-id>:...`. A job with
  `environment:` gets `...:environment:<name>` instead of `...:ref:...`.
- **`upload-artifact` skips dot folders** without `include-hidden-files: true` (`.tf-ci/`). Checkouts use
  `persist-credentials: false`, so use `gh api` rather than `git fetch` to read other refs.
- **GitHub sometimes doesn't start or delays push runs**; every workflow has `workflow_dispatch` to run it by hand.
- **The bastion must be at least a t3.micro:** the organization's Inspector agents exhaust a t3.nano and SSM drops it.
- **SSM tunnels can die silently** ("broken pipe", process still listening), and abandoned sessions break new port
  forwards. Kill the plugin, terminate stale sessions (`aws ssm describe-sessions --state Active`), reopen. Use
  `kubectl --request-timeout`.
- **`rds.force_ssl` needs `apply_method = "pending-reboot"`**, or every plan shows drift.
- **The first ElastiCache create in an account** can fail with a 408 while its service-linked role propagates; retry.
- **IAM conditions on optional keys** need `...IfExists` (e.g. `ssm:SessionDocumentAccessCheck` with `BoolIfExists`).
- **The AMP workspace ID is hardcoded in gitops** (`alloy.yaml`, `grafana.yaml`); recreating `monitoring` needs a
  gitops commit, and the gitops check fails until it matches.
- **Secret rotation:** bump the version variable (`rotation_generation` in data, `grafana_password_version` in
  monitoring, `argocd_admin_password_version` in eks) and apply. Then force-sync the db-bootstrap ExternalSecret,
  sync the `db-bootstrap` Application in ArgoCD, and force-sync the realworld ExternalSecrets
  (annotation `force-sync=<timestamp>`). Reloader restarts the pods.
- **Destroy:** delete the gitops `apps` root and ApplicationSet first and wait until no `k8s-*` ALB exists. Otherwise
  the ALB's network interfaces block subnet and SG deletion (docs/operations.md).
