#!/usr/bin/env node
// extract-tf.mjs — Pull Terraform code blocks out of a Claude markdown response
// and write them to disk as .tf files. We try, in order:
//
//   1. Fenced blocks tagged ```hcl, ```terraform, or ```tf — written as one
//      consolidated <out_dir>/main.tf if no per-block filename hint is found.
//   2. Filename hints recognised:
//        - "# filename: path/to/file.tf"  (HCL comment, first line of block)
//        - "// filename: path/to/file.tf"
//        - markdown heading immediately above the block: "### path/to/file.tf"
//        - bold label immediately above the block: "**path/to/file.tf**"
//   3. Multiple blocks targeting the same filename are concatenated in order.
//
// This is a best-effort parser. If the agent produced ASCII tree art with no
// real code, we'll write zero files and the scorecard will reflect that.

import fs from "node:fs";
import path from "node:path";

const [, , inputPath, outputDir] = process.argv;
if (!inputPath || !outputDir) {
  console.error("usage: extract-tf.mjs <input.md> <output-dir>");
  process.exit(2);
}

const md = fs.readFileSync(inputPath, "utf8");
fs.mkdirSync(outputDir, { recursive: true });

const lines = md.split("\n");
const blocks = []; // { label, code }

let inBlock = false;
let currentLang = "";
let currentLabel = "";
let currentCode = [];
let lastNonEmptyBefore = "";

const fenceRe = /^```(\w+)?/;
const headingHintRe = /^#{1,6}\s+([\w./_-]+\.tf)\b/i;
const boldHintRe = /^\*\*([\w./_-]+\.tf)\*\*\s*$/i;
const fileCommentRe = /^\s*(?:#|\/\/)\s*filename:\s*([\w./_-]+\.tf)\b/i;

const isHcl = (lang) =>
  ["hcl", "terraform", "tf"].includes((lang || "").toLowerCase());

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const fence = line.match(fenceRe);

  if (!inBlock && fence) {
    currentLang = fence[1] || "";
    if (isHcl(currentLang)) {
      inBlock = true;
      currentCode = [];
      currentLabel = "";
      // look back for a hint
      for (let j = i - 1; j >= Math.max(0, i - 3); j--) {
        const prev = lines[j].trim();
        if (!prev) continue;
        const h = prev.match(headingHintRe);
        const b = prev.match(boldHintRe);
        if (h) { currentLabel = h[1]; break; }
        if (b) { currentLabel = b[1]; break; }
        break;
      }
    }
    continue;
  }

  if (inBlock && fence) {
    blocks.push({ label: currentLabel, code: currentCode.join("\n") });
    inBlock = false;
    currentLang = "";
    currentLabel = "";
    currentCode = [];
    continue;
  }

  if (inBlock) {
    if (!currentLabel && currentCode.length === 0) {
      const fc = line.match(fileCommentRe);
      if (fc) currentLabel = fc[1];
    }
    currentCode.push(line);
  } else if (line.trim()) {
    lastNonEmptyBefore = line;
  }
}

if (blocks.length === 0) {
  console.error(`extract-tf: no HCL blocks found in ${inputPath}`);
  process.exit(0);
}

// Group by label. Anonymous blocks coalesce into main.tf.
const grouped = new Map();
for (const { label, code } of blocks) {
  const key = label && label.trim() ? label.trim() : "main.tf";
  const safe = key.replace(/^\/+/, "").replace(/\.\./g, "");
  const existing = grouped.get(safe) || [];
  existing.push(code);
  grouped.set(safe, existing);
}

for (const [rel, chunks] of grouped) {
  const dest = path.join(outputDir, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, chunks.join("\n\n") + "\n", "utf8");
}

console.error(`extract-tf: wrote ${grouped.size} file(s) under ${outputDir}`);
