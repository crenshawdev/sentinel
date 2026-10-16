# sentinel

Ask a model to security-review a repository twice and you get two different lists. Some findings are real, some are not, and the report gives you no way to tell them apart. sentinel turns that into a process you can repeat: mechanical checks first, then many narrow reviews of the same code by more than one model, then a merge that counts how often each finding came back, then an adjudication pass where a finding only counts as confirmed once a failing test demonstrates it.

It is plain files and bash, with small embedded Python scripts that use only the standard library, packaged as a Claude Code plugin so the whole pipeline runs from one command. It is tuned for Rust command-line tools, hooks and MCP servers that work with Claude Code transcripts, and it also covers Node and Python projects.

## Status

sentinel is the audit kit I run on my own tools. It is public so the approach can be read, and it is MIT-licensed, so copy anything useful. It is not packaged or supported for anyone else to depend on: paths, defaults and prompts change whenever my own projects need them to, and I don't take issues or pull requests.

## Using it

Install the plugin once:

```sh
claude plugin marketplace add crenshawdev/sentinel
claude plugin install snt@sentinel
```

Then, in a project:

- `/snt:onboard` sets the repo up, once. It adds the kit as a git submodule at `.sentinel`, writes `THREAT-MODEL.md` from the code, the security-guidance rules, fuzz targets and `deny.toml` for Rust, the fast CI workflow and `SECURITY.md`. It stops after each step for you to look, and it does not run the audit.
- `/snt:audit [runs per lens]` runs the full pipeline below, stopping after each step. It finds, proves and records; it does not fix or commit anything.

Each project runs the sentinel version its `.sentinel` submodule is pinned to. Updating a lens or a script happens once here, and a project picks it up by moving its pin.

## The pipeline

What `/snt:audit` runs, in order:

1. **Mechanical checks.** `.sentinel/mechanical/check.sh .`
2. **Context map.** The Trail of Bits `audit-context-building` skill maps the code; its `audit-context/DOSSIER.md` is copied to `audit/CONTEXT.md`.
3. **Claude Security scan.** `/claude-security`, a codebase scan of the whole repo. Its report is copied to `audit/claude-security.md`.
4. **Lenses and merge.** `.sentinel/fanout.sh . 3`, then `.sentinel/import-claude-security.sh` to add the step 3 findings, then `.sentinel/merge.sh`. Asks before starting, because this is the expensive step: 8 lenses × (runs per lens + 1), on your Claude plan and your OpenAI key.
5. **Adjudication.** `adjudicator.md`, run as a subagent. Every confirmed finding gets a failing test under `tests/security-unfixed/` (in a Cargo workspace, the member crate's), skipped by default so the normal test run stays green, and the session reruns each test to check it really fails. The fix session moves each test to `tests/security/` with its fix.
6. **Variant analysis.** The Trail of Bits `variant-analysis` skill looks for the same pattern elsewhere for each confirmed finding; new hits are adjudicated the same way.
7. **Findings log.** One row per step in `audit/findings-log.md`.

Everything the pipeline writes goes under `audit/`, apart from the context map's `audit-context/` folder and the tests. `/snt:onboard` puts `audit/`, `audit-context/`, `CLAUDE-SECURITY-*/` and `security-unfixed/` in `.gitignore`, because they hold unfixed vulnerability findings, the tests that prove them and the map the reviewers worked from. fanout.sh also leaves all four out of the reviewers' snapshot.

## What is in it

| Path | What it is |
|------|------------|
| `.claude-plugin/`, `skills/` | The `snt` plugin: the `onboard` and `audit` skills, and the marketplace entry that installs them. |
| `threat-model.template.md` | The template for a project's `THREAT-MODEL.md`. Every lens and the adjudicator read it first. |
| `lenses/*.md` | Eight review prompts, one concern each: data exposure, path handling, untrusted input, permissions, resource limits, hook execution, supply chain, crypto and state. |
| `finding-format.md` | The output format every lens must use. fanout.sh appends it to each lens; merge.sh parses it. |
| `fanout.sh` | Runs every lens N times through `claude -p` and once through `codex exec`. |
| `import-claude-security.sh` | Adds a `/claude-security` scan's findings to an audit run as one more run of each lens. |
| `merge.sh` | Merges the runs into `merged.md` for the adjudicator, with which model reported what removed, and `agreement.md` for you. |
| `adjudicator.md` | The prompt for the adjudication pass. |
| `mechanical/check.sh` | Runs cargo audit, cargo deny, clippy, semgrep and the rest, depending on what the repo contains. |
| `mechanical/install.sh` | Installs those tools on Arch Linux. |
| `mechanical/deny.toml` | cargo-deny baseline. A repo's own `deny.toml` takes precedence. |
| `mechanical/semgrep.yml` | The semgrep rulesets check.sh runs, and the rules it skips. |
| `ci/fast.yml`, `ci/full.yml` | Workflows for GitHub Actions and Forgejo Actions. |
| `ci/install-tools.sh` | Installs the mechanical tools on a Debian or Ubuntu CI runner. |
| `ci/security-review.sh`, `ci/security-review.md` | The pull request review `fast.yml` runs, and its prompt. |
| `findings-log.md` | The template for a project's `audit/findings-log.md`. |

## Requirements

- `bash`, `git`, GNU `tar`, `timeout` from coreutils, `python3`.
- `claude` (Claude Code) and `codex` (Codex CLI) on PATH.
- The Claude Code plugins the pipeline calls: `claude-security` and `security-guidance` from `claude-plugins-official`, and `audit-context-building` and `variant-analysis` from `trailofbits`.
- The mechanical tools: `mechanical/install.sh` on Arch, `ci/install-tools.sh` on CI runners.

## check.sh

Gates fail the run when they fail or when the tool is not installed. Everything else is reported and never fails the run.

| Check | Runs when | Kind |
|-------|-----------|------|
| `cargo audit` | `Cargo.toml` exists | gate |
| `cargo deny check` | `Cargo.toml` exists | gate |
| `cargo clippy --all-targets -- -W clippy::pedantic -W clippy::nursery` | `Cargo.toml` exists | gate (fails on errors and deny-level lints; pedantic and nursery only warn) |
| `semgrep scan --error` with the rulesets in `semgrep.yml` | always | gate |
| `cargo geiger`, once per workspace member | `Cargo.toml` exists | report |
| `cargo vet --locked` | `supply-chain/` exists | report |
| `cargo +nightly fuzz build` | a `fuzz/` directory at the root or in any workspace member | report |
| `cargo +nightly miri test --workspace --lib --bins` (unit tests only: Miri cannot run tests that start processes) | the repo's own Rust code has an `unsafe` block, fn, impl, trait or extern | report |
| `npm audit` | `package.json` and `package-lock.json` exist | report |
| `pip-audit -r requirements.txt` and `pip-audit .`, one run for each that applies | `requirements.txt`, and `pyproject.toml` with a `[project]` table | report |
| `bandit -r .` | `pyproject.toml` or `requirements.txt` exists | report |

semgrep runs with `--metrics=off`. `semgrep.yml` also lists rules to skip: the three p/rust rules that flag reading the program's arguments or its own path (`args`, `args-os`, `current-exe`), which fire on every command-line tool.

## fanout.sh

```
fanout.sh <repo-dir> [runs-per-lens=3]
```

Each lens runs N times through Claude and once through Codex, in parallel within a lens and one lens after another. Results go to `<repo>/audit/<timestamp>/<lens>/1.md` … `N.md` and `codex.md`, each with a `.log`, plus `run.txt` recording the commit, models and settings. A run that fails leaves only its `.log`. When `<repo>/audit/CONTEXT.md` exists, it goes at the top of every lens prompt.

Settings, set as environment variables:

| Variable | Default | What it sets |
|----------|---------|--------------|
| `SENTINEL_MODEL` | `opus` | Claude model (`--model`) |
| `SENTINEL_EFFORT` | `high` | Claude effort (`--effort`) |
| `SENTINEL_CODEX_MODEL` | `gpt-6-astra` | Codex model (`-m`); set it to an empty string for Codex's own default |
| `SENTINEL_CODEX_EFFORT` | `xhigh` | Codex `model_reasoning_effort` |
| `SENTINEL_RUN_TIMEOUT` | `3600` | Seconds before a single run is killed |

Billing: Claude runs in `--safe-mode` on your logged-in claude.ai plan. To bill an API key instead, set `SENTINEL_ANTHROPIC_API_KEY`, or `ANTHROPIC_API_KEY`, which is what CI sets on its fanout step. Don't export `ANTHROPIC_API_KEY` on a workstation: every interactive Claude Code session would see it alongside your claude.ai login. A key must be scoped to a workspace in the Anthropic Console; an unscoped key fails with a 400 asking for an `anthropic-workspace-id` header. Codex uses `CODEX_API_KEY`, or `OPENAI_API_KEY` passed to it as `CODEX_API_KEY`, and falls back to your Codex login when neither is set.

What the reviewers can and cannot do:

- They read a snapshot of the repo's tracked and untracked-but-not-ignored files in a private temp directory, so no run sees another run's output and nothing they do touches your working tree. `audit/`, `CLAUDE-SECURITY-*/` and the sentinel directory are left out of the snapshot.
- Claude gets only the Read, Grep and Glob tools, with nothing pre-approved, so any read or search outside the snapshot (your home directory, `/proc`) is refused. (`--bare` would drop Grep and Glob on Linux, which is why the runs use `--safe-mode`.) The repo's `.claude/settings.json`, hooks and MCP servers are not loaded, and neither are your own hooks, plugins, MCP servers or CLAUDE.md. Sessions are not saved.
- Each CLI gets only its own API key.
- Codex runs under a permission profile that makes only the snapshot, the system folders its commands need and its own install folder readable, with no writes and no network. The commands it runs get only basic variables such as `PATH` and `HOME`, never `CODEX_API_KEY`. Codex's own `--sandbox read-only` is not used: it lets commands read the whole disk, home directory included, and silently overrides the profile. Without an API key, Codex loads your global `AGENTS.md`.

## import-claude-security.sh

```
import-claude-security.sh <CLAUDE-SECURITY-dir> [audit-run-dir]
```

Reads the scan's `CLAUDE-SECURITY-RESULTS.jsonl` and writes `<run>/<lens>/claude-security.md` for every lens, in the finding format, so merge.sh treats the scan as one more run of each lens. Each finding goes to a lens by its CWE ids; a finding whose CWEs match no lens goes to an `other` lens. With no run directory, it uses the newest run under `./audit/`. Run it before merge.sh.

## merge.sh

```
merge.sh [audit-run-dir]
```

Reports of the same lens that cite the same file go under one finding only when their line ranges all overlap and none covers more than 30 lines, so one wide range can't swallow the findings inside it. Each report keeps its own title, severity, trigger and consequence, and which run wrote it is removed. It writes two files. `merged.md` is for the adjudicator and holds no agreement counts. `agreement.md` is for you: how many runs reported each finding, those reported by a single run tagged `low-agreement`, and the counts per lens. A trailing `:column` on a location is dropped, and an absolute path into the reviewers' snapshot is made relative using the path fanout.sh records in `run.txt`. Run outputs that do not follow the finding format are named on stderr and counted in `agreement.md`; they are never dropped silently. Findings are not merged across lenses, because two lenses citing the same lines are usually describing different problems. With no run directory, it uses the newest run under `./audit/`.

## CI

The workflows expect sentinel as a submodule at `.sentinel`, which `/snt:onboard` sets up. Copy them into `.github/workflows/` or `.forgejo/workflows/`, and add the secrets `ANTHROPIC_API_KEY` (and `OPENAI_API_KEY` for `full.yml`). GitHub keeps Actions secrets per repository, encrypted in its settings and never in git, so each repo needs its own; `/snt:onboard` asks you to set it in your own terminal, where `gh` prompts for the key so it never passes through Claude:

```sh
gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

If the project needs system libraries to build, add them to the install step.

`fast.yml` runs on every pull request. The `mechanical` job runs check.sh with the gating tools on GitHub and Forgejo. The `security-review` job then runs `ci/security-review.sh`, on GitHub only, because it posts its result as a pull request comment through the GitHub API. It installs a pinned Claude Code (2.1.300) on Node 22, has Claude Opus 5.5 review the pull request's diff against `THREAT-MODEL.md` with read-only tools and none of the pull request's own `.claude` settings loaded, and writes the review in the finding format. The checkout keeps no GitHub token in `.git/config`, the reviewer is refused any read outside the checkout and inside `.git`, and output that contains the API key is deleted and fails the job instead of being posted. The job fails when the review did not run or its output holds neither findings nor a "No findings" marker, so a passing check means a review happened. Findings do not fail the job; they are posted for the author to read.

The diff is untrusted input, and text in it can try to steer the review. The prompt tells Claude to treat it as data, which narrows that but cannot rule it out, so the review is for trusted pull requests; require approval for workflows from outside contributors. `SENTINEL_REVIEW_MODEL` and `SENTINEL_REVIEW_EFFORT` override the model and effort.

`full.yml` runs on demand and at 06:00 UTC on the 1st of each month: check.sh with every tool, fanout.sh with 3 runs per lens, merge.sh, and `audit/` uploaded as the `sentinel-audit` artifact, kept 14 days. It does not run the context map, the Claude Security scan or adjudication; those need a session. The API keys are set only on the fanout step, never while check.sh builds the project. Anyone who can download the repo's workflow artifacts can read the findings, so on a public repo run it somewhere private.

On Forgejo, the `ubuntu-latest` label must be mapped to an image on the runner, and Codex's sandbox may not start inside an unprivileged container; when it fails, fanout.sh reports the Codex runs as failed and the Claude runs still count.

## What stays manual

- Checking every `[VERIFY]` mark `/snt:onboard` leaves in `THREAT-MODEL.md`, and keeping the threat model current.
- Fixing confirmed findings. That is a separate session; `/snt:audit` only finds, proves and records.
- Committing. Neither skill commits anything.
