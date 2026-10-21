"""Architecture diagrams of the sandbox environment (us-east-1), rendered to three PNGs.

Diagrams as code with the Python "diagrams" library: edit this file and re-render (see README.md here), so the
pictures are reviewed and versioned like the rest of the repo.

One picture per concern, each read left to right with few edges:
  request-path.png     API clients to the database: DNS, ALB, pods, RDS and Valkey, and the subnets they sit in
  platform.png         what the in-cluster platform talks to in AWS (and GitHub), and why
  delivery-access.png  how changes and people get in: GitHub Actions through OIDC roles, engineers through Session Manager
"""
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, EC2Instance, EC2Instances, EKS
from diagrams.aws.general import General
from diagrams.aws.database import ElastiCache, RDSPostgresqlInstance
from diagrams.aws.management import AmazonManagedPrometheus, CloudwatchLogs, SystemsManager
from diagrams.aws.network import ALB, Endpoint, NATGateway, Route53HostedZone
from diagrams.aws.security import IAMRole, SecretsManager
from diagrams.aws.storage import SimpleStorageServiceS3Bucket
from diagrams.k8s.compute import Deploy, Job, Pod
from diagrams.k8s.ecosystem import ExternalDns
from diagrams.onprem.certificates import CertManager
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.logging import FluentBit
from diagrams.onprem.monitoring import Grafana
from diagrams.onprem.vcs import Github

FONT = "DejaVu Sans"
GRAPH = {"fontsize": "20", "fontname": FONT, "pad": "0.5", "nodesep": "0.7", "ranksep": "1.4", "splines": "spline"}
NODE = {"fontname": FONT, "fontsize": "12"}
EDGE = {"fontname": FONT, "fontsize": "11", "color": "#444444"}


def diagram(title, filename, **graph):
    return Diagram(title, filename=filename, outformat="png", show=False, direction="LR",
                   graph_attr={**GRAPH, **graph}, node_attr=NODE, edge_attr=EDGE)


def c(label):
    return Cluster(label, graph_attr={"fontname": FONT, "fontsize": "14"})


def e(label=""):
    return Edge(label=label)


# 1. Request path.
with diagram("Request path", "request-path"):
    users = Users("API clients")

    with c("AWS · us-east-1"):
        zone = Route53HostedZone("sandbox.gg-incode.click\n(delegated from\ngg-incode.click)")
        with c("VPC 10.10.0.0/16 · 3 AZs"):
            with c("public subnets"):
                alb = ALB("ALB\nACM wildcard cert\nTLS 1.2/1.3, /api only")
            with c("private-app subnets · EKS"):
                with c("namespace realworld"):
                    api = Pod("realworld-api × 2")
                    migrate = Job("migrations\n(ArgoCD Sync hook)")
            with c("private-data subnets (no internet route)"):
                postgres = RDSPostgresqlInstance("RDS PostgreSQL 18")
                valkey = ElastiCache("ElastiCache Valkey 8.1")

    users >> e("1. DNS") >> zone
    users >> e("2. HTTPS") >> alb >> e("HTTP") >> api
    api >> e("TLS") >> postgres
    api >> e("TLS") >> valkey
    migrate >> e("schema changes") >> postgres


# 2. Platform: in-cluster components and the services they use.
with diagram("Platform: what runs in the cluster and what it talks to", "platform", nodesep="0.3"):
    with c("EKS 1.36 · private API endpoint · 2 × t3.medium"):
        with c("platform"):
            lbc = Deploy("AWS Load Balancer\nController")
            dns = ExternalDns("ExternalDNS")
            eso = Deploy("External Secrets")
            CertManager("cert-manager, Reloader,\ndb-bootstrap\n(in-cluster only)")
        with c("observability"):
            alloy = Deploy("Grafana Alloy")
            grafana = Grafana("Grafana")
            fluentbit = FluentBit("Fluent Bit")
        with c("argocd"):
            argocd = ArgoCD("ArgoCD")
        nodes = EC2Instances("nodes (kubelet)")

    with c("AWS services (IRSA roles per component)"):
        alb = ALB("ALB")
        zone = Route53HostedZone("Route 53\nsandbox zone")
        secrets = SecretsManager("Secrets Manager")
        amp = AmazonManagedPrometheus("Managed Prometheus\n+ alert rules")
        logs = CloudwatchLogs("CloudWatch Logs")
        endpoints = Endpoint("VPC endpoints")
        ecr = ECR("ECR")
        nat = NATGateway("NAT gateway")

    github = Github("GitHub\ngitops, realworld-app")

    lbc >> e("creates from Ingress") >> alb
    dns >> e("records") >> zone
    eso >> e("syncs to K8s Secrets") >> secrets
    alloy >> e("remote write") >> amp
    grafana >> e("queries") >> amp
    grafana >> e("queries") >> logs
    fluentbit >> e("container logs") >> logs
    nodes >> e("image pulls") >> endpoints >> ecr
    argocd >> e("git pull (deploy keys)") >> nat >> github


# 3. Delivery and access.
with diagram("Delivery and access: no static keys, no inbound ports", "delivery-access"):
    with c("GitHub"):
        actions = GithubActions("Actions\ninfra · gitops · realworld-app")
    engineer = Users("Engineer\n(AWS CLI, kubectl)")

    with c("AWS · us-east-1"):
        roles = IAMRole("IAM roles ci/*\n(GitHub OIDC,\none per stack and job)")
        ssm = SystemsManager("Session Manager")
        state = SimpleStorageServiceS3Bucket("S3 Terraform state")
        ecr = ECR("ECR")
        apis = General("AWS APIs\n(Terraform plan/apply)")
        with c("VPC"):
            bastion = EC2Instance("bastion\n(no inbound,\nno SSH)")
            with c("private targets"):
                k8s = EKS("EKS API")
                postgres = RDSPostgresqlInstance("RDS PostgreSQL")
                valkey = ElastiCache("Valkey")

    actions >> e("OIDC token") >> roles
    roles >> e("state") >> state
    roles >> e("push images") >> ecr
    roles >> e("infra stacks") >> apis
    actions >> e("ArgoCD install\n(port forwarding)") >> ssm
    engineer >> e("IAM") >> ssm
    ssm >> bastion
    bastion >> e("port forwarding") >> k8s
    bastion >> postgres
    bastion >> valkey
