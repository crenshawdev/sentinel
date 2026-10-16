#!/usr/bin/env bash
# Read a pull request's encrypted security review on your own machine.
#
# Usage: read-review.sh <pull-request-number> [age-identity-file]
#
# Run it inside the repo's checkout. It finds the newest fast.yml run for the
# pull request's head commit, downloads that run's security-review artifact
# into a temporary folder, decrypts it with your age identity and prints it.
# The identity is the second argument, else $SENTINEL_AGE_IDENTITY, else
# ~/.config/sentinel/age.key. The temporary folder is removed afterwards.
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $(basename "$0") <pull-request-number> [age-identity-file]" >&2; exit 2; }
pr=$1
identity=${2:-${SENTINEL_AGE_IDENTITY:-$HOME/.config/sentinel/age.key}}
for tool in gh age; do
    command -v "$tool" >/dev/null || { echo "read-review.sh: $tool not found on PATH" >&2; exit 2; }
done
[[ -r $identity ]] || { echo "read-review.sh: no age identity at $identity" >&2; exit 2; }

sha=$(gh pr view "$pr" --json headRefOid -q .headRefOid)
# By file name, not the workflow's display name, which another workflow could share.
run=$(gh run list --workflow fast.yml --commit "$sha" --json databaseId -q '.[0].databaseId')
[[ -n $run ]] || { echo "read-review.sh: no fast.yml run for pull request $pr at $sha" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh run download "$run" -n security-review -D "$tmp"
# The review is model output about untrusted code, so control characters,
# C0 and C1 and so every terminal escape, are removed before it reaches the
# terminal. Bytes that are not valid UTF-8 become U+FFFD.
age -d -i "$identity" "$tmp/security-review.md.age" |
    python3 -I -c 'import re, sys; t = sys.stdin.buffer.read().decode("utf-8", "replace"); sys.stdout.write(re.sub("[\x00-\x08\x0b-\x1f\x7f-\x9f]", "", t))'
