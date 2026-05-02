Stand up a production-grade VPC and EKS cluster in `eu-west-1` for our platform team.

Context:

- Environment: `prod`. Naming convention: `<env>-<workload>-<resource>` (e.g., `prod-platform-eks`).
- We run regulated SaaS workloads. Auditors look at this account quarterly, so default to the safer choice when an option is ambiguous.
- We already have a Route 53 zone (`platform.example.internal`) and a Transit Gateway attachment ID we'll wire up later — leave a clean variable for it.
- Engineering team is ~25 people. Cost-conscious but not aggressively so; correctness beats a 10% saving.

Requirements:

- A new VPC with three private subnets and three public subnets across three AZs. NAT for egress from private subnets. Reasonable CIDR sizing for ~500 pods at peak.
- An EKS cluster (latest stable minor version) with a managed node group sized for steady-state plus headroom. Workloads run in private subnets.
- IRSA must work out of the box — i.e., the cluster's OIDC provider is wired up so we can grant pod-level IAM roles immediately.
- Terraform CLI 1.10+, AWS provider 5.x. Output state locally for now (we'll wire S3 backend in a follow-up task).
- Tag every resource with `Environment=prod`, `Owner=platform`, `CostCenter=infra`, `ManagedBy=terraform`.

Deliverables: Terraform code that `terraform init`, `terraform validate`, and `terraform plan` cleanly. README with how to run it. Prefer `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws` from the registry — don't reinvent.

Notes from past tickets: we've been bitten before by control-plane logging being off and by node groups getting public endpoints by accident. Reviewer will check for both.
