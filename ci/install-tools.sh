#!/usr/bin/env bash
# Install the tools check.sh runs on a Debian or Ubuntu CI runner. Run it from
# the root of the repo under audit. mechanical/install.sh is the Arch version
# for a workstation.
#
# Usage: install-tools.sh [--all]
#   default  the gating tools only: cargo-audit, cargo-deny and clippy when the
#            repo has a Cargo.toml, and semgrep
#   --all    also the reported tools: cargo-geiger, cargo-vet, cargo-fuzz and
#            Miri with a nightly toolchain, pip-audit and bandit
#
# Works as root without sudo (Forgejo runner images) and as a normal user with
# sudo (GitHub runners). New PATH entries are written to $GITHUB_PATH, which
# both GitHub and Forgejo read.
set -euo pipefail

all=0
[[ ${1:-} == --all ]] && all=1

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
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    add_path "$HOME/.cargo/bin"
    rustup toolchain install stable --profile minimal --component clippy
    tools=(cargo-audit cargo-deny)
    if [[ $all -eq 1 ]]; then
        tools+=(cargo-geiger cargo-vet cargo-fuzz)
        rustup toolchain install nightly --profile minimal --component miri
    fi
    cargo install --locked "${tools[@]}"
fi

pipx install semgrep
if [[ $all -eq 1 ]]; then
    pipx install pip-audit
    pipx install bandit
fi
