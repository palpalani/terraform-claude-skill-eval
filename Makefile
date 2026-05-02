# Makefile — terraform-claude-skill-eval
#
# Defaults:
#   RUN_ID    = current UTC timestamp (YYYYMMDD-HHMM)
#   PROMPTS   = 01,02,03,04
#   RUNS_PER  = 2     # runs per (prompt × variant) cell
#   VARIANTS  = default,skill
#
# Examples:
#   make eval                                    # full run, both variants
#   make eval RUN_ID=20260502-1430 RUNS_PER=3
#   make eval PROMPTS=01,03                      # subset
#   make aggregate RUN_ID=20260502-1430
#   make clean                                   # remove all non-sample runs
#
# Configure your Claude Code CLI invocation via env:
#   CLAUDE_CMD          (default: 'claude --print')
#   CLAUDE_SKILL_FLAG   (default: '/terraform')

SHELL := /usr/bin/env bash

RUN_ID    ?= $(shell date -u +%Y%m%d-%H%M)
PROMPTS   ?= 01,02,03,04
RUNS_PER  ?= 2
VARIANTS  ?= default,skill

.PHONY: help eval aggregate clean prereqs

help:
	@echo "make eval RUN_ID=<id> PROMPTS=<list> RUNS_PER=<n>"
	@echo "make aggregate RUN_ID=<id>"
	@echo "make clean        # removes runs/* except sample-run and .gitkeep"
	@echo "make prereqs      # checks that claude / terraform / tfsec are on PATH"

prereqs:
	@command -v claude    >/dev/null 2>&1 || echo "WARN: 'claude' not on PATH — set CLAUDE_CMD"
	@command -v terraform >/dev/null 2>&1 || (echo "ERROR: terraform not on PATH" && exit 1)
	@command -v node      >/dev/null 2>&1 || (echo "ERROR: node not on PATH (need Node 22+)" && exit 1)
	@command -v tfsec     >/dev/null 2>&1 || echo "INFO: tfsec not on PATH — security scoring will be null"

eval: prereqs
	@bin/run-eval.sh --run-id $(RUN_ID) --prompts $(PROMPTS) --runs-per $(RUNS_PER) --variants $(VARIANTS)
	@$(MAKE) aggregate RUN_ID=$(RUN_ID)

aggregate:
	@node bin/aggregate.mjs --run-id $(RUN_ID)
	@echo ""
	@echo "Summary written:"
	@echo "  runs/$(RUN_ID)/summary.md"
	@echo "  runs/$(RUN_ID)/summary.csv"

clean:
	@find runs -mindepth 1 -maxdepth 1 -type d ! -name 'sample-run' -exec rm -rf {} +
	@echo "cleaned runs/ (kept sample-run, .gitkeep)"
