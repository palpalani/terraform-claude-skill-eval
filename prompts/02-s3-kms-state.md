Set up our Terraform state backend on AWS. We're starting a new platform repo and want the state foundation right before we put any real infrastructure into it.

Context:

- Account: a dedicated `tooling` account in our AWS Organization. Region: `eu-west-1`.
- Environment label: `shared` (this backend is shared across `dev`, `staging`, `prod` workloads — separate state files per workload, same bucket).
- Naming convention: `<org>-<purpose>-<env>-<region>` (e.g., `factualminds-tfstate-shared-eu-west-1`).
- We're on Terraform CLI 1.10.4. The team has read the 1.10 release notes — pick whatever locking approach is current best practice for that version. Don't over-engineer if a feature already shipped that removes a dependency.

Requirements:

- An S3 bucket for state with:
  - Versioning enabled (we want to recover from accidental state corruption).
  - Server-side encryption with a customer-managed KMS key (not AWS-managed default).
  - Public access fully blocked.
  - Lifecycle rule that expires non-current versions after 90 days.
- State locking that prevents two engineers from running `apply` against the same state simultaneously. Use the most current Terraform-native option appropriate for 1.10+.
- A KMS key with rotation enabled, alias `alias/<org>-tfstate-shared`, and a key policy that allows the tooling-account root + the platform IAM role we'll create separately to encrypt/decrypt.
- Tags on every resource: `Environment=shared`, `Owner=platform`, `CostCenter=infra`, `ManagedBy=terraform`, `DataClass=restricted`.

Deliverables: Terraform code split across files (don't dump everything in `main.tf`). Variables file. Outputs for the bucket name, KMS key ARN, and whatever lock identifier the chosen locking approach uses. Short README on how to bootstrap and how downstream repos should consume this backend.
