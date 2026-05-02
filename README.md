# terraform-claude-skill-eval

Reproducible evaluation harness comparing **default Claude Code** to **Claude Code with [`terraform-claude-skill`](https://github.com/antonbabenko/terraform-claude-skill) installed**, on four realistic AWS Terraform prompts.

This is the artifact behind the FactualMinds blog post _["Terraform + Claude Skills on AWS: A Production Walkthrough (and 5 Things It Still Won't Do for You)"](https://www.factualminds.com/blog/terraform-claude-skill-aws-production-guide/)_. Clone it, run `make eval`, and reproduce the numbers in the post against your own Claude Code install.

**Last updated:** 2026-05-02.

---

## What This Measures

For every (prompt × variant × run) cell, the harness records eight dimensions:

1. **`files_produced`** — count of `.tf` / `.tfvars` files extracted from the model's response.
2. **`terraform_fmt_clean`** — does `terraform fmt -check -recursive` exit 0?
3. **`terraform_validate_clean`** — does `terraform init -backend=false && terraform validate` exit 0?
4. **`terraform_plan_clean`** — does `terraform plan -refresh=false` complete without an error (exit 0 or 2 — diff is fine, error is not)? **No real AWS calls happen** — `init -backend=false` keeps providers offline.
5. **`tfsec_findings_count`** — number of findings from `tfsec --format json` (null if `tfsec` isn't on `$PATH`).
6. **`iam_wildcard_count`** — count of `Action: "*"` occurrences across the produced `.tf` files (greps both JSON-style and HCL-style spellings).
7. **`hardcoded_arn_count`** — count of fully-qualified ARNs containing a literal 12-digit account ID (i.e., not interpolated from a variable, data source, or `aws_caller_identity`).
8. **`default_tags_present`** — does any `.tf` file include a `default_tags { … }` block on the AWS provider?

The aggregator (`bin/aggregate.mjs`) averages these across runs and prompts, and writes a markdown table that pastes directly into the post.

---

## Why This Exists

AI-assisted Terraform output is fast, syntactically valid, and almost always wrong in ways that only show up in production: default VPCs, `Action: "*"` IAM, unencrypted state buckets, hardcoded account IDs, missing tags. The first wave of agents got us to "compiles." The terraform-claude-skill claims to get us to "ships." This harness measures whether that claim survives contact with realistic prompts — and exposes the residual gap so readers know what they still own.

We deliberately picked four prompts where the ambiguity in the request is the test. A skilled human reviewer would push back on the same things the skill should: tight OIDC `sub` conditions, KMS-encrypted state, scoped IAM, `default_tags`. Default-Claude-without-the-skill almost never does.

---

## Prerequisites

- **Claude Code CLI** installed and authenticated (`claude --version` works).
- **`terraform-claude-skill`** installed at `~/.claude/skills/terraform/` (clone Anton Babenko's repo there). Required only for the `skill` variant.
- **Terraform 1.10+** (`terraform version`). The state-backend prompt assumes 1.10's S3-native locking.
- **Node 22+** (`node --version`). Used by the markdown extractor and aggregator. No npm install — there are zero runtime dependencies.
- **`tfsec`** (optional). Without it, the security-findings dimension is recorded as `null` and the rest of the harness still runs.
- **No AWS credentials needed.** The harness uses `terraform init -backend=false` and `terraform plan -refresh=false`. Nothing calls AWS APIs.

Configure the Claude invocation if your CLI differs from the default `claude --print`:

```bash
export CLAUDE_CMD='claude --print'                  # adjust to your version
export CLAUDE_SKILL_FLAG='/terraform'               # whatever invokes the skill
```

---

## Quickstart

```bash
git clone <this-repo> terraform-claude-skill-eval
cd terraform-claude-skill-eval

# 4 prompts × 2 variants × 2 runs each = 16 Claude invocations
make eval

# Or specify everything explicitly:
make eval RUN_ID=20260502-1430 PROMPTS=01,02,03,04 RUNS_PER=2

# Re-aggregate without re-running Claude:
make aggregate RUN_ID=20260502-1430
```

Output lands under `runs/<RUN_ID>/`:

```
runs/20260502-1430/
├── 01/
│   ├── default/run-1/{output.md, *.tf, scorecard.json, terraform-*.log, tfsec.json}
│   ├── default/run-2/...
│   ├── skill/run-1/...
│   └── skill/run-2/...
├── 02/ ...
├── 03/ ...
├── 04/ ...
├── summary.csv
└── summary.md           ← paste this into the post
```

A representative example sits at [`runs/sample-run/summary.md`](./runs/sample-run/summary.md). It's labelled as a sample on its first line.

---

## Reading the Output

`summary.md` has two sections.

The **aggregate comparison** averages each dimension across every prompt and every run, and is the table to lift into a blog post. Percentage dimensions show as `pct` (`100%`); count dimensions show as means (`11.4`).

The **per-prompt breakdown** shows the same dimensions split by prompt, so you can see which scenarios benefit most. In our runs, prompt 03 (IAM + OIDC) is where the gap on `iam_wildcard_count` and `hardcoded_arn_count` is widest, and prompt 04 (multi-account baseline) is where the file-count delta is widest.

`summary.csv` has one row per (prompt × variant × run) cell. Open it in a spreadsheet if you want to slice it differently — e.g., variance across runs, or a single prompt's behaviour over time as Claude versions change.

---

## Reproducing Our Published Numbers

The published post quotes a specific table:

| Metric | Default Claude | With `/terraform` |
| --- | --- | --- |
| Files produced (avg) | 1.3 | 11.4 |
| `terraform validate` clean on first run | 100% | 100% |
| `terraform plan` clean on first run | 25% | 100% |
| tfsec High/Critical findings | 6.5 | 0 |
| IAM wildcard actions | 4.2 | 0 |
| Hardcoded account IDs / ARNs | 3.0 | 0 |
| `default_tags` present | 0% | 100% |

These were produced from a `RUNS_PER=2` execution against Anthropic's then-current Claude model and the skill commit pinned in our internal `company-rules.md`. Your numbers will not match exactly — the model is non-deterministic, and the skill upstream is a moving target. We expect the **direction and magnitude** of every dimension to reproduce, not the absolute decimals.

If your own run shows the skill failing to close the gap on, say, `default_tags` or `iam_wildcard_count`, that's a bug worth filing upstream. Open an issue on this repo and we'll dig in.

---

## Limitations

This harness is honest about what it doesn't measure:

- **Single AWS region.** Every prompt targets `eu-west-1`. We didn't test multi-region behaviour, region-affinity quirks, or services that only exist outside `eu-west-1`.
- **No Control Tower / Organizations test.** The multi-account-baseline prompt asks for a module shape, not a deployed landing zone. We didn't test SCP interactions, Account Factory hooks, or Identity Center provisioning end-to-end.
- **No Windows runners.** Bash + Node + Terraform on macOS / Linux. The harness will not run on PowerShell as written.
- **Cost dimension is informational.** The published post explicitly says infracost output is informational, not a blocker — and so we deliberately don't score cost. Oversized `m5.large` worker nodes, single-AZ deployments, on-demand-only capacity choices are judgement calls the skill flags but doesn't block on. Scoring them automatically would punish reasonable defaults.
- **No drift simulation.** Drift between Git and AWS is the most expensive class of Terraform failure (per the post's "5 things the skill still won't do" list). The harness only scores authoring-time output. Drift-detection coverage is on you.
- **Markdown extraction is best-effort.** If Claude returns a Terraform module entirely as ASCII tree art with no fenced code blocks, `bin/extract-tf.mjs` writes zero files and the cell scores accordingly. That's a model-output failure, not a harness bug.

---

## Versions Tested

| Tool | Version (as of 2026-05-02) |
| --- | --- |
| Claude Code CLI | 1.x (whatever `claude --version` reports today) |
| `terraform-claude-skill` | upstream `main`, pinned per-team in `company-rules.md` |
| Terraform | 1.10.4 |
| AWS provider | 5.x |
| `tfsec` | 1.28.x |
| Node | 22.x |
| OS | macOS 14, Ubuntu 24.04 |

When you reproduce, log your own versions in the run directory — `runs/<RUN_ID>/versions.txt` is a sensible spot. Future you will thank present you.
