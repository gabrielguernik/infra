# Production designs

The designs behind the README's "Not implemented" lists: what each item needs and why it was left out of the sandbox.

These were planned (Phases 5 and 7) and deliberately left out of the sandbox.

## Autoscaling

The API runs a fixed 2 replicas on a fixed node group of 2 × t3.medium. The latency test in
[operations.md](operations.md#verified-with-injected-faults-2026-10-20) shows the cost: under
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

## PodDisruptionBudgets

None exist. A node drain (an EKS or AMI upgrade, Karpenter consolidation) may evict both API pods at once; the rolling
update strategy (`maxUnavailable: 0`) protects deploys, not drains.
- **The API:** `minAvailable: 1` (with 2 replicas). Topology spread already places the pods in different zones.
- **Platform controllers** running more than one replica would get one too. Single-replica controllers (sandbox
  sizing) can't have a useful PDB: it would block drains forever. In prod they'd run 2 replicas.

## NetworkPolicies

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

## Progressive delivery (canary)

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

## Ingress proxy (Gateway API)

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

## RDS restore test

Automated backups are on: 7-day retention and point-in-time recovery (`db_backup_retention_days`). A restore has never
been tested, so the RPO and RTO are unmeasured. The test would:
1. restore to a point in time with `aws rds restore-db-instance-to-point-in-time` into a new instance in the same
   subnet group, with `sg-db`;
2. run a pod with `psql` (as in db-bootstrap) against it, and check row counts and the latest writes;
3. time it, and write down the steps, the RTO (restore time) and the RPO (the newest restorable time, usually within 5 minutes);
4. delete the instance.

Also for prod: `db_deletion_protection = true`, `db_skip_final_snapshot = false`, snapshot copies to another region or
account, and Multi-AZ (`rds_multi_az`).

## Observability

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

## Terraform CI/CD

The pipeline stays small on purpose. A full production setup adds:
- **Approvals and branch rules:** a GitHub plan with required reviewers on the environments, prod requiring two people and
  CODEOWNERS per area. A branch ruleset on `main`: PRs only, required checks (static, plans), up-to-date branches,
  signed commits. A merge queue so merges, and their plans, are serialized.
- **One account per environment** (sandbox, staging, prod), each with its own state bucket, KMS key and CI roles, and
  changes promoted sandbox → staging → prod through the same plan and approve steps per environment.
- **Exact plan apply:** store the reviewed plan file encrypted (an S3 bucket with KMS, per run) and apply that file,
  instead of re-planning and comparing change lists. Today's comparison checks addresses and actions, not attribute values.
- **Narrower plan roles:** a custom read policy per stack instead of `ReadOnlyAccess` (which can read any S3 object and
  many configurations). The Valkey auth token is the last generated secret in state (ElastiCache's `auth_token` has no
  write-only form): ElastiCache RBAC users managed outside Terraform would remove it.
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

## Security services

- **CloudTrail.** A multi-region trail to the log archive (management events, log file validation), optionally with
  CloudWatch Logs for alerting on API activity. It is not in the sandbox; in a multi-account setup it becomes an organization trail
  in a dedicated log-archive account.
- **Detection:** GuardDuty and Security Hub, enabled organization-wide from a delegated administrator account.
- **WAF:** the edge module already supports a web ACL (`enable_waf`); turn it on for prod.

## Log archive cost

Logs expire after 365 days and stay in S3 Standard the whole time. Storage-class transitions were left out on purpose: at
sandbox volume the bucket holds a few GB, and the cheaper classes would not pay for themselves:

- Standard-IA and Glacier Instant Retrieval bill every object as at least 128 KB, and most flow-log and ALB-log objects are smaller.
- Each transition is charged per object (per 1,000 requests), and log buckets hold many small objects.
- Standard-IA bills a minimum of 30 days of storage, and Glacier IR a minimum of 90 days.

At production volume (hundreds of GB per month) a rule such as Standard → Standard-IA at 30 days → Glacier IR at 90 days
roughly halves storage cost. Add it together with an `object_size_greater_than` filter (e.g. 128 KB) so small objects stay in Standard.
