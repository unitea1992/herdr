#!/usr/bin/env bash
# install-tabbycwd.sh — one-line Linux installer for the personal herdr fork
# (unitea1992/herdr, branch local/tabby-cwd).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/unitea1992/herdr/local/tabby-cwd/install-tabbycwd.sh | bash
#
# Overrides:
#   HERDR_LOCAL_REPO  repo checkout path (default $HOME/projects/herdr)
#   HERDR_LOCAL_BIN   binary dir (default $HOME/.local/bin)
#
# Linux-only. Installs Rust tooling (rustup, cargo-binstall, cargo-nextest)
# and Zig 0.15.2 into user space only — no sudo, no system packages, no
# Windows/macOS tooling. Never resets or deletes a dirty checkout. Safe to
# re-run (marker-guarded .bashrc edits, no duplicates).
set -euo pipefail

REPO="${HERDR_LOCAL_REPO:-$HOME/projects/herdr}"
BIN_DIR="${HERDR_LOCAL_BIN:-$HOME/.local/bin}"
BRANCH="local/tabby-cwd"
FORK_URL="https://github.com/unitea1992/herdr.git"
UPSTREAM_URL="https://github.com/herdrdev/herdr.git"
ZIG_VERSION="0.15.2"

GUARD_BLOCK='herdr() {
    if [[ "${1:-}" == "update" ]]; then
        echo "Custom Herdr build detected."
        echo "Use: update-herdr"
        return 1
    fi
    command herdr "$@"
}'

die() {
    echo "error: $*" >&2
    exit 1
}

say() { echo "== $*"; }

# Append a marker-guarded block to a file exactly once. Exit 1 if already present.
append_marker_block() {
    local file="$1" marker="$2" block="$3"
    if [[ -f "$file" ]] && grep -qF "# $marker" "$file"; then
        return 1
    fi
    printf '\n# %s\n%s\n' "$marker" "$block" >> "$file"
    return 0
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || die "this installer is Linux-only (uname -s: $(uname -s))"
}

require_commands() {
    local missing=()
    for cmd in git curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "required commands missing: ${missing[*]} (install with your distribution's package manager)"
    fi
}

ensure_bin_dir() {
    mkdir -p "$BIN_DIR"
}

ensure_rust() {
    if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
        say "rust toolchain present: $(cargo --version)"
        return
    fi
    say "installing rust toolchain via rustup (user space, no sudo)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default --no-modify-path
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! append_marker_block "$HOME/.bashrc" "herdr: cargo PATH" 'export PATH="$HOME/.cargo/bin:$PATH"'; then
        say "cargo PATH entry already present in ~/.bashrc"
    fi
}

ensure_binstall() {
    if command -v cargo-binstall >/dev/null 2>&1; then
        say "cargo-binstall present"
        return
    fi
    say "installing cargo-binstall (user space)"
    curl -L --proto '=https' --tlsv1.2 -sSf \
        https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
        | bash
    export PATH="$HOME/.cargo/bin:$PATH"
}

ensure_nextest() {
    if command -v cargo-nextest >/dev/null 2>&1; then
        say "cargo-nextest present"
        return
    fi
    say "installing cargo-nextest via cargo-binstall"
    cargo binstall cargo-nextest --no-confirm
}

ensure_zig() {
    if command -v zig >/dev/null 2>&1 && [[ "$(zig version 2>/dev/null)" == "$ZIG_VERSION" ]]; then
        say "zig $ZIG_VERSION found on PATH"
        ZIG_BIN="zig"
        return
    fi
    local candidate="$HOME/.local/bin/zig"
    if [[ -x "$candidate" ]] && [[ "$("$candidate" version 2>/dev/null)" == "$ZIG_VERSION" ]]; then
        say "zig $ZIG_VERSION found at $candidate"
        ZIG_BIN="$candidate"
        return
    fi
    say "installing zig $ZIG_VERSION to $HOME/.local/bin/zig (user space; other zig versions untouched)"
    local arch tarball extracted tmp
    arch="$(uname -m)"
    case "$arch" in
        x86_64) tarball="zig-x86_64-linux-$ZIG_VERSION.tar.xz" ;;
        aarch64) tarball="zig-aarch64-linux-$ZIG_VERSION.tar.xz" ;;
        *) die "unsupported architecture: $arch" ;;
    esac
    extracted="zig-$arch-linux-$ZIG_VERSION"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL -o "$tmp/$tarball" "https://ziglang.org/download/$ZIG_VERSION/$tarball"
    tar -C "$tmp" -xf "$tmp/$tarball"
    install -Dm755 "$tmp/$extracted/zig" "$HOME/.local/bin/zig"
    ZIG_BIN="$HOME/.local/bin/zig"
}

ensure_repo() {
    if [[ ! -e "$REPO" ]]; then
        say "cloning fork into $REPO"
        git clone "$FORK_URL" "$REPO"
        return
    fi
    if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
        die "$REPO exists but is not a git repository; move it away and re-run"
    fi
    say "repo exists: $REPO"
    if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
        echo "error: $REPO has uncommitted changes; refusing to touch it" >&2
        git -C "$REPO" status --short >&2
        exit 1
    fi
}

ensure_remotes() {
    cd "$REPO"
    if git remote get-url origin >/dev/null 2>&1; then
        [[ "$(git remote get-url origin)" == "$FORK_URL" ]] || git remote set-url origin "$FORK_URL"
    else
        git remote add origin "$FORK_URL"
    fi
    if git remote get-url upstream >/dev/null 2>&1; then
        [[ "$(git remote get-url upstream)" == "$UPSTREAM_URL" ]] || git remote set-url upstream "$UPSTREAM_URL"
    else
        git remote add upstream "$UPSTREAM_URL"
    fi
}

ensure_branch() {
    cd "$REPO"
    [[ "$(git branch --show-current)" == "$BRANCH" ]] && return
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git checkout "$BRANCH"
    else
        git checkout -b "$BRANCH" "origin/$BRANCH"
    fi
}

ensure_rebased() {
    cd "$REPO"
    git rev-parse --verify -q upstream/master >/dev/null || die "upstream/master not found after fetch"
    if [[ "$(git rev-list --count HEAD..upstream/master)" == "0" ]]; then
        say "branch is up to date with upstream/master"
        return
    fi
    say "rebase $BRANCH onto upstream/master"
    if ! git rebase upstream/master; then
        echo "error: rebase conflicts; aborting (resolve manually, then run update-herdr)" >&2
        git diff --name-only --diff-filter=U >&2
        git rebase --abort
        exit 1
    fi
}

build_and_install() {
    cd "$REPO"
    local head_sha
    head_sha="$(git rev-parse --short HEAD)"
    say "cargo build --release (channel=tabbycwd, id=$head_sha, zig=$ZIG_BIN)"
    HERDR_BUILD_CHANNEL=tabbycwd HERDR_BUILD_ID="$head_sha" ZIG="$ZIG_BIN" cargo build --release --locked
    say "install -> $BIN_DIR/herdr"
    install -Dm755 target/release/herdr "$BIN_DIR/herdr"
    say "install -> $BIN_DIR/update-herdr"
    install -Dm755 scripts/update-herdr "$BIN_DIR/update-herdr"
}

ensure_bashrc_path() {
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        say "$BIN_DIR already on PATH"
        return
    fi
    if ! append_marker_block "$HOME/.bashrc" "herdr: local bin PATH" "export PATH=\"$BIN_DIR:\$PATH\""; then
        say "$BIN_DIR PATH entry already present in ~/.bashrc"
    else
        say "added $BIN_DIR to PATH in ~/.bashrc"
    fi
}

ensure_bashrc_guard() {
    if [[ -f "$HOME/.bashrc" ]] && grep -q '^herdr()' "$HOME/.bashrc"; then
        say "herdr() wrapper already defined in ~/.bashrc"
        return
    fi
    if ! append_marker_block "$HOME/.bashrc" "herdr: custom fork guard" "$GUARD_BLOCK"; then
        say "herdr() update guard already present in ~/.bashrc"
    else
        say "added herdr() update guard to ~/.bashrc"
    fi
}

# Exit 0 and print the upstream version when $version matches
# `herdr <ver>+tabbycwd.<expected_sha>`; exit 1 otherwise.
check_version_format() {
    local version="$1" expected_sha="$2"
    [[ "$version" =~ ^herdr\ (.+)\+tabbycwd\.([0-9a-f]+)$ ]] || return 1
    [[ "${BASH_REMATCH[2]}" == "$expected_sha" ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

verify() {
    local version sha upstream_version
    version="$("$BIN_DIR/herdr" --version)"
    sha="$(git -C "$REPO" rev-parse --short HEAD)"
    if upstream_version="$(check_version_format "$version" "$sha")"; then
        say "installed: herdr $upstream_version+tabbycwd.$sha"
    else
        die "unexpected version (expected 'herdr <ver>+tabbycwd.$sha'): $version"
    fi
}

main() {
    require_linux
    require_commands
    ensure_bin_dir
    ensure_rust
    ensure_binstall
    ensure_nextest
    ensure_zig
    ensure_repo
    ensure_remotes
    cd "$REPO"
    echo "== git fetch origin + upstream =="
    git fetch origin
    git fetch upstream
    ensure_branch
    ensure_rebased
    build_and_install
    ensure_bashrc_path
    ensure_bashrc_guard
    verify
    echo
    echo "install complete."
    echo "  binary:  $BIN_DIR/herdr"
    echo "  updater: $BIN_DIR/update-herdr"
    echo "  repo:    $REPO (branch $BRANCH)"
    echo "update with: update-herdr   (or: update-herdr --check)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
