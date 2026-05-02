Build a Terraform baseline module we can call from each AWS account in our Organization. Each call lays down the same foundational guardrails so we stop hand-rolling them per account.

Context:

- We have ~12 AWS accounts under one Organization, grouped into OUs: `Workloads/Prod`, `Workloads/NonProd`, `Sandbox`, `Security`, `Tooling`. We're standing up four more accounts this quarter and the per-account drift is already painful.
- The module is called once per account from a central infra repo. Provider aliases are needed because some resources (e.g., IAM Identity Center role assignments) live in the management account while everything else lives in the target account.
- Region pin: `eu-west-1` primary, `eu-central-1` for DR. Module should accept a region var.

What the baseline must include:

- A standard provider configuration with `default_tags` populated from input variables (`environment`, `owner`, `cost_center`, `data_class`, `managed_by="terraform"`, `account_purpose`). Every downstream resource picks these up automatically.
- An IAM role for human break-glass access, assumable from the management account via SSO, with `AdministratorAccess` *only* if the input `account_role == "sandbox"`. Otherwise the break-glass role gets `ReadOnlyAccess` plus a small write scope that the caller passes in.
- An IAM role for CI/CD deploys, assumable via GitHub Actions OIDC. Trust policy must scope `sub` to a specific repo passed in via variable, and specific refs (`main` + tags). No org-wide wildcards.
- AWS Config recorder + delivery channel pointing at a central S3 bucket (passed in as a variable — don't create it here).
- A CloudTrail trail for the account, encrypted with a customer-managed KMS key the module creates, log file validation enabled, multi-region.
- An S3 bucket for ad-hoc account artifacts, KMS-encrypted, versioned, public access blocked.

Requirements:

- Provider aliases: `aws.target` (the account being baselined) and `aws.management` (the org management account). Pass both in via the caller.
- Outputs: break-glass role ARN, CI deploy role ARN, CloudTrail ARN, KMS key ARNs, S3 bucket name.
- Terraform 1.10+, AWS provider 5.x. Module should be in `modules/account-baseline/` with the usual `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, plus a `README.md` and an `examples/` folder with one working caller.
- Tags: every resource picks up `default_tags`. Anything that doesn't honour `default_tags` (e.g., some IAM resources) gets explicit tag merges.

Deliverables: a module the platform team can reference from each per-account root in our infra repo. We'd rather have boring and consistent than clever. Reviewers will check for `default_tags` on the provider, OIDC `sub` scoping, and that the management-account provider alias is actually used.
