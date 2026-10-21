"""Architecture diagram of the sandbox environment (us-east-1), rendered to architecture.png.

Diagrams as code with the Python "diagrams" library: edit this file and re-render (see README.md here), so the
picture is reviewed and versioned like the rest of the repo.

Edge styles:
  solid blue    user traffic (request path)
  solid green   the app's and the platform's data flows (secrets, metrics, logs, images)
  dashed gray   control: controllers that manage AWS resources, ArgoCD pulling git
  dashed orange delivery and access: GitHub Actions through OIDC roles, engineers through Session Manager
Control and delivery edges don't affect the layout (constraint=false): the request path sets the top-to-bottom order.
"""
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, EC2Instance
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

USER = dict(color="#1f5fbf", penwidth="2")
DATA = dict(color="#2e8b57")
CONTROL = dict(color="#777777", style="dashed", constraint="false")
DELIVERY = dict(color="#e07b00", style="dashed", constraint="false")

graph_attr = {
    "fontsize": "22",
    "fontname": "DejaVu Sans",
    "pad": "0.4",
    "nodesep": "0.45",
    "ranksep": "0.9",
    "splines": "spline",
}
node_attr = {"fontname": "DejaVu Sans", "fontsize": "12"}
cluster_font = {"fontname": "DejaVu Sans", "fontsize": "14"}


def c(label, **extra):
    """A cluster with the shared font settings."""
    return Cluster(label, graph_attr={**cluster_font, **extra})


with Diagram(
    "RealWorld API — sandbox (AWS us-east-1)",
    filename="architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    users = Users("API clients")
    engineer = Users("Engineer\n(AWS CLI, kubectl)")

    with c("GitHub"):
        repos = Github("infra · gitops\nrealworld-app")
        actions = GithubActions("Actions\n(OIDC, no keys)")

    with c("AWS account 965140467182 · us-east-1"):
        zone = Route53HostedZone("sandbox.gg-incode.click\n(delegated from\ngg-incode.click)")

        with c("VPC 10.10.0.0/16 · 3 AZs"):
            with c("public subnets"):
                alb = ALB("ALB\nACM wildcard cert\nTLS 1.2/1.3")
                nat = NATGateway("NAT gateway")

            with c("private-app subnets"):
                bastion = EC2Instance("Session Manager\nbastion\n(no inbound)")

                with c("EKS 1.36 · private API endpoint · 2 × t3.medium"):
                    with c("realworld"):
                        api = Pod("realworld-api × 2")
                        migrate = Job("migrations\n(Sync hook)")
                    with c("argocd"):
                        argocd = ArgoCD("ArgoCD")
                    with c("platform"):
                        lbc = Deploy("AWS Load Balancer\nController")
                        dns = ExternalDns("ExternalDNS")
                        eso = Deploy("External Secrets")
                        misc = CertManager("cert-manager\nReloader\ndb-bootstrap")
                    with c("observability"):
                        alloy = Deploy("Grafana Alloy")
                        grafana = Grafana("Grafana")
                        fluentbit = FluentBit("Fluent Bit")

            with c("private-data subnets (no internet route)"):
                postgres = RDSPostgresqlInstance("RDS PostgreSQL 18")
                valkey = ElastiCache("ElastiCache\nValkey 8.1")

            endpoints = Endpoint("VPC endpoints\n(S3, ECR, STS, SSM, ...)")

        with c("regional services"):
            ecr = ECR("ECR realworld-api\n(pulled through\nVPC endpoints)")
            secrets = SecretsManager("Secrets Manager")
            amp = AmazonManagedPrometheus("Managed Prometheus\n+ alert rules")
            logs = CloudwatchLogs("CloudWatch Logs")
            ssm = SystemsManager("Session Manager\n+ Parameter Store")
            s3 = SimpleStorageServiceS3Bucket("S3: Terraform state,\nlog archive")
            roles = IAMRole("IAM roles\n(CI, IRSA)")

    # Request path.
    users >> Edge(label="DNS", **USER) >> zone
    users >> Edge(label="HTTPS", **USER) >> alb >> Edge(**USER) >> api
    api >> Edge(label="TLS", **USER) >> postgres
    api >> Edge(label="TLS", **USER) >> valkey
    migrate >> Edge(**DATA) >> postgres

    # Data flows of the app and the platform.
    eso >> Edge(**DATA) >> secrets
    alloy >> Edge(label="remote write", **DATA) >> amp
    grafana >> Edge(**DATA) >> amp
    grafana >> Edge(**DATA) >> logs
    fluentbit >> Edge(**DATA) >> logs
    api >> Edge(**DATA) >> ecr

    # Control: controllers managing AWS, ArgoCD pulling git.
    lbc >> Edge(**CONTROL) >> alb
    dns >> Edge(label="records", **CONTROL) >> zone
    argocd >> Edge(label="git pull", **CONTROL) >> nat >> Edge(**CONTROL) >> repos

    # Delivery and access.
    repos >> Edge(**DELIVERY) >> actions
    actions >> Edge(label="OIDC", **DELIVERY) >> roles
    roles >> Edge(label="terraform state", **DELIVERY) >> s3
    actions >> Edge(label="push images", **DELIVERY) >> ecr
    engineer >> Edge(label="IAM", **DELIVERY) >> ssm >> Edge(**DELIVERY) >> bastion
    bastion >> Edge(label="port forwarding:\nK8s API, DB, cache", **DELIVERY) >> postgres
