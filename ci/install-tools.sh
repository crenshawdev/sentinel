#!/usr/bin/env bash
# Install the tools check.sh runs on a Debian or Ubuntu CI runner. Run it from
# the root of the repo under audit. mechanical/install.sh is the Arch version
# for a workstation.
#
# Usage: install-tools.sh
#   The gating tools: cargo-audit, cargo-deny and clippy when the repo has a
#   Cargo.toml, and semgrep.
#
# Works as root without sudo (Forgejo runner images) and as a normal user with
# sudo (GitHub runners). New PATH entries are written to $GITHUB_PATH, which
# both GitHub and Forgejo read.
set -euo pipefail

[[ $# -eq 0 ]] || { echo "usage: $(basename "$0")" >&2; exit 2; }

sudo=()
[[ $EUID -eq 0 ]] || sudo=(sudo)

"${sudo[@]}" apt-get update
"${sudo[@]}" apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev ca-certificates curl git python3 pipx

add_path() {
    export PATH="$1:$PATH"
    [[ -z ${GITHUB_PATH:-} ]] || echo "$1" >> "$GITHUB_PATH"
}
add_path "$HOME/.local/bin"

if [[ -f Cargo.toml ]]; then
    if ! command -v rustup >/dev/null; then
        # GitHub's runners already have rustup; this is for images that do not.
        # The installer's version and SHA-256 are pinned here, so a changed
        # file on the download server is refused instead of run.
        rustup_version=1.29.1
        case $(uname -m) in
            x86_64) target=x86_64-unknown-linux-gnu
                    sum=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71 ;;
            aarch64) target=aarch64-unknown-linux-gnu
                     sum=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433 ;;
            *) echo "install-tools.sh: no pinned rustup-init for $(uname -m)" >&2; exit 1 ;;
        esac
        init=$(mktemp)
        curl --proto '=https' --tlsv1.2 -sSf -o "$init" \
            "https://static.rust-lang.org/rustup/archive/$rustup_version/$target/rustup-init"
        echo "$sum  $init" | sha256sum -c --quiet -
        chmod +x "$init"
        "$init" -y --profile minimal
        rm -f "$init"
    fi
    add_path "$HOME/.cargo/bin"
    rustup toolchain install stable --profile minimal --component clippy
    cargo install --locked cargo-audit cargo-deny
fi

pipx install semgrep
