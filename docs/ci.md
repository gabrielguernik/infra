# Terraform CI/CD

How infra changes are planned, approved and applied, and what each CI role can do. The overview is in the
[README](../README.md); production upgrades are in [production.md](production.md).

## Workflows

Three workflows in `.github/workflows/`, plain Terraform and official actions pinned by commit, with the logic in
`scripts/ci/` (`stacks.py`: which stacks and in what order; `tf.sh`: assume a role, plan, compare, apply).

| Workflow | When | What |
|---|---|---|
| `terraform-pr` | Pull requests touching Terraform or the CI | **Static checks** on everything: `fmt`, `validate` (every stack, bootstrap included), `tflint`, Trivy config scan (HIGH and CRITICAL; accepted findings with reasons in `.trivyignore.yaml`). **Plan** of each affected stack with its read-only role, posted as one PR comment per stack and updated on each push. The change lists are kept as artifacts: they are what the merge approves. |
| `terraform-apply` | Push to `main`; manual | Plans the stacks affected since the last apply, read-only. **Applies only if each plan is identical to the one reviewed in the merged PR**, then, in apply order with the write roles, re-plans each stack with the state lock and applies only if the plan still matches. Moves the tag `applied/sandbox` when done. |
| `terraform-drift` | Daily 06:17 UTC; manual | Read-only plan of every stack. Drift or a failed plan fails the run and opens or updates the issue labelled `drift`; a clean run closes it. Stacks with empty state (environment torn down) count as "not deployed". |

**Which stacks run.** The stack list and the apply order are the `stacks` map in `bootstrap/terraform.tfvars`, the
same map that creates the roles. A stack runs only when its own folder or a module it calls changes. Stacks that read its
SSM outputs are not re-planned: they pick up a changed value on their next change, and until then the daily drift plan
reports them. To roll a changed output out right away, run **terraform-apply** by hand with those stacks. A change to
the CI itself plans everything. On `main`, "affected" is measured from the tag `applied/sandbox`, so a failed or skipped run can't make a later
one skip its stacks.

**Who can write.**
- Pull requests only get the read-only `tf-<stack>-plan` roles, and plans run with `-lock=false`.
- The write roles `tf-<stack>` trust only the GitHub environment `sandbox`, which only `main` can deploy to.
- `bootstrap` is applied by CI too, first in the apply order. Its write role `tf-bootstrap` can change every CI role,
  itself included, so it is effectively account admin: merging a bootstrap change is an admin-level action. It can't
  change its own trust policy or delete itself (an explicit deny), so a bad change fails instead of locking CI out.
  Prod: required reviewers on its environment, or bootstrap in a separate management account and pipeline.

**The approval is the PR review.** This repo's GitHub plan has no required reviewers for environments in private repos,
so merging approves the plans shown in the PR comments. The apply refuses anything else:
- **No PR:** a direct push to `main` is planned, never applied.
- **A stack the PR didn't plan, or a plan that changed** (main moved, the state changed): nothing is applied.

In those cases, review the run's plans and start **terraform-apply** by hand (Actions → terraform-apply → Run
workflow) with `apply: true`. `apply: false` only plans. With GitHub Team or Enterprise, add required reviewers to the
`sandbox` environment; the apply job then also waits for a person, with no workflow change.

**Typical change:** branch → PR → read the plan comments (🟡 changes, 🟢 none, 🔴 failed) → merge → the apply
workflow applies it. Destroying a stack is never automated (see [operations.md](operations.md#destroy-order-environment-between-work-sessions)).

**Provider upgrades:** CI inits with `-lockfile=readonly`, so each `.terraform.lock.hcl` must carry the checksums of
the CI platform too. After changing a provider version, lock for every platform:
`terraform -chdir=<stack> providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64`.

**Local dry run** of the CI logic with your own credentials:
`TF_CI_SKIP_ASSUME=1 ACCOUNT_ID=965140467182 scripts/ci/tf.sh plan <stack>`.

## State

- Bucket `tfstate-965140467182-us-east-1`: versioning, SSE-S3, Block Public Access, TLS-only, old versions expire after 90 days.
- Locking with S3 native lockfiles (`use_lockfile = true`), so there is no DynamoDB table.
- The key equals the stack's folder under `live/`.
- The bucket policy denies each `tf-<stack>` and `tf-<stack>-plan` role every object outside its own prefix (object
  versions included), so no CI role can read another stack's state.

## CI roles

GitHub Actions authenticates through OIDC. There are no long-lived keys.

| Role | Trusted subjects | Can do |
|---|---|---|
| `ci/tf-<stack>` | `repo:gabrielguernik/infra`, GitHub environment `sandbox` only (the apply job; deployment branch `main`) | Its own state prefix, its own SSM path, the SSM paths it reads, and the service actions in `modules/ci-roles/policies/<stack>.json.tftpl`. For `tf-bootstrap`: all of IAM under `role/ci/`, the GitHub OIDC provider and the state bucket's configuration, which makes it effectively admin |
| `ci/tf-<stack>-plan` | `repo:gabrielguernik/infra` on `main` and pull requests | Read-only: AWS `ReadOnlyAccess` (which includes every SSM parameter), its own state prefix read-only. No secret values: generated secrets are write-only, and refreshing them only lists their versions |
| `ci/ci-build` | `repo:gabrielguernik/realworld-app` on `main` | Push to the `realworld-api` ECR repo |
| `ci/argocd-<cluster>` | `repo:gabrielguernik/gitops`, GitHub environment `<cluster>` only | Port forwarding through the bastion to the cluster API, `eks:DescribeCluster`, read `<env>/argocd/*` secrets; cluster-admin access entry in `eks` |
| `ci/gitops-check` | `repo:gabrielguernik/gitops` on `main` and pull requests | Read-only: describe the VPCs, security groups, IRSA roles, secret metadata, RDS instances, certificates, AMP workspaces and log groups that gitops references |

Subjects use GitHub's immutable form, `repo:<owner>@<owner-id>/<repo>@<repo-id>:...`, so a deleted and recreated repo with
the same name can't inherit the trust. A job that uses a GitHub environment gets the subject `...:environment:<name>`
instead of `...:ref:...`.

Notable scoping:
- `tf-dns` can only write the `sandbox.gg-incode.click` NS record in the parent zone.
- `tf-edge` can only write `_*.sandbox.gg-incode.click` CNAMEs (certificate validation).
- `tf-network` is denied launching instances; `tf-bastion` can only launch instances tagged `Stack=bastion`.
- `tf-eks` manages IAM only under the `/eks/` path, `tf-bastion` only under `/bastion/`.
- `tf-data` reaches only `sandbox/realworld/*` and RDS-managed `rds!*` secrets.
- `tf-platform` manages IAM roles only under the `/irsa/` path.
- `tf-monitoring` reaches only log groups under `/eks/<cluster>/` and secrets under `sandbox/monitoring/`; AMP has no
  name-based ARNs, so its AMP actions are scoped to the account and region.

The ArgoCD deploy keys (`<env>/argocd/repo-<repo>` in Secrets Manager) are created by hand, outside Terraform, so the
private keys never land in state. The ArgoCD admin password (`<env>/argocd/<cluster>/admin`) is generated by the `eks`
stack, ephemeral and write-only, so it isn't in state either; `tf-eks` reaches only `<env>/argocd/<cluster>/*`.
