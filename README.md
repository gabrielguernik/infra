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
  envs/sandbox/us-east-1/{network,bastion,edge,eks,data}
  envs/prod/...   stub tfvars showing the prod toggles; never applied
docs/      cidr-plan.md
scripts/   tunnel.sh: SSM port forwarding through the bastion
```

## Stack catalogue

| Stack | Path | Contents | Reads from SSM |
|---|---|---|---|
| bootstrap | `accounts/sandbox/_global/bootstrap` | State bucket, GitHub OIDC provider, CI roles | — |
| shared-global | `shared/_global/shared-global` | Parent zone `gg-incode.click` (imported), registrar name servers | — |
| shared-regional | `shared/us-east-1/shared-regional` | ECR repo `realworld-api`, log archive bucket | — |
| account-baseline | `accounts/sandbox/_global/account-baseline` | Account alias, S3 account-level Block Public Access | — |
| regional-baseline | `accounts/sandbox/us-east-1/regional-baseline` | EBS encryption by default | — |
| dns | `envs/sandbox/_global/dns` | `sandbox.gg-incode.click` zone + delegation | shared-global |
| network | `envs/sandbox/us-east-1/network` | VPC, subnets, NAT, S3 gateway + interface endpoints, `sg-vpce`, flow logs | shared-regional |
| bastion | `envs/sandbox/us-east-1/bastion` | Session Manager bastion (t3.micro, no inbound, no keys), `sg-bastion` | network |
| edge | `envs/sandbox/us-east-1/edge` | Wildcard ACM certificate, `sg-alb`, optional WAF | dns, network |
| eks | `envs/sandbox/us-east-1/eks` | EKS 1.36 (private endpoint only), 2 × t3.medium system nodes, IRSA, add-ons, `sg-app` | network (+ `sg-alb`, `sg-bastion` by tag) |
| data | `envs/sandbox/us-east-1/data` | RDS PostgreSQL 18, ElastiCache Valkey 8.1, app secrets, `sg-db`, `sg-cache` | network (+ `sg-app`, `sg-bastion` by tag) |

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
8. `live/envs/sandbox/us-east-1/bastion`
9. `live/envs/sandbox/us-east-1/edge`
10. `live/envs/sandbox/us-east-1/eks`
11. `live/envs/sandbox/us-east-1/data`

### Destroy order (environment, between work sessions)

```bash
for s in data eks edge bastion network; do
  terraform -chdir=live/envs/sandbox/us-east-1/$s destroy || break
done
```

The order matters: `data` holds rules that reference `sg-app` and `sg-bastion`, and `eks` references `sg-alb` and `sg-bastion`,
so each must go before the stack owning the referenced group.

`dns` and everything above it stay up: they cost almost nothing, and keeping them keeps delegation stable.
Approximate running cost of the environment stacks: EKS control plane $73, interface endpoints (5 services × 3 AZs) $110,
2 × t3.medium nodes $65, NAT gateway $35, RDS db.t3.micro $15, Valkey cache.t3.micro $12, bastion t3.micro $8. That is about
$320/month, nearly all of it removed by the destroy above.

## Connecting to the environment

Nothing in the environment is reachable from the internet except the ALB. The Kubernetes API, PostgreSQL and Valkey are
reached through a **Session Manager bastion**: a `t3.micro` in a private subnet with no inbound rules, no public IP and no
SSH keys. Session Manager forwards a local port through the bastion to the target. Access is granted by IAM and every
session is recorded in Session Manager's history.

```
laptop:8443  ──SSM──▶ bastion ──▶ EKS private endpoint :443
laptop:15432 ──SSM──▶ bastion ──▶ RDS PostgreSQL     :5432
laptop:16379 ──SSM──▶ bastion ──▶ ElastiCache Valkey :6379
```

### 1. Prerequisites (once)

1. **AWS CLI v2:** `aws --version` shows `aws-cli/2.x`.
2. **Session Manager plugin:**
   ```bash
   brew install --cask session-manager-plugin     # macOS; other OS: see the AWS docs "Install the Session Manager plugin"
   session-manager-plugin --version
   ```
3. **kubectl** within one minor version of the cluster (1.36): `kubectl version --client`.
4. Optional, for the data tier: `psql` (`brew install libpq`), `valkey-cli` (`brew install valkey`) and `jq`.
5. **Credentials for account 965140467182.** Your identity needs:
   - `ssm:StartSession` on the bastion with the `AWS-StartPortForwardingSessionToRemoteHost` document;
   - `ssm:GetParameter` on `/sandbox/*`;
   - `eks:DescribeCluster`;
   - an EKS access entry, for kubectl;
   - `secretsmanager:GetSecretValue` on the database and app secrets, for psql and valkey-cli.

### 2. Check your identity and that the environment is up

```bash
aws sts get-caller-identity --query Account --output text      # must print 965140467182
export AWS_REGION=us-east-1

BASTION_ID=$(aws ssm get-parameter --name /sandbox/us-east-1/bastion/instance_id --query Parameter.Value --output text)
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values="$BASTION_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text   # must print Online
```

If the parameter doesn't exist, the environment is destroyed: apply `network` → `bastion` → `edge` → `eks` → `data` first.
If the status isn't `Online`, see Troubleshooting.

### 3. Kubernetes API

**3a. Open the tunnel.** It runs in the foreground, so use a dedicated terminal:

```bash
./scripts/tunnel.sh eks
# equivalent to:
EKS_HOST=$(aws ssm get-parameter --name /sandbox/us-east-1/eks/cluster_endpoint --query Parameter.Value --output text | sed 's#^https://##')
aws ssm start-session --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$EKS_HOST,portNumber=443,localPortNumber=8443"
```

Wait for `Waiting for connections...`.

**3b. Configure kubectl** (once per cluster rebuild), in another terminal:

```bash
export AWS_REGION=us-east-1
EKS_HOST=$(aws ssm get-parameter --name /sandbox/us-east-1/eks/cluster_endpoint --query Parameter.Value --output text | sed 's#^https://##')

aws eks update-kubeconfig --name sandbox-us-east-1 --alias sandbox
CLUSTER_ARN=$(aws eks describe-cluster --name sandbox-us-east-1 --query cluster.arn --output text)
# Send traffic to the local tunnel, but keep checking the certificate against the real endpoint name:
kubectl config set-cluster "$CLUSTER_ARN" --server=https://localhost:8443 --tls-server-name="$EKS_HOST"
```

**3c. Test:**

```bash
kubectl --context sandbox get nodes        # 2 Ready t3.medium nodes
```

Stop the tunnel with `Ctrl-C`. Sessions also end after 20 minutes idle; just run step 3a again.

### 4. PostgreSQL (debugging)

```bash
./scripts/tunnel.sh db                      # terminal 1: localhost:15432 → RDS :5432
```

```bash
# terminal 2
export AWS_REGION=us-east-1
DB_HOST=$(aws ssm get-parameter --name /sandbox/us-east-1/data/db_endpoint --query Parameter.Value --output text)
SECRET_ARN=$(aws ssm get-parameter --name /sandbox/us-east-1/data/db_master_secret_arn --query Parameter.Value --output text)
export PGUSER=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r .username)
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r .password)
curl -sO https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem

# host = real name (checked against the certificate); hostaddr = the tunnel
psql "host=$DB_HOST hostaddr=127.0.0.1 port=15432 dbname=realworld sslmode=verify-full sslrootcert=us-east-1-bundle.pem" -c 'select version();'
unset PGPASSWORD
```

### 5. Valkey (debugging)

```bash
./scripts/tunnel.sh cache                   # terminal 1: localhost:16379 → Valkey :6379
```

```bash
# terminal 2
CACHE_HOST=$(aws ssm get-parameter --name /sandbox/us-east-1/data/cache_endpoint --query Parameter.Value --output text)
APP_SECRET_ARN=$(aws ssm get-parameter --name /sandbox/us-east-1/data/app_secret_arn --query Parameter.Value --output text)
export REDISCLI_AUTH=$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_ARN" --query SecretString --output text | jq -r .REDIS_AUTH_TOKEN)
curl -sO https://www.amazontrust.com/repository/AmazonRootCA1.pem   # ElastiCache certificates chain to Amazon Root CA 1

valkey-cli --tls --cacert AmazonRootCA1.pem --sni "$CACHE_HOST" -h 127.0.0.1 -p 16379 PING     # PONG
unset REDISCLI_AUTH
```

No local `valkey-cli`? Use the container image. Docker Desktop and Rancher Desktop reach the tunnel as `host.docker.internal`:

```bash
docker run --rm -e REDISCLI_AUTH -v "$PWD/AmazonRootCA1.pem:/ca.pem:ro" valkey/valkey:8.1 \
  valkey-cli --tls --cacert /ca.pem --sni "$CACHE_HOST" -h host.docker.internal -p 16379 PING
```

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `TargetNotConnected` / status not `Online` | The bastion is stopped, just booted (wait about 2 minutes) or has no route to SSM. Check the NAT gateway exists (`network` applied) and the instance is running. |
| Status `ConnectionLost` minutes after launch, instance `running` | The organization's Amazon Inspector associations install agents on every new instance. On a `t3.nano` that exhausts memory and CPU credits and the SSM agent stops reporting, which is why the bastion is a `t3.micro`. A stop/start (or a resize) brings it back. |
| `SessionManagerPlugin is not found` | Install the plugin (step 1.2) and open a new shell. |
| `AccessDeniedException` on `StartSession` | Your identity lacks `ssm:StartSession` for this instance or document. |
| `bind: address already in use` | Another tunnel is using the port: `lsof -i :8443` and stop it, or pass another local port. |
| kubectl `x509: certificate is valid for …, not localhost` | `--tls-server-name` is missing: redo step 3b. |
| kubectl `Unauthorized` / `the server has asked for the client to provide credentials` | Your IAM identity has no EKS access entry, or `AWS_PROFILE` differs from the one used for `update-kubeconfig`. |
| kubectl hangs or `connection refused` on 8443 | The tunnel isn't running, timed out, or its connection dropped (the tunnel terminal shows `broken pipe` but the process keeps running and accepting connections). Stop it with `Ctrl-C` and redo step 3a. |
| Tunnel opens but every connection logs `Connection to destination port failed` | Abandoned sessions (closed laptops, killed terminals) stay open on the bastion and break new port forwards. List and end your sessions, then reopen the tunnel: `aws ssm describe-sessions --state Active --query 'Sessions[].SessionId' --output text \| xargs -n1 aws ssm terminate-session --session-id` |
| valkey-cli `certificate verify failed` | That `valkey-cli` has no CA bundle (the official container image doesn't ship one): pass `--cacert AmazonRootCA1.pem`. |
| psql `server certificate does not match host name` | Use `host=<real endpoint> hostaddr=127.0.0.1`, not `host=localhost`. |
| Everything worked yesterday, nothing works today | The environment was destroyed between sessions. Apply it again, then repeat step 3b (new cluster endpoint). |

### Security notes

- The bastion has no inbound security group rules, no public IP and no SSH key. The only way in is Session Manager, authorized by IAM.
- Allowed sessions are restricted to the port-forwarding document, so no interactive shell is available.
- Database and cache credentials come from Secrets Manager into environment variables for one command, and are never written to disk.

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
| `ci/ci-build` | `repo:gabrielguernik/realworld-app` on `main` | Push to the `realworld-api` ECR repo |

Notable scoping:
- `tf-dns` can only write the `sandbox.gg-incode.click` NS record in the parent zone.
- `tf-edge` can only write `_*.sandbox.gg-incode.click` CNAMEs (certificate validation).
- `tf-network` is denied launching instances; `tf-bastion` can only launch instances tagged `Stack=bastion`.
- `tf-eks` manages IAM only under the `/eks/` path, `tf-bastion` only under `/bastion/`.
- `tf-data` reaches only `sandbox/realworld/*` and RDS-managed `rds!*` secrets.

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

## Rules for cluster add-ons (IMDS)

Nodes require IMDSv2 with a **hop limit of 1**, so pods cannot reach the instance metadata service and cannot use the
node role. Pods get AWS credentials only through IRSA. Add-ons that would discover settings from IMDS get them explicitly:

| Component | Explicit setting |
|---|---|
| AWS Load Balancer Controller | Helm `region` and `vpcId` |
| ExternalDNS, External Secrets, Fluent Bit, Karpenter | `AWS_REGION` (injected by the IRSA webhook) plus region in each tool's config |
| EBS CSI driver | none: falls back to Kubernetes node labels |

Fallback, if a component still needs IMDS: `imds_hop_limit = 2` in the eks module. Every pod could then use the node role.

## Known gaps

- Single NAT gateway (toggle in `network/terraform.tfvars`, prod value in the prod stub).
- No CloudTrail trail managed here (see Future considerations).
- No IAM password policy; the account's password rules are left to its owner. CI never uses passwords or keys (OIDC roles only).
- The log archive bucket has no S3 server access logging of its own.
- The CI roles for network and edge use broad `ec2:*` / `acm:*` / `wafv2:*` service actions; instance launches are denied for `tf-network`.
- One account and one region stand in for a multi-account, multi-region organization.
