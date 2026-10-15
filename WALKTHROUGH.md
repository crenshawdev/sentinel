# sentinel walkthrough

How a project goes from nothing to audited, and what to do with the results. There are four parts: set up the machine once, onboard each project once, audit when it matters, then fix in a separate session.

## 1. Set up the machine (once)

**Tools.** Run the installer from your sentinel checkout, or from any onboarded project's `.sentinel/`. It uses sudo for pacman and installs the cargo tools, Miri and the pipx tools for your user:

```sh
<your sentinel checkout>/mechanical/install.sh
```

Run it again whenever you want newer versions of the tools.

**Plugins.** `/snt:audit` calls four plugins besides its own:

```sh
claude plugin marketplace add crenshawdev/sentinel
claude plugin install snt@sentinel

claude plugin install claude-security@claude-plugins-official
claude plugin install security-guidance@claude-plugins-official

claude plugin marketplace add trailofbits/skills
claude plugin install audit-context-building@trailofbits
claude plugin install variant-analysis@trailofbits
```

**Keys.** Put these in `~/.zshenv`:

```sh
export SENTINEL_ANTHROPIC_API_KEY=sk-ant-...   # a key scoped to a workspace in the Anthropic Console
export OPENAI_API_KEY=sk-...
```

Do not export `ANTHROPIC_API_KEY`. Every interactive Claude Code session would see it next to your claude.ai login and ask which one to use. fanout.sh hands the key to its own `claude -p` runs and nowhere else. The key must be scoped to a workspace: an unscoped key fails with a 400 asking for an `anthropic-workspace-id` header. A workspace just for audits also gives you a spend limit and separate usage.

**CLIs.** `claude` and `codex` on PATH.

## 2. Onboard a project (once per repo)

Open Claude Code in the repo and run:

```
/snt:onboard
```

It stops after each step for you to look. If a step is already done, it says so and moves on.

| Step | What it does | What you check |
|------|--------------|----------------|
| 1. Add the kit | `git submodule add https://github.com/crenshawdev/sentinel .sentinel`, and `audit/` plus `CLAUDE-SECURITY-*/` into `.gitignore` | Both ignore lines are there. Those two folders hold unfixed findings. |
| 2. THREAT-MODEL.md | Written from the code: what the tool reads, writes, executes, must never touch, and where untrusted data enters. Unsure claims are marked `[VERIFY]`. | Every `[VERIFY]` mark. This is the most important review in the whole process: every lens and the adjudicator treat this file as the definition of what matters. |
| 3. Security-guidance rules | `.claude/claude-security-guidance.md`: a short threat model plus a codebase-specific checklist, which the security-guidance plugin adds to its reviews | It stays well under 8 KB and holds no secrets. |
| 4. Fuzz targets (Rust) | cargo-fuzz targets for every function that parses outside input (JSONL, config, CLI, MCP payloads), in the crate that owns it, each one built | They all compile and the main build still works. It also reports whether the code has `unsafe`; check.sh runs Miri on its own when it does. |
| 5. deny.toml (Rust) | The baseline copied to the repo root, its license list fitted to the real dependencies, then `cargo deny check` | Read the output. Nothing gets fixed yet. |
| 6. Fast CI workflow | `.github/workflows/fast.yml` (or `.forgejo/workflows/`), and the repo's `ANTHROPIC_API_KEY` Actions secret set from your environment after it asks you | `gh secret list -R <owner>/<repo>` shows the secret. The key lives encrypted in GitHub's settings, never in git. |
| 7. SECURITY.md | How to report, a link to sentinel, and the rule that every confirmed finding becomes a regression test | It asks you for the reporting contact. It never makes one up. |

At the end it lists every file it created or changed. It does not commit; review the list and commit it yourself.

Onboarding never runs the audit lenses.

## 3. Audit (when it matters)

Open Claude Code in the repo and run:

```
/snt:audit
```

The default is 3 Claude runs per lens. `/snt:audit 5` runs 5. It stops after each step.

| Step | What it does | What you look at |
|------|--------------|------------------|
| 1. Mechanical checks | `check.sh`: cargo audit, cargo deny, clippy and semgrep as gates; geiger, vet, fuzz build, Miri, npm audit, pip-audit and bandit as reports | Failures by tool. Nothing gets fixed in this session. |
| 2. Context map | The Trail of Bits `audit-context-building` skill maps the code; its dossier is saved as `audit/CONTEXT.md` | Whether the map matches how you know the code works. Every later reviewer reads it first. |
| 3. Claude Security scan | `/claude-security`, a codebase scan of the whole repo; its report is copied to `audit/claude-security.md` | The report itself. Its findings join the merge in step 4. |
| 4. Lenses and merge | Asks first, because this is the step that bills: 8 lenses × (runs + 1), 32 runs at the default. Then fanout.sh, the Claude Security import and merge.sh. | `audit/<timestamp>/merged.md`: the count per lens, and which findings came back in only one run (`low-agreement`). |
| 5. Adjudication | A subagent runs `adjudicator.md` on the merged list and writes a failing test for every finding it can prove. Then the session reruns each test itself. | The final table: CONFIRMED, UNPROVEN, DROPPED, each with its reason and test path. |
| 6. Variant analysis | For each confirmed finding, the Trail of Bits `variant-analysis` skill looks for the same mistake elsewhere; new hits are adjudicated the same way | New rows in the table. |
| 7. Findings log | One row per step in `audit/findings-log.md`: reported, confirmed, unproven, dropped, and what the noise looked like | Whether a lens keeps producing noise. That's how the lenses get tuned. |

Where everything lands:

| Path | What it holds |
|------|---------------|
| `audit/CONTEXT.md` | The architectural map |
| `audit/claude-security.md` | The Claude Security report |
| `audit/<timestamp>/` | Every lens run, `merged.md`, `adjudication.md`, `variants.md` |
| `audit/findings-log.md` | The running log for this repo |
| `tests/security/` | The failing tests (in a Cargo workspace, under the member crate) |

`audit/` stays out of git. The audit commits nothing and fixes nothing.

## 4. Fix (a separate session)

Suggested process. Start a new session, so the fixes are judged against the tests and not against what the audit session believed:

1. Work through the CONFIRMED rows of `audit/<timestamp>/adjudication.md` one at a time, the most severe first.
2. A fix is done when its test in `tests/security/` passes and the rest of the suite still passes.
3. Commit each fix together with its test. The test stays in the repo as the regression test SECURITY.md promises.
4. For UNPROVEN rows, read the reason and decide: write the missing test yourself, or record why it stays open.
5. DROPPED rows need nothing. Their reasons are in the notes.

On a public repo, keep confirmed findings to yourself until they're fixed: no issue, no commit message and no post that describes an open one.

## 5. Keeping it running

| When | What to do |
|------|------------|
| Every pull request | `fast.yml` runs by itself: the mechanical gates, then Claude Opus 5.5 reviews the diff and posts the result as a comment. The check fails if the review didn't actually run. It only runs on pull requests; pushes straight to `main` skip it. |
| Before a release | `/snt:audit`, then a fix session for whatever it confirms. |
| When the tool gains a new input, output, command or hook | Update `THREAT-MODEL.md` and `.claude/claude-security-guidance.md` first, then audit. The lenses only look for what the threat model says matters. |
| When sentinel changes | Move the project's pin and commit it: `git submodule update --remote .sentinel` |
| When the snt plugin changes | `claude plugin marketplace update sentinel && claude plugin update snt@sentinel`, then restart Claude Code |
| Now and then | Rerun `mechanical/install.sh` to update the tools. |

`full.yml`, the monthly CI audit, is optional and not added during onboarding. It runs the lenses and the merge but cannot adjudicate, and on a public repo anyone who can download the workflow's files can read the findings.
