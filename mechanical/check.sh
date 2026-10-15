#!/usr/bin/env bash
# Run the mechanical security checks that apply to a repo.
#
# Usage: check.sh [repo-dir=.]
#
# Gates (a failure, or the tool missing, makes the exit code non-zero):
#   cargo audit, cargo deny, cargo clippy, semgrep
# Reported only (output shown, exit code ignored):
#   cargo geiger, cargo vet, cargo fuzz build, cargo miri test (only when the
#   repo has unsafe code), npm audit, pip-audit, bandit
set -uo pipefail

mech=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
repo=$(realpath "${1:-.}")
[[ -d $repo ]] || { echo "check.sh: $repo is not a directory" >&2; exit 2; }
cd "$repo" || exit 2

summary=()
gate_failed=0

# step gate|report <name> <tool> <command...>
step() {
    local kind=$1 name=$2 tool=$3
    shift 3
    echo
    echo "==> $name"
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found; see mechanical/install.sh"
        if [[ $kind == gate ]]; then
            summary+=("FAIL     $name (not installed)")
            gate_failed=1
        else
            summary+=("MISSING  $name (not installed)")
        fi
        return
    fi
    local rc=0
    "$@" || rc=$?
    if [[ $kind == gate ]]; then
        if [[ $rc -eq 0 ]]; then
            summary+=("PASS     $name")
        else
            summary+=("FAIL     $name (exit $rc)")
            gate_failed=1
        fi
    else
        summary+=("REPORT   $name (exit $rc)")
    fi
}

skip() { summary+=("SKIPPED  $1 ($2)"); }

# cargo subcommands are separate binaries, so check for those by name.
cargo_sub() { command -v "cargo-$1" >/dev/null && echo cargo || echo "cargo-$1"; }

if [[ -f Cargo.toml ]]; then
    deny_cfg="$repo/deny.toml"
    [[ -f $deny_cfg ]] || deny_cfg="$mech/deny.toml"
    step gate "cargo audit" "$(cargo_sub audit)" cargo audit
    step gate "cargo deny ($deny_cfg)" "$(cargo_sub deny)" \
        cargo deny --manifest-path Cargo.toml --config "$deny_cfg" check
    step gate "cargo clippy" "$(cargo_sub clippy)" \
        cargo clippy --all-targets -- -W clippy::pedantic -W clippy::nursery

    # Manifest paths of every workspace member (or the one package).
    members() {
        cargo metadata --no-deps --format-version 1 |
            python3 -c 'import json,sys; print("\n".join(p["manifest_path"] for p in json.load(sys.stdin)["packages"]))'
    }

    # cargo geiger cannot run on a virtual workspace manifest, so run it on
    # each workspace member.
    geiger() {
        local manifests rc=0 m
        manifests=$(members) || return 1
        while IFS= read -r m; do
            echo "-- $m"
            cargo geiger --manifest-path "$m" || rc=$?
        done <<< "$manifests"
        return "$rc"
    }
    step report "cargo geiger" "$(cargo_sub geiger)" geiger

    if [[ -d supply-chain ]]; then
        step report "cargo vet" "$(cargo_sub vet)" cargo vet --locked
    else
        skip "cargo vet" "no supply-chain/ directory; run cargo vet init to start"
    fi

    # fuzz/ can sit at the repo root or inside any workspace member.
    fuzz_dirs=()
    while IFS= read -r d; do
        [[ -f $d/fuzz/Cargo.toml ]] && fuzz_dirs+=("$d")
    done < <({ echo "$repo"; members 2>/dev/null | xargs -r -d '\n' -n1 dirname; } | sort -u)
    fuzz_build() {
        local rc=0 d
        for d in "${fuzz_dirs[@]}"; do
            echo "-- $d/fuzz"
            (cd "$d" && cargo +nightly fuzz build) || rc=$?
        done
        return "$rc"
    }
    if [[ ${#fuzz_dirs[@]} -gt 0 ]]; then
        step report "cargo fuzz build" "$(cargo_sub fuzz)" fuzz_build
    else
        skip "cargo fuzz build" "no fuzz/ directory at the root or in any workspace member"
    fi

    # Miri checks unsafe code for undefined behavior, so it runs only when the
    # repo's own Rust code has an unsafe block, fn, impl, trait or extern.
    if grep -rqE --include='*.rs' --exclude-dir=target --exclude-dir=.git \
        --exclude-dir=vendor --exclude-dir=third_party \
        'unsafe[[:space:]]*(\{|fn|impl|trait|extern)' .; then
        step report "cargo miri test" "$(cargo_sub miri)" cargo +nightly miri test --workspace --lib --bins
    else
        skip "cargo miri test" "no unsafe code in the repo's own Rust files"
    fi
else
    skip "cargo checks" "no Cargo.toml"
fi

semgrep_args=(scan --metrics=off --error --exclude=audit)
while read -r section value; do
    case $section in
        configs)
            [[ $value == p/* || $value == r/* || $value == /* ]] || value="$mech/$value"
            semgrep_args+=(--config "$value") ;;
        exclude-rules)
            semgrep_args+=(--exclude-rule "$value") ;;
    esac
done < <(awk '/^[a-z-]+:/ { section = $1; sub(/:$/, "", section); next }
              /^[[:space:]]*-[[:space:]]*[^#[:space:]]/ { print section, $2 }' "$mech/semgrep.yml")
step gate "semgrep" semgrep semgrep "${semgrep_args[@]}" .

if [[ -f package.json ]]; then
    if [[ -f package-lock.json ]]; then
        step report "npm audit" npm npm audit
    else
        skip "npm audit" "no package-lock.json; npm audit needs one"
    fi
else
    skip "npm audit" "no package.json"
fi

if [[ -f pyproject.toml || -f requirements.txt ]]; then
    pip_args=()
    [[ -f requirements.txt ]] && pip_args+=(-r requirements.txt)
    grep -q '^\[project\]' pyproject.toml 2>/dev/null && pip_args+=(.)
    if [[ ${#pip_args[@]} -gt 0 ]]; then
        step report "pip-audit" pip-audit pip-audit "${pip_args[@]}"
    else
        skip "pip-audit" "pyproject.toml has no [project] table and there is no requirements.txt"
    fi
    step report "bandit" bandit bandit -r . \
        -x ./.git,./.venv,./venv,./node_modules,./target,./audit,./.tox,./__pycache__
else
    skip "pip-audit and bandit" "no pyproject.toml or requirements.txt"
fi

echo
echo "==> summary"
printf '%s\n' "${summary[@]}"
exit "$gate_failed"
