#!/usr/bin/env bash
# run-eval.sh — Run one Claude Code invocation per (prompt × variant) and score the output.
#
# Usage:
#   bin/run-eval.sh --run-id 20260502-1430 --prompts 01,02,03,04 --runs-per 2
#
# Environment overrides (set these before running if your CLI differs):
#   CLAUDE_CMD              How to invoke Claude Code in headless / non-interactive mode.
#                           Default: 'claude --print'  (Claude Code's headless flag — adjust
#                           to whatever your installed CLI version supports).
#   CLAUDE_SKILL_FLAG       Extra flag(s) passed to Claude when running the SKILL variant.
#                           Default: '/terraform'  (leading slash invokes the skill in Claude Code).
#   TERRAFORM_BIN           Default: 'terraform'.
#   TFSEC_BIN               Default: 'tfsec'.  Set to '' (empty) to skip tfsec scoring.
#
# What this script does NOT do:
#   - It does not run `terraform apply`. Ever.
#   - It does not call `terraform plan` against real AWS — `init -backend=false` only.
#   - It does not assume tfsec is installed; if missing, that dimension is recorded as null.

set -euo pipefail

#-----------------------------------------------------------------------------
# Defaults & arg parsing
#-----------------------------------------------------------------------------
RUN_ID=""
PROMPTS="01,02,03,04"
RUNS_PER="2"
VARIANTS="default,skill"

CLAUDE_CMD="${CLAUDE_CMD:-claude --print}"
CLAUDE_SKILL_FLAG="${CLAUDE_SKILL_FLAG:-/terraform}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
TFSEC_BIN="${TFSEC_BIN:-tfsec}"

usage() {
  sed -n '2,30p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)    RUN_ID="$2";    shift 2 ;;
    --prompts)   PROMPTS="$2";   shift 2 ;;
    --runs-per)  RUNS_PER="$2";  shift 2 ;;
    --variants)  VARIANTS="$2";  shift 2 ;;
    -h|--help)   usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date -u +%Y%m%d-%H%M)"
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${ROOT_DIR}/runs/${RUN_ID}"
mkdir -p "$RUN_DIR"

echo "==> Run ID:     ${RUN_ID}"
echo "==> Run dir:    ${RUN_DIR}"
echo "==> Prompts:    ${PROMPTS}"
echo "==> Variants:   ${VARIANTS}"
echo "==> Runs/cell:  ${RUNS_PER}"
echo "==> CLAUDE_CMD: ${CLAUDE_CMD}"

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------

# Extract fenced HCL/Terraform code blocks from a markdown file into individual
# .tf files in the target dir. Heuristic — Claude is inconsistent about how it
# names files in markdown. We look for "# filename: foo.tf" or "// filename:" or
# a heading like "### foo.tf" or "**foo.tf**" right above a fenced block.
extract_tf_files() {
  local md="$1"
  local out_dir="$2"
  node "${ROOT_DIR}/bin/extract-tf.mjs" "$md" "$out_dir"
}

# Build the payload we feed to Claude. Default = the prompt as-is. Skill = prompt
# preceded by the skill activation flag, on its own line.
build_payload() {
  local variant="$1"
  local prompt_file="$2"
  if [[ "$variant" == "skill" ]]; then
    printf '%s\n\n' "$CLAUDE_SKILL_FLAG"
    cat "$prompt_file"
  else
    cat "$prompt_file"
  fi
}

run_claude() {
  local variant="$1"
  local prompt_file="$2"
  local out_md="$3"

  build_payload "$variant" "$prompt_file" \
    | $CLAUDE_CMD \
    > "$out_md" \
    2> "${out_md%.md}.stderr.log" \
    || {
      echo "    (Claude exited non-zero — see $(basename "${out_md%.md}.stderr.log"))"
    }
}

# Score one (prompt × variant × run) cell. Writes scorecard.json.
score_cell() {
  local cell_dir="$1"
  local prompt_id="$2"
  local variant="$3"
  local run_index="$4"

  pushd "$cell_dir" > /dev/null

  # 1. files_produced — count .tf and .tfvars
  local files_produced
  files_produced=$(find . -maxdepth 3 -type f \( -name '*.tf' -o -name '*.tfvars' \) | wc -l | tr -d ' ')

  # 2. terraform fmt -check
  local fmt_exit=99
  local fmt_log="terraform-fmt.log"
  if [[ "$files_produced" -gt 0 ]]; then
    "$TERRAFORM_BIN" fmt -check -recursive . > "$fmt_log" 2>&1 && fmt_exit=0 || fmt_exit=$?
  fi

  # 3. terraform init -backend=false
  local init_exit=99
  local init_log="terraform-init.log"
  if [[ "$files_produced" -gt 0 ]]; then
    "$TERRAFORM_BIN" init -backend=false -input=false -no-color > "$init_log" 2>&1 && init_exit=0 || init_exit=$?
  fi

  # 4. terraform validate
  local validate_exit=99
  local validate_log="terraform-validate.log"
  if [[ "$files_produced" -gt 0 && "$init_exit" -eq 0 ]]; then
    "$TERRAFORM_BIN" validate -no-color > "$validate_log" 2>&1 && validate_exit=0 || validate_exit=$?
  fi

  # 5. terraform plan — refresh-disabled, no real AWS calls. Considered "clean"
  # if exit-code is 0 (no diff) or 2 (diff present, but plan succeeded). Exit
  # code 1 = error.
  local plan_exit=99
  local plan_log="terraform-plan.log"
  if [[ "$files_produced" -gt 0 && "$validate_exit" -eq 0 ]]; then
    "$TERRAFORM_BIN" plan -refresh=false -input=false -lock=false -no-color -detailed-exitcode > "$plan_log" 2>&1 && plan_exit=0 || plan_exit=$?
  fi
  local plan_clean=0
  if [[ "$plan_exit" -eq 0 || "$plan_exit" -eq 2 ]]; then plan_clean=1; fi

  # 6. tfsec
  local tfsec_findings_count="null"
  if [[ -n "$TFSEC_BIN" ]] && command -v "$TFSEC_BIN" > /dev/null 2>&1 && [[ "$files_produced" -gt 0 ]]; then
    "$TFSEC_BIN" --format json --soft-fail . > tfsec.json 2> tfsec.stderr.log || true
    tfsec_findings_count=$(node -e '
      try {
        const data = JSON.parse(require("fs").readFileSync("tfsec.json","utf8"));
        const arr = data.results || [];
        process.stdout.write(String(arr.length));
      } catch { process.stdout.write("null"); }
    ')
  fi

  # 7. iam_wildcard_count — Action: "*" anywhere in .tf files
  local iam_wildcard_count=0
  if [[ "$files_produced" -gt 0 ]]; then
    iam_wildcard_count=$(grep -REho '"Action"[[:space:]]*:[[:space:]]*"\*"|Action[[:space:]]*=[[:space:]]*"\*"' --include='*.tf' . 2>/dev/null | wc -l | tr -d ' ')
  fi

  # 8. hardcoded_arn_count — concrete arn:aws:<service>:<region>:<12-digit-account>:...
  # We exclude lines that look like variable references (var., local., data.) right
  # before the ARN, and exclude policy ARNs that come from the AWS-managed namespace
  # (arn:aws:iam::aws:policy/...).
  local hardcoded_arn_count=0
  if [[ "$files_produced" -gt 0 ]]; then
    hardcoded_arn_count=$(grep -REho 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[A-Za-z0-9_/.:-]+' --include='*.tf' . 2>/dev/null | wc -l | tr -d ' ')
  fi

  # 9. default_tags_present
  local default_tags_present=0
  if grep -REq 'default_tags[[:space:]]*\{' --include='*.tf' . 2>/dev/null; then
    default_tags_present=1
  fi

  # Emit scorecard.json
  cat > scorecard.json <<JSON
{
  "prompt_id": "${prompt_id}",
  "variant": "${variant}",
  "run_index": ${run_index},
  "files_produced": ${files_produced},
  "terraform_fmt_clean": $([ "$fmt_exit" -eq 0 ] && echo true || echo false),
  "terraform_init_clean": $([ "$init_exit" -eq 0 ] && echo true || echo false),
  "terraform_validate_clean": $([ "$validate_exit" -eq 0 ] && echo true || echo false),
  "terraform_plan_clean": $([ "$plan_clean" -eq 1 ] && echo true || echo false),
  "tfsec_findings_count": ${tfsec_findings_count},
  "iam_wildcard_count": ${iam_wildcard_count},
  "hardcoded_arn_count": ${hardcoded_arn_count},
  "default_tags_present": $([ "$default_tags_present" -eq 1 ] && echo true || echo false)
}
JSON

  popd > /dev/null
}

#-----------------------------------------------------------------------------
# Main loop
#-----------------------------------------------------------------------------
IFS=',' read -ra PROMPT_LIST <<< "$PROMPTS"
IFS=',' read -ra VARIANT_LIST <<< "$VARIANTS"

for prompt_id in "${PROMPT_LIST[@]}"; do
  prompt_file="${ROOT_DIR}/prompts/${prompt_id}-"*.md
  prompt_file=$(echo $prompt_file)
  if [[ ! -f "$prompt_file" ]]; then
    echo "!! prompt file not found for id ${prompt_id} — skipping"
    continue
  fi
  echo ""
  echo "## prompt ${prompt_id} :: ${prompt_file##*/}"

  for variant in "${VARIANT_LIST[@]}"; do
    for ((i=1; i<=RUNS_PER; i++)); do
      cell_dir="${RUN_DIR}/${prompt_id}/${variant}/run-${i}"
      mkdir -p "$cell_dir"
      out_md="${cell_dir}/output.md"

      echo "  -> ${variant} run ${i}/${RUNS_PER}"
      run_claude "$variant" "$prompt_file" "$out_md"
      extract_tf_files "$out_md" "$cell_dir" || true
      score_cell "$cell_dir" "$prompt_id" "$variant" "$i"
    done
  done
done

echo ""
echo "==> Done. Aggregate with:"
echo "    node bin/aggregate.mjs --run-id ${RUN_ID}"
