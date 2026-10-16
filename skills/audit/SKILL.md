---
name: audit
description: Run the full sentinel security pipeline on the current repository - mechanical checks, the audit-context map, a /claude-security codebase scan, the eight sentinel lenses through Claude and Codex, merge, adjudication with failing tests, variant analysis and the findings log - stopping after each step. Finds, proves and records only; fixing is a separate session. Run only on an explicit /snt:audit.
argument-hint: "[runs per lens, default 3]"
disable-model-invocation: true
---

# Full sentinel audit

Run the full security pipeline on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

Fixing is a separate session. In this one, only find, prove and record. Do not fix code, and do not commit anything.

Runs per lens: use `$ARGUMENTS` if it is a positive number, otherwise 3.

## Before you start

Check these and stop with a clear message if any is missing:

- `.sentinel/` exists. If not, the repo has not been onboarded: tell the user to run `/snt:onboard` first.
- `THREAT-MODEL.md` exists at the repo root.
- `audit/`, `audit-context/`, `CLAUDE-SECURITY-*/` and `security-unfixed/` are in `.gitignore`. Add any that are missing, and say so.
- The plugins this pipeline calls are installed: `claude-security`, `audit-context-building` and `variant-analysis`.

Every step reads THREAT-MODEL.md as the definition of what matters.

## 1. Mechanical checks

Run `.sentinel/mechanical/check.sh .` and summarize the failures by tool. Do not fix anything.

## 2. Context map

Run the `audit-context-building` skill on the whole repo. It writes `audit-context/DOSSIER.md`; copy that file to `audit/CONTEXT.md`. This is the architectural map every later reviewer reads first: fanout.sh puts `audit/CONTEXT.md` at the top of every lens prompt, and the adjudicator reads it after THREAT-MODEL.md.

## 3. Claude Security codebase scan

Run the `claude-security` skill (`/claude-security`) and choose a codebase scan of the whole repository. When it finishes, find the newest `CLAUDE-SECURITY-<timestamp>/` directory and copy its `CLAUDE-SECURITY-RESULTS.md` to `audit/claude-security.md` so the user can read it. Keep the directory's name: step 4 imports its findings.

## 4. Lenses, then merge

Before starting, tell the user how many paid model runs this is (8 lenses × (runs per lens + 1); 32 at the default of 3) and wait for their go.

1. Run `.sentinel/fanout.sh . <runs per lens>`. It takes a long time, so run it in the background and wait for it to finish. Note the audit run directory it prints, `audit/<timestamp>`.
2. Run `.sentinel/import-claude-security.sh <the CLAUDE-SECURITY directory from step 3> audit/<timestamp>`. It adds the Claude Security findings to the run as one more run of each lens, in the same shape as the lens runs, so the merge dedupes them, counts them in the agreement, and strips where they came from like every other run. Findings whose CWE matches no lens go to an `other` lens.
3. Run `.sentinel/merge.sh audit/<timestamp>`.

Show the user `audit/<timestamp>/agreement.md`: the counts table per lens and which findings only one run reported. agreement.md is for the user only; never give it to the adjudicator. If fanout.sh reported failed runs or merge.sh named outputs it could not parse, say which.

## 5. Adjudicate

Run the adjudicator as a subagent with the Agent tool, so every command it runs goes through this session's permission checks. Give it only this: read `.sentinel/adjudicator.md` and follow it exactly, against `audit/<timestamp>/merged.md`; write each demonstration where adjudicator.md says (in a Cargo workspace, under the member crate's `tests/security-unfixed/`); write the table and notes to `audit/<timestamp>/adjudication.md`; do not commit. Do not tell it anything about where the findings came from.

When it returns, check its work yourself: run every CONFIRMED test, and confirm it fails for the reason the finding gives. A test that passes, or fails for an unrelated reason, does not confirm anything: mark that finding UNPROVEN in the table and say why. Then show the user the final table.

## 6. Variant analysis

For each CONFIRMED finding, run the `variant-analysis` skill to find the same pattern elsewhere in this repo. Write every new hit in the shape `.sentinel/finding-format.md` describes, into `audit/<timestamp>/variants.md`, with ids continuing after the last id in merged.md. Adjudicate the new hits the same way as step 5 (a subagent, then your own check of each CONFIRMED test), and add them to the table as new rows. Show the user the updated table.

## 7. Findings log

Write one row per step into `audit/findings-log.md`: date, repo, lens or step, how many findings were reported, confirmed, unproven and dropped, and one line on what the noise looked like. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

## Finish

Tell the user where everything is: `audit/<timestamp>/merged.md`, `audit/<timestamp>/adjudication.md`, the test files, and `audit/findings-log.md`. Remind them that fixing is a separate session and nothing was committed.
