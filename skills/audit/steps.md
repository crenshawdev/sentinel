# Full sentinel audit

Run the full security pipeline on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

Fixing is a separate session. In this one, only find, prove and record. Do not fix code, and do not commit anything.

Runs per lens: the number `/snt:audit` was given, otherwise 3.

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

## 5. Adjudicate, in batches

One adjudicator cannot write and run tests for a long list without running out of room, so the findings are judged in batches.

1. Split the finding ids in `audit/<timestamp>/merged.md` into batches of 10, in the order merged.md lists them: F001 to F010 is batch 01, F011 to F020 is batch 02, and so on. Tell the user how many batches there are.
2. Judge one batch at a time, never two at once, because batches share test files such as `tests/security-unfixed/main.rs` and one build directory. For each batch, run a fresh adjudicator subagent with the Agent tool, so every command it runs goes through this session's permission checks. Give it only this: read `.sentinel/adjudicator.md` and follow it exactly, against `audit/<timestamp>/merged.md`, judging only the ids in this batch (name them); write each demonstration where adjudicator.md says (in a Cargo workspace, under the member crate's `tests/security-unfixed/`); write the table and notes to `audit/<timestamp>/adjudication/batch-<NN>.md`; do not commit. Do not tell it anything about where the findings came from, and never give it `agreement.md`.
3. When a batch returns, check its work yourself before starting the next: run every CONFIRMED test with the command in its notes, and confirm it fails for the reason the finding gives. A test that passes, or fails for an unrelated reason, does not confirm anything: mark that finding UNPROVEN in the batch's table and say why.
4. When every batch is done, join the batches' tables and notes into `audit/<timestamp>/adjudication.md`, with every id in merged.md present once, or its report ids where the reports were judged separately. Show the user the table.

## 6. Refute

A fresh reviewer tries to prove each CONFIRMED and DROPPED ruling wrong. A wrong DROPPED is a real vulnerability let go, the most expensive mistake an audit can make.

1. For each batch, write its CONFIRMED and DROPPED rows, with their notes, to `audit/<timestamp>/refute/rulings-<NN>.md`. Leave out the UNPROVEN rows.
2. One batch at a time, run a fresh subagent. Give it only this: read `.sentinel/refuter.md` and follow it exactly, against `audit/<timestamp>/refute/rulings-<NN>.md`; write its table to `audit/<timestamp>/refute/refute-<NN>.md`. Do not give it merged.md, agreement.md or adjudication.md.
3. Show the user every row whose `holds` is `no`, with its reason, and ask how to rule on each one. Record their ruling in adjudication.md's notes, and change the row's status when they say so. A CONFIRMED that moves to UNPROVEN or DROPPED keeps its test file; tell the user its path.

## 7. Variant analysis

For each CONFIRMED finding, run the `variant-analysis` skill to find the same pattern elsewhere in this repo. Write every new hit in the shape `.sentinel/finding-format.md` describes, into `audit/<timestamp>/variants.md`, with ids continuing after the last id in merged.md. Adjudicate and refute the new hits the same way as steps 5 and 6, and add them to the table as new rows. Show the user the updated table.

## 8. Findings log

Write one row per step into `audit/findings-log.md`: date, repo, lens or step, how many findings were reported, confirmed, unproven and dropped, and one line on what the noise looked like. For the refute step, record how many rulings did not hold and how the user ruled on them. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

## Finish

Tell the user where everything is: `audit/<timestamp>/merged.md`, `audit/<timestamp>/adjudication.md`, `audit/<timestamp>/refute/`, the test files, and `audit/findings-log.md`. Remind them that fixing is a separate session and nothing was committed.
