#!/usr/bin/env node
// aggregate.mjs — Walk runs/<run_id>/**/scorecard.json and emit:
//   - runs/<run_id>/summary.csv  (one row per scorecard)
//   - runs/<run_id>/summary.md   (a comparison table ready to paste into a blog post)
//
// Usage:
//   node bin/aggregate.mjs --run-id 20260502-1430

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
let runId = "";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--run-id") runId = args[i + 1];
}
if (!runId) {
  console.error("usage: aggregate.mjs --run-id <RUN_ID>");
  process.exit(2);
}

const root = path.resolve(path.join(path.dirname(new URL(import.meta.url).pathname), ".."));
const runDir = path.join(root, "runs", runId);
if (!fs.existsSync(runDir)) {
  console.error(`run dir not found: ${runDir}`);
  process.exit(2);
}

function* walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile() && entry.name === "scorecard.json") yield full;
  }
}

const scorecards = [];
for (const f of walk(runDir)) {
  try {
    scorecards.push(JSON.parse(fs.readFileSync(f, "utf8")));
  } catch (e) {
    console.error(`skip ${f}: ${e.message}`);
  }
}

if (scorecards.length === 0) {
  console.error(`no scorecards under ${runDir}`);
  process.exit(1);
}

const dimensions = [
  ["files_produced",          "Files produced (avg)",                 "mean"],
  ["terraform_fmt_clean",     "`terraform fmt` clean",                "pct"],
  ["terraform_validate_clean","`terraform validate` clean",           "pct"],
  ["terraform_plan_clean",    "`terraform plan` clean (no errors)",   "pct"],
  ["tfsec_findings_count",    "tfsec findings (avg)",                 "mean"],
  ["iam_wildcard_count",      "IAM `Action: \"*\"` count (avg)",      "mean"],
  ["hardcoded_arn_count",     "Hardcoded ARNs / account IDs (avg)",   "mean"],
  ["default_tags_present",    "`default_tags` present",               "pct"],
];

function bucketBy(scorecards, key) {
  const map = new Map();
  for (const s of scorecards) {
    const v = s[key];
    if (!map.has(v)) map.set(v, []);
    map.get(v).push(s);
  }
  return map;
}

function meanOf(rows, key) {
  const vals = rows.map(r => r[key]).filter(v => typeof v === "number");
  if (vals.length === 0) return null;
  return vals.reduce((a, b) => a + b, 0) / vals.length;
}

function pctOf(rows, key) {
  const vals = rows.map(r => r[key]).filter(v => typeof v === "boolean");
  if (vals.length === 0) return null;
  const n = vals.filter(Boolean).length;
  return (n / vals.length) * 100;
}

function fmt(value, mode) {
  if (value === null || value === undefined) return "n/a";
  if (mode === "pct") return `${value.toFixed(0)}%`;
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(1);
}

// CSV first
const csvHeader = ["prompt_id","variant","run_index", ...dimensions.map(d => d[0])];
const csvRows = [csvHeader.join(",")];
for (const s of scorecards) {
  csvRows.push(csvHeader.map(k => {
    const v = s[k];
    if (v === null || v === undefined) return "";
    if (typeof v === "boolean") return v ? "true" : "false";
    return String(v);
  }).join(","));
}
fs.writeFileSync(path.join(runDir, "summary.csv"), csvRows.join("\n") + "\n");

// Markdown table — overall comparison
const byVariant = bucketBy(scorecards, "variant");
const variants = ["default", "skill"].filter(v => byVariant.has(v));

const rows = [];
rows.push(`# Eval summary — run \`${runId}\``);
rows.push("");
rows.push(`Scorecards: **${scorecards.length}** | Variants: ${variants.join(", ")} | Prompts: ${[...new Set(scorecards.map(s => s.prompt_id))].sort().join(", ")}`);
rows.push("");
rows.push("## Aggregate comparison (averaged across all prompts and runs)");
rows.push("");
rows.push("| Dimension | Default Claude | With `/terraform` skill | Delta |");
rows.push("| --- | --- | --- | --- |");

for (const [key, label, mode] of dimensions) {
  const cells = variants.map(v => {
    const rows = byVariant.get(v) || [];
    return mode === "pct" ? pctOf(rows, key) : meanOf(rows, key);
  });
  const [defVal, skillVal] = cells;
  let delta = "";
  if (typeof defVal === "number" && typeof skillVal === "number") {
    const diff = skillVal - defVal;
    if (mode === "pct") {
      delta = `${diff >= 0 ? "+" : ""}${diff.toFixed(0)} pp`;
    } else {
      delta = `${diff >= 0 ? "+" : ""}${diff.toFixed(1)}`;
    }
  }
  rows.push(`| ${label} | ${fmt(defVal, mode)} | ${fmt(skillVal, mode)} | ${delta} |`);
}

rows.push("");
rows.push("## Per-prompt breakdown");
rows.push("");

const byPrompt = bucketBy(scorecards, "prompt_id");
for (const promptId of [...byPrompt.keys()].sort()) {
  const promptRows = byPrompt.get(promptId);
  rows.push(`### Prompt \`${promptId}\``);
  rows.push("");
  rows.push("| Dimension | Default Claude | With `/terraform` skill |");
  rows.push("| --- | --- | --- |");
  for (const [key, label, mode] of dimensions) {
    const def = promptRows.filter(r => r.variant === "default");
    const sk  = promptRows.filter(r => r.variant === "skill");
    const defVal = mode === "pct" ? pctOf(def, key) : meanOf(def, key);
    const skVal  = mode === "pct" ? pctOf(sk, key)  : meanOf(sk, key);
    rows.push(`| ${label} | ${fmt(defVal, mode)} | ${fmt(skVal, mode)} |`);
  }
  rows.push("");
}

rows.push("");
rows.push("---");
rows.push("");
rows.push("_Generated by `bin/aggregate.mjs`. Re-run with `make aggregate RUN_ID=" + runId + "`._");

fs.writeFileSync(path.join(runDir, "summary.md"), rows.join("\n") + "\n");

console.log(`wrote ${path.join(runDir, "summary.csv")}`);
console.log(`wrote ${path.join(runDir, "summary.md")}`);
