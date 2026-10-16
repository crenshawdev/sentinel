#!/usr/bin/env bash
# Run every lens against a repo: N Claude runs per lens, each in a fresh
# context, plus one Codex run per lens. Runs for one lens go in parallel.
#
# Usage: fanout.sh <repo-dir> [runs-per-lens=3]
#
# Writes <repo-dir>/audit/<timestamp>/<lens>/<run>.md (1.md .. N.md, codex.md),
# a <run>.log next to each, and run.txt describing the audit. A run that fails
# leaves only its .log, so merge.sh never parses an error message as a report.
# When <repo-dir>/audit/CONTEXT.md exists, it goes at the top of every prompt.
set -euo pipefail

MODEL="${SENTINEL_MODEL:-opus}"
EFFORT="${SENTINEL_EFFORT:-high}"
# Set here because with an API key Codex runs with an empty CODEX_HOME and never
# reads ~/.codex/config.toml. SENTINEL_CODEX_MODEL="" uses Codex's own default.
CODEX_MODEL="${SENTINEL_CODEX_MODEL-gpt-6-astra}"
CODEX_EFFORT="${SENTINEL_CODEX_EFFORT:-xhigh}"
RUN_TIMEOUT="${SENTINEL_RUN_TIMEOUT:-3600}"   # seconds per run

die() { echo "fanout.sh: $*" >&2; exit 2; }

[[ $# -ge 1 && $# -le 2 ]] || die "usage: fanout.sh <repo-dir> [runs-per-lens=3]"
repo=$(realpath "$1")
runs="${2:-3}"
[[ $runs =~ ^[1-9][0-9]*$ ]] || die "runs-per-lens must be a positive integer"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
[[ -f $repo/THREAT-MODEL.md ]] || die "$repo/THREAT-MODEL.md is missing; fill in threat-model.template.md first"
for tool in claude codex git tar timeout; do
    command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

sentinel=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
lenses=("$sentinel"/lenses/*.md)
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$repo/audit/$ts"
# The architectural map from the audit-context-building step, if it ran.
context="$repo/audit/CONTEXT.md"
mkdir -p "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Reviewers read a snapshot of the repo's tracked and untracked-but-not-ignored
# files, not the repo itself. Every run sees the same files, no run can read
# another run's output under audit/, and nothing a reviewer does can touch the
# real working tree. The kit itself is left out when it lives inside the repo,
# and so is everything that would hand reviewers earlier findings: /claude-security
# reports, the context map's own folder, and the tests that prove unfixed
# findings. They are named here as well as gitignored, in case the ignore lines
# are missing.
excludes=(":(exclude)audit" ":(exclude)audit-context" ":(exclude)CLAUDE-SECURITY-*"
          ":(exclude,glob)**/security-unfixed/**")
rel=$(realpath --relative-to="$repo" "$sentinel")
[[ $rel == .. || $rel == ../* ]] || excludes+=(":(exclude)$rel")
# A submodule shows up in the first listing as one directory, and copying that
# directory whole would bring in files its own .gitignore excludes (.env,
# target/). So directories are never copied recursively; the files inside
# submodules come from the second listing, which names each tracked file.
mkdir "$work/repo"
{
    git -C "$repo" ls-files -z --cached --others --exclude-standard -- . "${excludes[@]}"
    git -C "$repo" ls-files -z --cached --recurse-submodules -- . "${excludes[@]}"
} | sort -zu |
    tar -c -f - -C "$repo" --null --no-recursion --ignore-failed-read -T - |
    tar -x -f - -C "$work/repo"

# Claude: --safe-mode skips the user's and the repo's hooks, plugins, MCP
# servers and CLAUDE.md, and --setting-sources "" loads no settings file, so
# neither the repo's .claude/settings.json nor an allow rule in the user's own
# settings can widen what a reviewer reads. The tools are Read, Grep and Glob
# (--bare would drop Grep and Glob), nothing is pre-approved, so any read or search outside
# the snapshot is refused. With an API key set, the key is billed; without
# one, the logged-in plan is.
# SENTINEL_ANTHROPIC_API_KEY lets the key live in a shell profile without
# every interactive Claude Code session picking it up as ANTHROPIC_API_KEY.
claude_key="${SENTINEL_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}"
claude_mode=(--safe-mode)
if [[ -n $claude_key ]]; then
    claude_auth="API key (SENTINEL_ANTHROPIC_API_KEY or ANTHROPIC_API_KEY)"
else
    claude_auth="logged-in Claude plan (no API key set)"
fi

# Codex: codex exec reads CODEX_API_KEY, not OPENAI_API_KEY, so pass the key
# under that name. With a key, CODEX_HOME is an empty directory so the user's
# global AGENTS.md and config stay out of the run. Without one, Codex uses its
# own login and loads them.
codex_key="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
if [[ -n $codex_key ]]; then
    codex_home="$work/codex-home"
    mkdir -m 700 "$codex_home"
    codex_auth="API key (CODEX_API_KEY or OPENAI_API_KEY)"
else
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    codex_auth="existing Codex login (no API key set; global AGENTS.md will load)"
fi

{
    echo "repo: $repo"
    echo "commit: $(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    echo "uncommitted changes: $([[ -n $(git -C "$repo" status --porcelain -- . "${excludes[@]}") ]] && echo yes || echo no)"
    echo "sentinel commit: $(git -C "$sentinel" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    echo "started: $ts"
    echo "snapshot: $work/repo"
    echo "claude: model $MODEL, effort $EFFORT, runs per lens $runs, auth: $claude_auth"
    echo "codex: model ${CODEX_MODEL:-default}, effort $CODEX_EFFORT, reads limited to the snapshot, auth: $codex_auth"
    echo "lenses: $(basename -s .md -a "${lenses[@]}" | tr '\n' ' ')"
    echo "context map: $([[ -f $context ]] && echo "audit/CONTEXT.md, put at the top of every lens prompt" || echo "none (no audit/CONTEXT.md)")"
} > "$out/run.txt"
cat "$out/run.txt"
echo

status() { # lens run rc seconds
    local secs=$4 result
    if [[ $3 -eq 0 ]]; then result="ok"; else result="FAILED (exit $3, see $2.log)"; fi
    printf '[%s] %-7s %s in %dm%02ds\n' "$1" "$2" "$result" $((secs / 60)) $((secs % 60))
}

run_claude() { # lens prompt run
    local dest="$out/$1/$3" start=$SECONDS rc=0
    local envs=(-u OPENAI_API_KEY -u CODEX_API_KEY -u SENTINEL_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY)
    [[ -z $claude_key ]] || envs+=("ANTHROPIC_API_KEY=$claude_key")
    (cd "$work/repo" && env "${envs[@]}" \
        timeout --kill-after=30 "$RUN_TIMEOUT" \
        claude -p "${claude_mode[@]}" --model "$MODEL" --effort "$EFFORT" \
            --setting-sources "" --tools "Read,Grep,Glob" \
            --permission-mode dontAsk --no-session-persistence --output-format text \
        < "$2" > "$dest.md.part" 2> "$dest.log") || rc=$?
    if [[ $rc -eq 0 && -s $dest.md.part ]]; then
        mv "$dest.md.part" "$dest.md"
    else
        [[ $rc -ne 0 ]] || rc=1
        cat "$dest.md.part" >> "$dest.log"
        rm -f "$dest.md.part"
    fi
    status "$1" "$3" "$rc" $((SECONDS - start))
    return "$rc"
}

run_codex() { # lens prompt
    local dest="$out/$1/codex" start=$SECONDS rc=0
    # Codex's --sandbox read-only lets the model's commands read the whole disk
    # (home directory, keys), and it silently overrides any permission profile,
    # so it is not used. The "audit" profile makes only the system directories
    # commands need and the snapshot readable, with no writes and no network.
    # inherit="core" passes the commands PATH, HOME and the like, never
    # CODEX_API_KEY or any other key.
    # Codex runs each command through its own program, so the folder it is
    # installed in has to be readable too. When codex sits in a shared folder
    # (~/.local/bin, ~/.cargo/bin, /usr/bin and the like), the folder above
    # holds other programs' files, ~/.cargo/credentials.toml among them, so
    # only the binary's own folder is made readable.
    local codex_bin codex_root
    codex_bin=$(dirname "$(realpath "$(command -v codex)")")
    codex_root=$(dirname "$codex_bin")
    case $codex_root in
        / | /usr | /usr/local | /opt | "$HOME"/.local | "$HOME"/.cargo) codex_root=$codex_bin ;;
    esac
    [[ $HOME != "$codex_root" && $HOME != "$codex_root"/* ]] || codex_root=$codex_bin
    local args=(exec --cd "$work/repo" --skip-git-repo-check --ephemeral
                -c 'default_permissions="audit"'
                -c "permissions.audit.filesystem={\":minimal\"=\"read\", \":workspace_roots\"=\"read\", \"$codex_root\"=\"read\"}"
                -c 'shell_environment_policy.inherit="core"'
                -c "model_reasoning_effort=$CODEX_EFFORT" -c project_doc_max_bytes=0
                -o "$dest.md.part")
    [[ -z $CODEX_MODEL ]] || args+=(-m "$CODEX_MODEL")
    local envs=(-u ANTHROPIC_API_KEY -u SENTINEL_ANTHROPIC_API_KEY -u OPENAI_API_KEY "CODEX_HOME=$codex_home")
    [[ -z $codex_key ]] || envs+=("CODEX_API_KEY=$codex_key")
    env "${envs[@]}" timeout --kill-after=30 "$RUN_TIMEOUT" codex "${args[@]}" - \
        < "$2" > "$dest.log" 2>&1 || rc=$?
    if [[ $rc -eq 0 && -s $dest.md.part ]]; then
        mv "$dest.md.part" "$dest.md"
    else
        [[ $rc -ne 0 ]] || rc=1
        rm -f "$dest.md.part"
    fi
    status "$1" codex "$rc" $((SECONDS - start))
    return "$rc"
}

failed=0 total=0
for lens_file in "${lenses[@]}"; do
    lens=$(basename "$lens_file" .md)
    mkdir -p "$out/$lens"
    prompt="$work/$lens.prompt.md"
    {
        if [[ -f $context ]]; then
            echo "## Architectural map of this repository"
            echo
            echo "This map was written before the review to save you reading time. Treat it as a guide, and trust the code where they disagree."
            echo
            cat "$context"
            echo
            echo "---"
            echo
        fi
        cat "$lens_file"
        echo
        cat "$sentinel/finding-format.md"
    } > "$prompt"

    pids=()
    for ((i = 1; i <= runs; i++)); do
        run_claude "$lens" "$prompt" "$i" &
        pids+=($!)
    done
    run_codex "$lens" "$prompt" &
    pids+=($!)
    for pid in "${pids[@]}"; do
        total=$((total + 1))
        wait "$pid" || failed=$((failed + 1))
    done
done

echo
echo "$((total - failed)) of $total runs succeeded. Results: $out"
echo "Next: $sentinel/merge.sh $out"
[[ $failed -eq 0 ]]
