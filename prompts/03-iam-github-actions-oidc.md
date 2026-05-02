Create an IAM role that GitHub Actions can assume via OIDC to deploy our infrastructure.

Context:

- AWS account: `prod-deploy` (single-account scope for this ticket — we'll generalize later).
- Region: `eu-west-1`.
- Repo that should be allowed to assume the role: `factualminds/platform-infra`. Specifically the `main` branch and tag-based release refs (`refs/tags/v*`). No PR branches and no forks.
- The deploys we run from CI are: Terraform `plan`/`apply` against EKS, RDS, S3, IAM resources, plus pushing container images to a specific ECR repo `platform-services`.

Requirements:

- The OIDC provider `token.actions.githubusercontent.com` should already exist in the account — but if you can't assume that safely, create it idempotently. Pin the thumbprints to the values GitHub publishes; don't leave them stale.
- IAM role with a trust policy that:
  - Restricts `aud` to `sts.amazonaws.com`.
  - Restricts `sub` to the specific repo + the specific refs above. No wildcard `repo:org/*`.
  - No other principals can assume the role.
- Permissions policy scoped to the AWS APIs we actually use. Don't write `Action: "*"`. Don't use `Resource: "*"` unless an action genuinely requires it (and call out which ones do, with a comment).
- Session duration: 1 hour (we'll bump if we hit it). MFA condition not required for OIDC, but require `aws:SecureTransport=true`.
- Tag the role with `Environment=prod`, `Owner=platform`, `CostCenter=infra`, `ManagedBy=terraform`, `Purpose=ci-deploy`.

Deliverables: Terraform code, AWS provider 5.x, Terraform 1.10+. Output the role ARN. Document, in a short README, the `permissions:` block and `aws-actions/configure-aws-credentials` snippet a workflow needs to consume this role.

We've seen people scope OIDC too loose ("any branch in any repo in our org") — please don't do that. Tight `sub` claim or it doesn't ship.
