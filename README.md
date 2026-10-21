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
  envs/sandbox/us-east-1/{network,bastion,edge,eks,data,monitoring,platform}
  envs/prod/...   stub tfvars showing the prod toggles; never applied
docs/      cidr-plan.md
scripts/   tunnel.sh: SSM port forwarding through the bastion; ci/: the Terraform workflows' logic
.github/workflows/   terraform-pr, terraform-apply, terraform-drift
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
| data | `envs/sandbox/us-east-1/data` | RDS PostgreSQL 18, ElastiCache Valkey 8.1, app secrets, credentials for the DB roles `realworld_app` and `realworld_migrator`, `sg-db`, `sg-cache` | network (+ `sg-app`, `sg-bastion` by tag) |
| monitoring | `envs/sandbox/us-east-1/monitoring` | Amazon Managed Prometheus workspace and its alert rules (module `prometheus-alerts`), container log group `/eks/<cluster>/containers`, saved Logs Insights queries, Grafana admin secret | — |
| platform | `envs/sandbox/us-east-1/platform` | IRSA roles with fixed names for the in-cluster components (IAM only; no Kubernetes or Helm providers) | dns, eks, data, monitoring |

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
12. `live/envs/sandbox/us-east-1/monitoring`
13. `live/envs/sandbox/us-east-1/platform`
14. **If `monitoring` was recreated:** the AMP workspace has a new ID. Put it in gitops `clusters/<cluster>/platform/alloy.yaml`
    and `grafana.yaml` (`aws ssm get-parameter --name /sandbox/us-east-1/monitoring/amp_workspace_id`); the gitops checks fail
    until they match.
15. ArgoCD: run the `argocd` workflow in [gitops](https://github.com/gabrielguernik/gitops) (Actions → argocd → Run workflow). It installs ArgoCD through the bastion, and ArgoCD deploys everything else in the cluster from that repo.

No stack talks to the Kubernetes API: Terraform stops at AWS resources, so every stack can be planned without the tunnel.
After the first build, changes go through CI ("CI/CD (Terraform)"): a PR plans them, and merging applies them in this order.

### Destroy order (environment, between work sessions)

First remove the apps, so the controllers delete what they created outside Terraform (the ALB, its target groups and
DNS records). Otherwise the ALB's network interfaces block deleting the subnets and `sg-alb`. From the gitops repo:

```bash
eval "$(scripts/eks-tunnel.sh sandbox us-east-1)"
kubectl -n argocd delete application apps          # the root first, or it recreates the ApplicationSet
kubectl -n argocd delete applicationset apps        # Applications → Ingress → ALB and DNS records
kubectl -n argocd wait --for=delete application/realworld --timeout=5m
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerName"  # []
kill "$TUNNEL_PID"
```

Then, from this repo:

```bash
for s in platform monitoring data eks edge bastion network; do
  terraform -chdir=live/envs/sandbox/us-east-1/$s destroy || break
done
```

The order matters: `data` holds rules that reference `sg-app` and `sg-bastion`, and `eks` references `sg-alb` and `sg-bastion`,
so each must go before the stack owning the referenced group. Destroying `monitoring` deletes the metrics history (AMP
workspace) and the container logs.

`dns` and everything above it stay up: they cost almost nothing, and keeping them keeps delegation stable.
Approximate running cost of the environment stacks: EKS control plane $73, interface endpoints (5 services × 3 AZs) $110,
2 × t3.medium nodes $65, NAT gateway $35, ALB $20, RDS db.t3.micro $15, Valkey cache.t3.micro $12, bastion t3.micro $8,
Amazon Managed Prometheus ingestion $10–20, CloudWatch Logs and API calls about $5. That is about $355–365/month, nearly all
of it removed by the destroy above.

## Connecting to the environment

Nothing in the environment is reachable from the internet except the ALB. The Kubernetes API, PostgreSQL and Valkey are
reached through a **Session Manager bastion**: a `t3.micro` in a private subnet with no inbound rules, no public IP and no
SSH keys. Session Manager forwards a local port through the bastion to the target. Access is granted by IAM, and every
session's user, start and end are in Session Manager's history (its content isn't logged).

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

This logs in as the master user, for administration. To see what the app sees, use the app role instead:
`sandbox/realworld/db-app` (or `db-migrator`) holds `username`, `password`, `host`, `port` and `dbname`.

**Database roles.** Workloads never use the master user. The platform's `db-bootstrap` Job (gitops repo) creates, as
master, `realworld_migrator` (owns the database and every table; runs the migrations) and `realworld_app` (data access
only, no DDL, 20 connections). Their passwords are generated by the `data` stack.

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
- The CI role is restricted to the port-forwarding document. People with broader IAM permissions (admins) can also open
  a shell on the bastion. EKS nodes have no Session Manager permissions, so the bastion is the only entry point.
- The bastion's database egress reaches only the private-data subnets, on 5432 and 6379.
- A new Amazon Linux release shows as drift on `bastion` (the AMI comes from the latest-AMI parameter). Applying it
  replaces the instance, which patches it and closes open tunnels.
- Database and cache credentials come from Secrets Manager into environment variables for one command, and are never written to disk.
- The gitops pipeline's role `ci/argocd-<cluster>` can only start port-forwarding sessions on the bastion, end its own sessions, describe the cluster, and read the ArgoCD deploy keys. It is cluster-admin inside Kubernetes (installing ArgoCD creates CRDs and cluster roles), and only jobs in the cluster's GitHub environment can assume it.

## Observability

| Signal | Collected by | Stored in | Where to look |
|---|---|---|---|
| API metrics (`/metrics`: latency histogram by route, cache hits, Prisma pool, process) | Grafana Alloy, scraping pods annotated `prometheus.io/scrape` | Amazon Managed Prometheus (AMP) workspace `sandbox-us-east-1` | Grafana → Apps → RealWorld API |
| API load balancer requests and 5xx (what users see) | Alloy's CloudWatch exporter, every minute | AMP | RealWorld API dashboard, top row; the error alert |
| ALB, RDS, Valkey, NAT metrics | CloudWatch | CloudWatch | Grafana → AWS → AWS dependencies |
| Container logs (JSON fields such as `reqId`, `res.statusCode` and `responseTime` are queryable) | Fluent Bit | CloudWatch Logs `/eks/sandbox-us-east-1/containers`, 30 days, one stream per `<namespace>.<pod>` | Logs Insights saved queries `sandbox-us-east-1/*`; dashboard log panels |
| EKS control plane, PostgreSQL logs | EKS, RDS | `/aws/eks/sandbox-us-east-1/cluster`, `/aws/rds/instance/sandbox-us-east-1-postgres/postgresql` | Logs Insights |
| VPC flow logs, ALB access logs | VPC, ALB | Log archive bucket | Athena or download |
| Top SQL and waits | Performance Insights | RDS | RDS console |

Grafana, Alloy and Fluent Bit run in the cluster and are deployed by ArgoCD from gitops (`clusters/<cluster>/platform/`).
The AMP workspace, the log group, the saved queries and the alert rules are in the `monitoring` stack.

### Alerts

Two alerts on the API, evaluated by AMP. The rules are a plain Prometheus rules file,
`modules/prometheus-alerts/rules/realworld.yaml`; each file in that folder becomes a rule group namespace. Change a rule,
then apply `monitoring`.

| Alert | Fires when | Measured at |
|---|---|---|
| `RealworldHighErrorRate` | More than 5% of requests get a 5xx for 5 minutes, with more than 30 requests in 5 minutes | The load balancer: when no pod is ready, the ALB answers 503 itself and the app never sees the request |
| `RealworldHighLatency` | p95 of user requests above 500 ms for 10 minutes | The app's latency histogram, excluding probes, `/metrics` and unmatched paths |

**Alerts aren't delivered anywhere** (see "Production" below). Firing alerts show in Grafana (Alerting → Alert rules,
data source "Amazon Managed Prometheus") and in the workspace's `api/v1/alerts`.

### Open Grafana

From the gitops repo (Grafana is private, like the ArgoCD UI):

```bash
eval "$(scripts/eks-tunnel.sh sandbox us-east-1)"
kubectl -n monitoring port-forward svc/grafana 3000:80 &
aws secretsmanager get-secret-value --secret-id sandbox/monitoring/grafana --query SecretString --output text | jq -r '."admin-password"'
open http://localhost:3000                                 # user admin
```

Dashboards come from gitops (`charts/grafana-dashboards`), and Grafana has no persistence, so changes made in the UI are
lost on restart. To change a dashboard, export its JSON into the chart.

### 3am runbook

1. **The alert.** Which one, since when. Errors (`RealworldHighErrorRate`) or latency (`RealworldHighLatency`)?
2. **Grafana → RealWorld API dashboard, top row.** Compare the two 5xx ratios:
   - **ALB high, API low or no API traffic:** requests aren't reaching the pods. Usually no pod is ready. Check
     `kubectl -n realworld get pods` and the dashboard panel "Readiness failures", which gives the reason from the
     `not ready: database check failed` log lines.
   - **API high too:** the API itself fails. "Errors/s by route and status" shows which routes, and "Latest 5xx" gives
     their `reqId`s.
3. **Latency.** Check "p95 latency by route" for the slow routes, and "Queries waiting for a connection" for DB pool
   saturation. Then check pod CPU and event loop lag: a CPU-bound pod makes every request wait.
4. **Recent changes.** `kubectl -n argocd get applications` and the gitops history. If a deploy lines up with the start,
   revert its gitops commit (realworld-app README, "Rollback").
5. **One request end to end.** Run Logs Insights → saved query `sandbox-us-east-1/Request by reqId`, with the `reqId` in
   place of `REPLACE_WITH_REQ_ID`. Clients get the ID back in the `X-Request-Id` response header.
6. **Dependencies.** On the AWS dependencies dashboard:
   - ALB 5xx vs target 5xx, and healthy hosts;
   - RDS CPU, connections and latency, then Performance Insights for top SQL;
   - Valkey memory and evictions. A cold cache sends every read to PostgreSQL; the API dashboard shows the hit ratio per cache.
   - NAT port allocation errors.
7. **Cluster.** `kubectl get events -n realworld --sort-by=.lastTimestamp`, `kubectl describe pod`, and the logs of the
   platform components, all in the same log group (stream `<namespace>.<pod>`).

### Verified with injected faults (2026-10-20)

| Fault | Result |
|---|---|
| A NetworkPolicy cuts the API pods off from PostgreSQL, under about 2 req/s of traffic | Pods unready in seconds; the ALB answers 503. `RealworldHighErrorRate` went pending after 3.5 min and fired after 8.6 min ("100% of requests fail with 5xx at the load balancer"). The runbook led to the cause: ALB 5xx but no API traffic, then "not ready: database check failed: timeout after 1000ms" from both pods. After the policy was deleted, the pods were ready in 21 s, and the alert resolved after 8.5 min (5-minute window plus CloudWatch's 1–2 minute delay). |
| An in-cluster k6 load test (300 virtual users on article and tag reads, 15 min) | p95 rose to about 600 ms. `RealworldHighLatency` went pending 5 min into the load and fired 10 min later ("p95 latency is 508.5ms"). The runbook pinned the cause on the API pods, not the database: `/api/tags` and `/api/articles` were slow, both pods were CPU-bound at about 0.92 cores (Node runs one thread) with about 430 ms of event-loop lag, and up to 183 queries waited per pod, while RDS CPU peaked at 14%. The fix is more pods: autoscaling, not implemented (see "Not implemented"). k6 itself measured p95 857 ms with 0 errors; the app's histogram reads lower because it starts timing only after the event loop picks up a request. |

The first run showed two gaps, both fixed:
- **The error alert first used the app's own metrics,** which never see the ALB's 503s, so a total outage would have gone unnoticed.
- **Readiness failures weren't logged.** The probe is excluded from the access log, so nothing said why pods were unready.

### Production

The sandbox keeps observability small on purpose. A production setup adds:
- **Grafana in a separate management cluster** (or Amazon Managed Grafana), so a cluster that goes down can still be observed.
- **Alert delivery.** It is not implemented here. Production adds an AMP alert manager definition that routes to SNS and on to
  a centralized alert management service such as PagerDuty (on-call schedules, escalation, deduplication), plus an
  always-firing "dead man's switch" alert that proves the delivery path works.
- **Platform alerts.** Only the two API alerts exist here. Production adds alerts for:
  - node pressure, pod crash loops and OOM kills;
  - ArgoCD applications out of sync or degraded;
  - ExternalSecrets not syncing; certificates close to expiry;
  - RDS CPU, storage and connections; Valkey memory and evictions;
  - SLO burn-rate alerts instead of fixed thresholds.
- **Platform metrics.** node-exporter, kube-state-metrics, cAdvisor, ArgoCD, the controllers and postgres-exporter, scraped
  by the same Alloy into the same workspace.
- **Logs in a centralized log system such as Loki** (shipped by Alloy), shared by all clusters and linked to metrics in
  Grafana, instead of CloudWatch Logs.
- **An easier way to manage dashboards.** Today a change means editing in the UI, exporting the JSON, committing it,
  tagging a chart version and bumping each cluster, and dashboard JSON is hard to review. Options:
  - the Grafana Operator, with dashboards, folders and data sources as Kubernetes resources;
  - dashboards written as code (Grafonnet/Jsonnet or the Grafana Foundation SDK), so reviews are readable;
  - a central Grafana that syncs UI edits back to Git.
- **Tracing** with OpenTelemetry to Tempo or X-Ray.

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
3. **GitHub environments** (repository settings, not in code), each with deployment branch `main` only: `sandbox` in
   `infra` (the only subject the `tf-<stack>` write roles trust), `sandbox-us-east-1` in `gitops` (the ArgoCD install
   role) and `sandbox` in `realworld-app` (the gitops deploy key). Removing that branch rule would let any branch
   assume these roles.
4. Apply the remaining stacks in order.

## State

- Bucket `tfstate-965140467182-us-east-1`: versioning, SSE-S3, Block Public Access, TLS-only, old versions expire after 90 days.
- Locking with S3 native lockfiles (`use_lockfile = true`), so there is no DynamoDB table.
- The key equals the stack's folder under `live/`.
- The bucket policy denies each `tf-<stack>` and `tf-<stack>-plan` role every object outside its own prefix (object
  versions included), so no CI role can read another stack's state.

## CI/CD (Terraform)

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
- `bootstrap` is never run by CI. A PR that touches it gets a comment saying an admin must apply it.

**The approval is the PR review.** This repo's GitHub plan has no required reviewers for environments in private repos,
so merging approves the plans shown in the PR comments. The apply refuses anything else:
- **No PR:** a direct push to `main` is planned, never applied.
- **A stack the PR didn't plan, or a plan that changed** (main moved, the state changed): nothing is applied.

In those cases, review the run's plans and start **terraform-apply** by hand (Actions → terraform-apply → Run
workflow) with `apply: true`. `apply: false` only plans. With GitHub Team or Enterprise, add required reviewers to the
`sandbox` environment; the apply job then also waits for a person, with no workflow change.

**Typical change:** branch → PR → read the plan comments (🟡 changes, 🟢 none, 🔴 failed) → merge → the apply
workflow applies it. Destroying a stack is never automated (see "Destroy order").

**Provider upgrades:** CI inits with `-lockfile=readonly`, so each `.terraform.lock.hcl` must carry the checksums of
the CI platform too. After changing a provider version, lock for every platform:
`terraform -chdir=<stack> providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64`.

**Local dry run** of the CI logic with your own credentials:
`TF_CI_SKIP_ASSUME=1 ACCOUNT_ID=965140467182 scripts/ci/tf.sh plan <stack>`.

### Production improvements

The pipeline stays small on purpose. A full production setup adds:
- **Approvals and branch rules:** a GitHub plan with required reviewers on the environments, prod requiring two people and
  CODEOWNERS per area. A branch ruleset on `main`: PRs only, required checks (static, plans), up-to-date branches,
  signed commits. A merge queue so merges, and their plans, are serialized.
- **One account per environment** (sandbox, staging, prod), each with its own state bucket, KMS key and CI roles, and
  changes promoted sandbox → staging → prod through the same plan and approve steps per environment.
- **Exact plan apply:** store the reviewed plan file encrypted (an S3 bucket with KMS, per run) and apply that file,
  instead of re-planning and comparing change lists. Today's comparison checks addresses and actions, not attribute values.
- **Narrower plan roles:** a custom read policy per stack instead of `ReadOnlyAccess` (which can read any S3 object and
  many configurations). Keep secrets out of state altogether (ephemeral resources and write-only arguments in Terraform
  1.11+, or secrets generated outside Terraform), so plans need no secret values.
- **Policy as code and cost** on every plan: OPA/Conftest checks on the plan JSON (no public buckets, tags present, no
  destroys of protected resources without a label), and Infracost comments.
- **An orchestrator** once the stacks grow: Atlantis, Terramate, Spacelift, HCP Terraform or env0. They provide
  dependency graphs, per-stack locks and queues, drift remediation and audit logs. Today's ordering is the `stacks` map, and stacks that
  consume a changed output aren't re-planned automatically.
- **Runners:** self-hosted ephemeral runners inside the AWS network (Actions Runner Controller or CodeBuild), with
  network egress restricted (e.g. StepSecurity harden-runner); no public runners holding cloud credentials.
- **Supply chain:** Renovate for provider, module and action updates, with plans in the PR; module tests (`terraform test`)
  and versioned modules in a registry.
- **Drift and audit:** drift alerts to the team's chat or on-call tool instead of an issue. CloudTrail on the CI roles'
  sessions, and alarms on any write by a principal other than the apply roles.

## CI roles

GitHub Actions authenticates through OIDC. There are no long-lived keys.

| Role | Trusted subjects | Can do |
|---|---|---|
| `ci/tf-<stack>` | `repo:gabrielguernik/infra`, GitHub environment `sandbox` only (the apply job; deployment branch `main`) | Its own state prefix, its own SSM path, the SSM paths it reads, and the service actions in `modules/ci-roles/policies/<stack>.json.tftpl` |
| `ci/tf-<stack>-plan` | `repo:gabrielguernik/infra` on `main` and pull requests | Read-only: AWS `ReadOnlyAccess` (which includes every SSM parameter), its own state prefix read-only, and the values of the secrets the stack manages (`plan_secrets`: `data`, `monitoring`), which refresh reads |
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
private keys never land in state.

## Module sources

Live stacks reference modules by relative path (`../../../../../modules/network`). Modules and stacks live in the same
repo, so a module change and its effect land in one commit, and CI plans every stack that uses the changed module.
Environments are still separated by their own folders, tfvars, state and CI roles, and sandbox is applied before prod.

**When to version modules:** once modules move to their own repo or a private registry shared by several teams, live stacks
pin them (`?ref=vX.Y.Z` or a registry version constraint). A module change then reaches each stack only when its pin is
bumped, so environments can be promoted one at a time.

## Lint

CI runs these on every pull request (`terraform-pr`); locally:

```bash
terraform fmt -recursive -check
tflint --init && tflint --recursive --minimum-failure-severity=warning
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml .
pre-commit run -a   # the same checks, from .pre-commit-config.yaml
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
| AWS Load Balancer Controller | Helm `region` and `vpcTags` (the VPC by its `Name` tag, so a rebuild needs no change) |
| ExternalDNS, External Secrets, Fluent Bit, Alloy, Grafana, Karpenter | `AWS_REGION` (injected by the IRSA webhook) plus region in each tool's config |
| EBS CSI driver | none: falls back to Kubernetes node labels |

Fallback, if a component still needs IMDS: `imds_hop_limit = 2` in the eks module. Every pod could then use the node role.

## Not implemented: improvements for production

These were planned (Phases 5 and 7) and deliberately left out of the sandbox.

### Autoscaling

The API runs a fixed 2 replicas on a fixed node group of 2 × t3.medium (`node_min_size`; the `eks` module ignores
`desired_size` changes so that an autoscaler can own it). The latency test in "Observability" shows the cost: under
load, both pods were CPU-bound at about 0.92 cores while RDS sat at 14% CPU, so more pods would have fixed it.
- **Pods: HorizontalPodAutoscaler** on the API.
  - It scales on CPU (requests are 100m, and a Node process saturates at about one core) and on requests per pod, read
    from AMP through KEDA or the Prometheus adapter.
  - It needs metrics-server (an EKS add-on).
  - The maximum is bounded by the `realworld_app` connection limit: replicas × `dbConnectionLimit` must stay under 20.
    Raise it in `db-bootstrap` together with the HPA maximum.
- **Nodes: Karpenter.**
  - A `NodePool` and `EC2NodeClass` for workloads, with on-demand t3 instances (the SCP allows up to t3.medium).
  - The system node group stays for the controllers.
  - It needs a node IAM role, an interruption queue and EventBridge rules in `eks`, plus an IRSA role in `platform`.
  - Its `EC2NodeClass` selects `sg-app` by tag.
  - Destroy must then also wait for Karpenter's instances to go.

### PodDisruptionBudgets

None exist. A node drain (an EKS or AMI upgrade, Karpenter consolidation) may evict both API pods at once; the rolling
update strategy (`maxUnavailable: 0`) protects deploys, not drains.
- **The API:** `minAvailable: 1` (with 2 replicas). Topology spread already places the pods in different zones.
- **Platform controllers** running more than one replica would get one too. Single-replica controllers (sandbox
  sizing) can't have a useful PDB: it would block drains forever. In prod they'd run 2 replicas.

### NetworkPolicies

There are none except ArgoCD's own; any pod can reach any pod. The VPC CNI already enforces policies
(`--enable-network-policy=true`), and the Phase 4 fault test used one, so this is configuration only:
- **Default deny** ingress and egress in every application namespace, through the app chart or a namespace baseline
  managed by the platform.
- **The API allows:**
  - ingress on port 3000 from the ALB, and from Alloy for `/metrics`;
  - egress to DNS, PostgreSQL (5432) and Valkey (6379), plus the AWS endpoints its controllers need (no AWS calls from the app itself).
- **The migrate Job:** egress to DNS and PostgreSQL only.
- **Platform namespaces:** allow-lists per controller, which need care: the API server, webhooks, AWS endpoints.

Security groups already limit what reaches RDS and Valkey (only `sg-app`); NetworkPolicies would add pod-level limits
inside the cluster.

### Progressive delivery (canary)

Planned as a bonus phase; not implemented now. Today a deploy is a rolling update. The readiness probe and the ALB
readiness gates keep old pods serving until new ones take traffic, and a rollback is a revert of the gitops deploy
commit (realworld-app README). A bad release still reaches all users before anyone notices, though: the alerts need
5–10 minutes.

The design:
- **Argo Rollouts** as a platform Application.
- **The app chart's Deployment becomes a `Rollout`** with canary steps: 20% → analysis → 50% → analysis → 100%.
- **Traffic split:** the ALB's weighted target groups (Rollouts' AWS Load Balancer Controller integration, with stable and
  canary Services), so the percentage is exact rather than a ratio of pods.
- **Analysis:** an `AnalysisTemplate` queries AMP (SigV4, an IRSA role for the Rollouts controller). It compares the
  canary's 5xx ratio and p95 latency with the stable version's, which needs Alloy to keep the pod-template-hash label.
  A regression aborts the rollout and shifts traffic back automatically.
- **Load during analysis:** a k6 Job (Rollouts' Job metric provider), so the comparison has enough requests even with
  little real traffic. Optionally, CI compares k6 results with a baseline stored in S3.
- **Migrations:** unchanged. They already must be compatible with the previous release (expand/contract), which a canary
  requires anyway, because both versions serve at once.

### Ingress proxy (Gateway API)

Today there is no proxy in the cluster. The AWS Load Balancer Controller turns the app's `Ingress` into an ALB that
terminates TLS and forwards straight to the pod IPs. That's enough for one API, but the ALB offers no authentication,
no rate limiting and only basic routing.

A production environment would put an **ingress proxy that implements the Gateway API** behind the ALB, for example
Envoy Gateway, Istio, Cilium or NGINX Gateway Fabric.
- **Traffic path:** the ALB (or an NLB) stays at the edge for ACM certificates, WAF and the public endpoint, and forwards to
  the proxy's pods. The proxy routes to the apps.
- **Gateway API resources:**
  - the platform owns the `GatewayClass` and a shared `Gateway`, with listeners and certificates;
  - each app ships its own `HTTPRoute` in its chart instead of an `Ingress`. It attaches only to the listeners the platform
    allows for its namespace.
- **Authentication:** JWT validation or OIDC at the proxy (e.g. Envoy Gateway's `SecurityPolicy`), so unauthenticated
  requests never reach the app and services share one implementation.
- **Rate limiting:** per client, route or API key, local or global (backed by Redis), to protect the API and the database
  from abuse and runaway clients.
- **Advanced routing:**
  - header- and weight-based routing, request mirroring;
  - retries and timeouts, request and response header rewrites;
  - many hostnames and apps behind one load balancer.
  Canary releases could then use `HTTPRoute` weights (Argo Rollouts' Gateway API plugin) instead of ALB target groups.
- **Observability:** per-route request metrics and access logs from the proxy, in the same format for every app.

Costs: a component on the request path that must run highly available (at least 2 replicas spread across zones, a PDB,
and autoscaling), plus one extra network hop.

### RDS restore test

Automated backups are on: 7-day retention and point-in-time recovery (`db_backup_retention_days`). A restore has never
been tested, so the RPO and RTO are unmeasured. The test would:
1. restore to a point in time with `aws rds restore-db-instance-to-point-in-time` into a new instance in the same
   subnet group, with `sg-db`;
2. run a pod with `psql` (as in db-bootstrap) against it, and check row counts and the latest writes;
3. time it, and write down the steps, the RTO (restore time) and the RPO (the newest restorable time, usually within 5 minutes);
4. delete the instance.

Also for prod: `db_deletion_protection = true`, `db_skip_final_snapshot = false`, snapshot copies to another region or
account, and Multi-AZ (`rds_multi_az`).

## Known gaps

- Single NAT gateway (toggle in `network/terraform.tfvars`, prod value in the prod stub).
- No CloudTrail trail managed here (see Future considerations).
- No IAM password policy; the account's password rules are left to its owner. CI never uses passwords or keys (OIDC roles only).
- The log archive bucket has no S3 server access logging of its own.
- The CI roles for network and edge use broad `ec2:*` / `acm:*` / `wafv2:*` service actions; instance launches are denied for `tf-network`.
- Any pull request can assume the `tf-<stack>-plan` roles, so a PR author can read the `plan_secrets` of `data` and
  `monitoring` (DB role passwords, JWT key, Valkey token, Grafana admin password), which the plans need because these
  values are in state. Prod: keep secrets out of state (see "CI/CD" → "Production improvements").
- `tf-eks`, `tf-bastion` and `tf-platform` create IAM roles under their paths without a permissions boundary, so the
  apply job of those stacks could create a role with more rights than its own. Prod: a boundary required on every role
  they create.
- One account and one region stand in for a multi-account, multi-region organization.
- No autoscaling, PodDisruptionBudgets, NetworkPolicies, canary releases or Gateway API ingress proxy (authentication,
  rate limiting, advanced routing), and no tested RDS restore (see "Not implemented").
- The `realworld_app` and `realworld_migrator` passwords are not rotated automatically. Prod: Secrets Manager rotation
  with alternating users; Reloader already rolls the pods when their Secret changes.
- Observability has no alert delivery, no platform alerts or metrics, and Grafana in the same cluster it watches
  (see "Observability" → "Production"). The AMP workspace ID is hardcoded in gitops, so recreating the `monitoring` stack
  needs a gitops commit.
- The vendored Load Balancer Controller IAM policy is the upstream one; it allows security group rule changes the
  controller never makes here (`enableBackendSecurityGroup: false`, `manage-backend-security-group-rules: "false"`).
