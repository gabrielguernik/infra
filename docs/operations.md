# Operations

Step-by-step procedures for the sandbox. The overview is in the [README](../README.md).

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
   This first apply is manual because it creates the roles CI uses, `ci/tf-bootstrap` included. After it, CI plans
   and applies bootstrap like any other stack. If a bootstrap change ever breaks `ci/tf-bootstrap` itself (its trust
   can only be changed by an admin), apply it by hand the same way, without the backend steps.
3. **GitHub environments** (repository settings, not in code), each with deployment branch `main` only: `sandbox` in
   `infra` (the only subject the `tf-<stack>` write roles trust), `sandbox-us-east-1` in `gitops` (the ArgoCD install
   role) and `sandbox` in `realworld-app` (the gitops deploy key). Removing that branch rule would let any branch
   assume these roles.
4. Apply the remaining stacks in order.

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

1. `live/accounts/sandbox/_global/bootstrap`: by hand only the first time (see "Setup from zero" above), then by CI
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
After the first build, changes go through CI ([ci.md](ci.md)): a PR plans them, and merging applies them in this order.

### Destroy order (environment, between work sessions)

First remove the apps, so the controllers delete what they created outside Terraform (the ALB, its target groups and
DNS records). Otherwise the ALB's network interfaces block deleting the subnets and `sg-alb`. From the gitops repo:

```bash
out=$(scripts/eks-tunnel.sh sandbox us-east-1) && eval "$out"   # stops here if the tunnel fails
kubectl --context sandbox-us-east-1 -n argocd delete application apps        # the root first, or it recreates the ApplicationSet
kubectl --context sandbox-us-east-1 -n argocd delete applicationset apps     # Applications → Ingress → ALB and DNS records
kubectl --context sandbox-us-east-1 -n argocd wait --for=delete application/realworld --timeout=5m
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerName"  # []
kill -INT "$TUNNEL_PID"
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
If the status isn't `Online`, see "Troubleshooting" below.

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
| Tunnel opens but every connection logs `Connection to destination port failed` | Abandoned sessions (closed laptops, killed terminals) stay open on the bastion and break new port forwards. List and end your own sessions, then reopen the tunnel: `aws ssm describe-sessions --state Active --filters "key=Owner,value=$(aws sts get-caller-identity --query Arn --output text)" --query 'Sessions[].SessionId' --output text \| xargs -n1 aws ssm terminate-session --session-id` |
| valkey-cli `certificate verify failed` | That `valkey-cli` has no CA bundle (the official container image doesn't ship one): pass `--cacert AmazonRootCA1.pem`. |
| psql `server certificate does not match host name` | Use `host=<real endpoint> hostaddr=127.0.0.1`, not `host=localhost`. |
| Everything worked yesterday, nothing works today | The environment was destroyed between sessions. Apply it again, then repeat step 3b (new cluster endpoint). |

## Grafana and incident response

### Open Grafana

From the gitops repo (Grafana is private, like the ArgoCD UI):

```bash
out=$(scripts/eks-tunnel.sh sandbox us-east-1) && eval "$out"   # stops here if the tunnel fails
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
| An in-cluster k6 load test (300 virtual users on article and tag reads, 15 min) | p95 rose to about 600 ms. `RealworldHighLatency` went pending 5 min into the load and fired 10 min later ("p95 latency is 508.5ms"). The runbook pinned the cause on the API pods, not the database: `/api/tags` and `/api/articles` were slow, both pods were CPU-bound at about 0.92 cores (Node runs one thread) with about 430 ms of event-loop lag, and up to 183 queries waited per pod, while RDS CPU peaked at 14%. The fix is more pods: autoscaling, not implemented (see [production.md](production.md#autoscaling)). k6 itself measured p95 857 ms with 0 errors; the app's histogram reads lower because it starts timing only after the event loop picks up a request. |

The first run showed two gaps, both fixed:
- **The error alert first used the app's own metrics,** which never see the ALB's 503s, so a total outage would have gone unnoticed.
- **Readiness failures weren't logged.** The probe is excluded from the access log, so nothing said why pods were unready.
