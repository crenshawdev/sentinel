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

# --bare and --setting-sources user keep the pull request's own .claude
# settings, hooks and MCP servers from loading, and the only tools are
# Read, Grep and Glob.
rc=0
claude -p --bare --model "$model" --effort "$effort" \
    --setting-sources user --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" \
    --permission-mode dontAsk --no-session-persistence --output-format text \
    < "$prompt" > "$out" || rc=$?

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
