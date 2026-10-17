# Full sentinel audit

Run the security audit on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

This session only finds and records. Do not fix code, do not write tests, and do not commit anything. What happens to the findings afterwards is the user's decision.

## Before you start

Check these and stop with a clear message if any is missing:

- `.sentinel/` exists. If not, the repo has not been onboarded: tell the user to run `/snt:onboard` first.
- `audit/` and `CLAUDE-SECURITY-*/` are in `.gitignore`. Add any that are missing, and say so.
- The `claude-security` plugin is installed.

## 1. Mechanical checks

Create `audit/` if it does not exist. Run `.sentinel/mechanical/check.sh .` with its output saved to `audit/check.txt`, and summarize the failures by tool. Do not fix anything.

## 2. Claude Security codebase scan

Run the `claude-security` skill (`/claude-security`) and choose a codebase scan of the whole repository. When it finishes, find the newest `CLAUDE-SECURITY-<timestamp>/` directory, copy its `CLAUDE-SECURITY-RESULTS.md` to `audit/claude-security.md`, and show the user the findings by severity.

Do not run or offer its suggest-patches job. Patches are fixes, and this audit fixes nothing.

## 3. Findings log

Write one row per step into `audit/findings-log.md`: the date, the repo, the step, and what it found (for check.sh, the tools that failed; for Claude Security, the count of findings by severity). Leave the notes column empty for the user. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

## Finish

Tell the user where everything is: `audit/check.txt`, `audit/claude-security.md`, the `CLAUDE-SECURITY-<timestamp>/` directory and `audit/findings-log.md`. Remind them that nothing was fixed or committed.
