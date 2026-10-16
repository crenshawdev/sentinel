#!/usr/bin/env bash
# Review a pull request's diff for security problems with Claude Code, and fail
# unless a review really happened. fast.yml runs it; it also runs locally.
#
# Usage: security-review.sh <base-ref>      e.g. security-review.sh origin/main
#
# Needs ANTHROPIC_API_KEY. Writes the review to security-review.md in the
# current directory, in the shape finding-format.md describes, and appends it
# to the job summary when run in GitHub Actions. Exits non-zero when Claude
# fails or its output holds neither findings nor a "No findings" marker, so a
# passing check always means a review happened. Findings themselves do not
# fail the job; they are posted for the author to read.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $(basename "$0") <base-ref>" >&2; exit 2; }
base=$1
kit=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
model="${SENTINEL_REVIEW_MODEL:-claude-opus-5-5}"
effort="${SENTINEL_REVIEW_EFFORT:-high}"
out=security-review.md

[[ -n ${ANTHROPIC_API_KEY:-} ]] || { echo "::error::ANTHROPIC_API_KEY is not set, so no review can run"; exit 1; }

git diff --merge-base "$base" HEAD > .pr.diff
if [[ ! -s .pr.diff ]]; then
    echo "No changes against $base, so there was nothing to review." > "$out"
    exit 0
fi

prompt=$(mktemp)
trap 'rm -f "$prompt"' EXIT
{ cat "$kit/ci/security-review.md"; echo; cat "$kit/finding-format.md"; } > "$prompt"

# --safe-mode and --setting-sources "" keep the pull request's own .claude
# settings, hooks and MCP servers from loading, and any settings file on the
# runner from pre-approving a read. The tools are Read, Grep and
# Glob (--bare would drop Grep and Glob) and nothing is pre-approved, so under
# dontAsk a read or search outside the working directory (/proc/self/environ,
# the home directory) is refused; .git is refused by name.
rc=0
claude -p --safe-mode --model "$model" --effort "$effort" \
    --setting-sources "" --tools "Read,Grep,Glob" --disallowedTools "Read(./.git/**)" \
    --permission-mode dontAsk --no-session-persistence --output-format text \
    < "$prompt" > "$out" || rc=$?

# The review is posted publicly. If text in the diff got the reviewer to quote
# the API key, fail without showing or posting the output.
if grep -qF -- "$ANTHROPIC_API_KEY" "$out"; then
    rm -f "$out"
    echo "::error::the security review output contained the API key; it was deleted and will not be posted. Rotate the key."
    exit 1
fi

if [[ $rc -ne 0 ]]; then
    echo "::error::the security review did not run: claude exited $rc"
    cat "$out"
    exit 1
fi
if ! grep -qE '^## (Finding:|No findings)' "$out"; then
    echo "::error::the security review output has no findings and no 'No findings' marker, so it cannot count as a review"
    cat "$out"
    exit 1
fi

cat "$out"
[[ -z ${GITHUB_STEP_SUMMARY:-} ]] || { echo "## Security review"; echo; cat "$out"; } >> "$GITHUB_STEP_SUMMARY"
