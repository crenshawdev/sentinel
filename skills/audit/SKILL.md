---
name: audit
description: Run the full sentinel security pipeline on the current repository - mechanical checks, the audit-context map, a /claude-security codebase scan, the eight sentinel lenses through Claude and Codex, merge, adjudication with failing tests in batches, a refute pass, variant analysis and the findings log - stopping after each step. Finds, proves and records only; fixing is a separate session. Run only on an explicit /snt:audit.
argument-hint: "[runs per lens, default 3]"
disable-model-invocation: true
---

# Full sentinel audit

The steps live in the sentinel kit this repository is pinned to, so they always match the scripts they call.

Runs per lens for this audit: `$ARGUMENTS` if it is a positive number, otherwise 3.

1. If `.sentinel/` does not exist, the repo has not been onboarded: tell the user to run `/snt:onboard` first, and stop.
2. Read `.sentinel/skills/audit/steps.md` in full and follow it exactly.
3. If that file does not exist, the pin is older than this plugin, and at that pin `.sentinel/skills/audit/SKILL.md` holds the full steps: read it in full and follow it exactly instead.
