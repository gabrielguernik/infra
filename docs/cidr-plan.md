# CIDR plan

One /16 per environment and region, from 10.0.0.0/8. Blocks never overlap, so any two VPCs can be peered or attached to a Transit Gateway later.

| Block | Environment | Region | Status |
|---|---|---|---|
| 10.10.0.0/16 | sandbox | us-east-1 | in use |
| 10.11.0.0/16 | sandbox | second region | reserved |
| 10.20.0.0/16 | prod | us-east-1 | reserved (stub) |
| 10.21.0.0/16 | prod | second region | reserved |
| 10.30.0.0/16 – 10.39.0.0/16 | future environments | — | free |

## Inside a VPC (3 AZs)

| Tier | Size | Subnets (sandbox) | Use |
|---|---|---|---|
| public | /24 × 3 | 10.10.0.0/24, 10.10.1.0/24, 10.10.2.0/24 | ALB, NAT gateways |
| private-data | /24 × 3 | 10.10.10.0/24, 10.10.11.0/24, 10.10.12.0/24 | RDS, ElastiCache; no internet route |
| private-app | /19 × 3 | 10.10.32.0/19, 10.10.64.0/19, 10.10.96.0/19 | EKS nodes and pods |

The app subnets are large because the VPC CNI gives every pod an IP from the subnet: about 8,000 addresses per AZ.
10.10.128.0/17 is left free for a second app range or for custom pod networking.
For a large scale production system, extra ranges could be added by adding another /16 CIDR range to the VPC.

The account is limited to us-east-1 by an organization SCP, so the plan starts there instead of eu-west-1.
