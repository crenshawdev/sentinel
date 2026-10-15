# sentinel

Ask a model to security-review a repository twice and you get two different lists. Some findings are real, some are not, and the report gives you no way to tell them apart. sentinel turns that into a process you can repeat: mechanical checks first, then many narrow reviews of the same code by more than one model, then a merge that counts how often each finding came back, then an adjudication pass where a finding only counts as confirmed once a failing test demonstrates it.

It is plain files and bash, with one embedded Python script that uses only the standard library. It is tuned for Rust command-line tools, hooks and MCP servers that work with Claude Code transcripts, and it also covers Node and Python projects.

## What is in it

| Path | What it is |
|------|------------|
| `threat-model.template.md` | The template a project fills in as `THREAT-MODEL.md`. Every lens and the adjudicator read it first. |
| `lenses/*.md` | Eight review prompts, one concern each: data exposure, path handling, untrusted input, permissions, resource limits, hook execution, supply chain, crypto and state. |
| `finding-format.md` | The output format every lens must use. fanout.sh appends it to each lens; merge.sh parses it. |
| `fanout.sh` | Runs every lens N times through `claude -p` and once through `codex exec`. |
| `merge.sh` | Merges the runs into `merged.md`, with which model reported what removed. |
| `adjudicator.md` | The prompt for the adjudication pass. |
| `mechanical/check.sh` | Runs cargo audit, cargo deny, clippy, semgrep and the rest, depending on what the repo contains. |
| `mechanical/install.sh` | Installs those tools on Arch Linux. |
| `mechanical/deny.toml` | cargo-deny baseline. A repo's own `deny.toml` takes precedence. |
| `mechanical/semgrep.yml` | The semgrep rulesets check.sh runs. |
| `ci/fast.yml`, `ci/full.yml` | Workflows for GitHub Actions and Forgejo Actions. |
| `ci/install-tools.sh` | Installs the mechanical tools on a Debian or Ubuntu CI runner. |
| `attack/` | The black-box attack step. Placeholders for now. |
| `findings-log.md` | A table for recording what each audit found and how much of it was noise. |

## Adopting it in a project

As a git submodule:

```sh
git submodule add <sentinel-repo-url> sentinel
cp sentinel/threat-model.template.md THREAT-MODEL.md
echo 'audit/' >> .gitignore
```

Or keep one checkout and point at it:

```sh
export SENTINEL_DIR=~/path/to/sentinel
cp "$SENTINEL_DIR/threat-model.template.md" THREAT-MODEL.md
echo 'audit/' >> .gitignore
```

The scripts find their own files from where they live, so `SENTINEL_DIR` is only a convenience for your shell. The CI workflows expect the submodule at `sentinel`; with a separate checkout, add a step that checks sentinel out and set `SENTINEL_DIR` in the workflow's `env`.

Keep `audit/` out of git. It holds unfixed vulnerability reports.

For CI, copy `ci/fast.yml` and `ci/full.yml` into `.github/workflows/` or `.forgejo/workflows/` and add the secrets `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`. If the project needs system libraries to build, add them to the install step.

## Requirements

- `bash`, `git`, GNU `tar`, `timeout` from coreutils, `python3`.
- `claude` (Claude Code) and `codex` (Codex CLI) on PATH for fanout.sh.
- The mechanical tools: `mechanical/install.sh` on Arch, `ci/install-tools.sh` on CI runners.

## Run order

1. Mechanical checks.
   ```sh
   $SENTINEL_DIR/mechanical/check.sh .
   ```
2. Context build. Fill in `THREAT-MODEL.md`. fanout.sh refuses to run without it.
3. Claude security full scan.
   <!-- TODO(john): how this step is run. -->
4. Fan out the lenses.
   ```sh
   $SENTINEL_DIR/fanout.sh . 3
   ```
5. Merge.
   ```sh
   $SENTINEL_DIR/merge.sh audit/<timestamp>
   ```
6. Adjudicate. Start Claude Code in the repo and give it the prompt and the merged list:
   ```
   Read <SENTINEL_DIR>/adjudicator.md and follow it. The findings are in audit/<timestamp>/merged.md.
   ```
   The adjudicator writes its demonstrations under `tests/security/` and does not commit them.
7. Variant search. For each CONFIRMED finding, search the rest of the code, and your other repos, for the same mistake.

Then add a row per step to `findings-log.md`.

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
| `cargo +nightly fuzz build` | `fuzz/` exists | report |
| `npm audit` | `package.json` and `package-lock.json` exist | report |
| `pip-audit` | `pyproject.toml` with a `[project]` table, or `requirements.txt` | report |
| `bandit -r .` | `pyproject.toml` or `requirements.txt` exists | report |

semgrep runs with `--metrics=off`.

## fanout.sh

```
fanout.sh <repo-dir> [runs-per-lens=3]
```

Each lens runs N times through Claude and once through Codex, in parallel within a lens and one lens after another. Results go to `<repo>/audit/<timestamp>/<lens>/1.md` … `N.md` and `codex.md`, each with a `.log`, plus `run.txt` recording the commit, models and settings. A run that fails leaves only its `.log`.

Settings, set as environment variables:

| Variable | Default | What it sets |
|----------|---------|--------------|
| `SENTINEL_MODEL` | `opus` | Claude model (`--model`) |
| `SENTINEL_EFFORT` | `high` | Claude effort (`--effort`) |
| `SENTINEL_CODEX_MODEL` | Codex's default | Codex model (`-m`) |
| `SENTINEL_CODEX_EFFORT` | `high` | Codex `model_reasoning_effort` |
| `SENTINEL_CODEX_SANDBOX` | `read-only` | Codex `--sandbox` |
| `SENTINEL_RUN_TIMEOUT` | `3600` | Seconds before a single run is killed |

Billing: with an API key set, Claude runs in `--bare` mode and bills the key. Without one, Claude runs in `--safe-mode` on your logged-in plan. fanout.sh reads `SENTINEL_ANTHROPIC_API_KEY` first and `ANTHROPIC_API_KEY` second. On a workstation, put the key in your shell profile as `SENTINEL_ANTHROPIC_API_KEY`: exported as `ANTHROPIC_API_KEY`, every interactive Claude Code session would see it alongside your claude.ai login. CI sets `ANTHROPIC_API_KEY` on the fanout step only, which is fine. The key must be scoped to a workspace in the Anthropic Console; an unscoped key fails with a 400 asking for an `anthropic-workspace-id` header. Codex uses `CODEX_API_KEY`, or `OPENAI_API_KEY` passed to it as `CODEX_API_KEY`, and falls back to your Codex login when neither is set.

What the reviewers can and cannot do:

- They read a snapshot of the repo's tracked and untracked-but-not-ignored files in a private temp directory, so no run sees another run's output and nothing they do touches your working tree. `audit/` and the sentinel directory are left out of the snapshot.
- Claude gets only the Read, Grep and Glob tools. The repo's `.claude/settings.json`, hooks and MCP servers are not loaded, and neither are your own hooks, plugins, MCP servers or CLAUDE.md. Sessions are not saved.
- Each CLI gets only its own API key.
- Codex's read-only sandbox blocks writes. Without an API key, Codex loads your global `AGENTS.md`.

## merge.sh

```
merge.sh <repo>/audit/<timestamp>
```

Findings of the same lens that cite the same file with overlapping line ranges become one finding. It counts how many runs reported each one and tags those reported by a single run `low-agreement`. It keeps every distinct title, trigger and consequence the runs gave and removes which run wrote them. Run outputs that do not follow the finding format are named on stderr and counted in `merged.md`; they are never dropped silently. Findings are not merged across lenses, because two lenses citing the same lines are usually describing different problems.

## CI

`fast.yml` runs on every pull request. The `mechanical` job runs check.sh with the gating tools on GitHub and Forgejo. The `security-review` job then runs `anthropics/claude-code-security-review`, pinned to a commit, on the diff, on GitHub only, because that action reads the pull request and posts comments through api.github.com. That action's own documentation says it is not hardened against prompt injection and should only review trusted pull requests; require approval for workflows from outside contributors.

`full.yml` runs on demand and at 06:00 UTC on the 1st of each month: check.sh with every tool, fanout.sh with 3 runs per lens, merge.sh, and `audit/` uploaded as the `sentinel-audit` artifact, kept 14 days. The API keys are set only on the fanout step, never while check.sh builds the project. Anyone who can download the repo's workflow artifacts can read the findings, so on a public repo run it somewhere private.

On Forgejo, the `ubuntu-latest` label must be mapped to an image on the runner, and Codex's sandbox may not start inside an unprivileged container; when it fails, fanout.sh reports the Codex runs as failed and the Claude runs still count.

## What stays manual

- The Claude security full scan (step 3).
- Adjudication. CI stops at `merged.md`.
- Variant search.
- Filling in `THREAT-MODEL.md` and keeping it current.
- Reading the reported-only output of check.sh.
- Recording results in `findings-log.md`.
- The black-box attack step in `attack/`, which is not written yet.
