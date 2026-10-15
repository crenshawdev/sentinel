---
name: onboard
description: Onboard the current repository to the sentinel security-audit kit, once per repo - adds the kit as the .sentinel submodule, writes THREAT-MODEL.md from the code, the security-guidance rules, fuzz targets, deny.toml, the fast CI workflow and SECURITY.md, stopping after each step. Run only on an explicit /snt:onboard.
disable-model-invocation: true
---

# Onboard this repo to sentinel

This repository is being onboarded to the sentinel security-audit kit (https://github.com/crenshawdev/sentinel). Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue. If a step is already done (the file exists and is filled in), say so and move on to the next one.

Do not run the LLM audit lenses in this session. Do not commit anything; list every file you created or changed at the end so the user can review and commit.

## 1. Add the kit

- Add sentinel as a git submodule at `.sentinel`:
  `git submodule add https://github.com/crenshawdev/sentinel .sentinel`
- Add `audit/` and `CLAUDE-SECURITY-*/` to `.gitignore`. Both hold unfixed vulnerability findings and must never be committed.
- Read `.sentinel/README.md`.

## 2. Write THREAT-MODEL.md

Write `THREAT-MODEL.md` at the repo root from `.sentinel/threat-model.template.md`. Fill it from the actual code, not from assumptions: trace what this tool reads, writes, executes, and where untrusted data enters. Transcripts from `~/.claude/projects` are untrusted because they contain tool output and web content. Mark every claim you are unsure of with `[VERIFY]`.

## 3. Write the security-guidance rules

Copy THREAT-MODEL.md's key points into `.claude/claude-security-guidance.md`, the file the security-guidance plugin reads. That plugin appends the file to every security review prompt as additive project rules, so:

- Write plain markdown: a short plain-language threat model, then a review checklist of rules specific to this codebase (what it must never touch, where untrusted data enters, which calls need which guard). Leave out generic advice the model already knows.
- Keep it well under 8 KB. The plugin's budget is 8 KB for this file and the user's own `~/.claude/claude-security-guidance.md` together, and it truncates past that.
- No secrets: the contents are sent with every review.

## 4. Fuzz targets and unsafe code (Rust only)

Skip this step if the repo has no `Cargo.toml`.

- Add cargo-fuzz targets for every function that parses external input: JSONL, config, CLI arguments, MCP payloads. Put each `fuzz/` directory in the crate that owns the function: the repo root for a single package, the member crate's directory in a workspace (a virtual workspace root cannot hold one).
- Each target must compile: run `cargo +nightly fuzz build` in each crate that has a `fuzz/` directory, and show the result. Check that the main workspace still builds afterwards.
- Report whether the repo's own code has any `unsafe`. You do not need to add anything for it: check.sh runs Miri on the unit tests (`cargo +nightly miri test --workspace --lib --bins`) by itself when the repo has unsafe code.

## 5. deny.toml (Rust only)

Skip this step if the repo has no `Cargo.toml`.

Copy `.sentinel/mechanical/deny.toml` to the repo root and adjust the license allow-list to what this repo actually depends on (`cargo deny list` shows the licenses in use). Then run `cargo deny check` and show the output. Do not fix anything yet.

## 6. Fast CI workflow

Copy `.sentinel/ci/fast.yml` into `.github/workflows/fast.yml`, or into `.forgejo/workflows/fast.yml` if the repo lives on a Forgejo instance (check `git remote -v`). The file works on both. Do not add `full.yml` yet.

The workflow's security-review job runs on GitHub only and needs the repo's `ANTHROPIC_API_KEY` Actions secret. If the repo has a GitHub remote, check with `gh secret list -R <owner>/<repo>`. If the secret is missing, ask the user before setting it, then set it from their environment so the key is never shown, typed, or written to a file:

```
printenv SENTINEL_ANTHROPIC_API_KEY | gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

If `SENTINEL_ANTHROPIC_API_KEY` is not set in the environment, do not ask the user to paste the key into the conversation; tell them to run that command themselves once it is. Never print the key.

## 7. SECURITY.md

Add a `SECURITY.md` with:

- How to report a vulnerability. Ask the user for the contact or channel; never make one up.
- What the security pipeline is, with a link to https://github.com/crenshawdev/sentinel.
- That every confirmed finding becomes a regression test.

## Finish

List every file created or changed, and anything marked `[VERIFY]` that the user still needs to check.
