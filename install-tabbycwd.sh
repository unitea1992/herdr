#!/usr/bin/env bash
# install-tabbycwd.sh — one-line Linux installer for the personal herdr fork
# (unitea1992/herdr, branch local/tabby-cwd).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/unitea1992/herdr/local/tabby-cwd/install-tabbycwd.sh | bash
#
# Overrides:
#   HERDR_LOCAL_BIN   binary dir (default $HOME/.local/bin)
#
# Linux-only. Installs Rust tooling (rustup) and Zig 0.15.2 into user space
# only — no sudo, no system packages, no Windows/macOS tooling. Each run
# shallow-clones the fork into a throwaway temp dir, builds with the shared
# $HOME/.cache/herdr/target, installs herdr + update-herdr, and removes the
# clone; no persistent source checkout is created. Safe to re-run
# (marker-guarded .bashrc edits, build failure never overwrites an
# already-installed binary).
set -euo pipefail

BIN_DIR="${HERDR_LOCAL_BIN:-$HOME/.local/bin}"
BRANCH="local/tabby-cwd"
FORK_URL="https://github.com/unitea1992/herdr.git"
ZIG_VERSION="0.15.2"
ZIG_ROOT="$HOME/.local/share/herdr/zig-$ZIG_VERSION"
CARGO_TARGET_DIR="$HOME/.cache/herdr/target"
export CARGO_TARGET_DIR

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

# Zig 0.15.2 is kept as a complete distribution tree (zig binary + lib/ +
# docs) under $HOME/.local/share/herdr/zig-$ZIG_VERSION/. A lone `zig` binary
# cannot find its lib/ for the vendored libghostty-vt build, so we never drop
# a bare binary into $HOME/.local/bin/zig. Resolution order: our managed
# complete tree first, then an exact-version PATH zig whose real location has
# a lib/ next to it (realpath so symlinked installs work), then install.
zig_complete() {
    local real
    real="$(readlink -f "$1" 2>/dev/null || echo "$1")"
    [[ -x "$real" ]] && [[ -d "${real%/*}/lib" ]]
}

ensure_zig() {
    local managed="$ZIG_ROOT/zig"
    if zig_complete "$managed"; then
        say "zig $ZIG_VERSION installation found at ${managed%/*}"
        ZIG="$managed"
        return
    fi
    if command -v zig >/dev/null 2>&1 \
        && [[ "$(zig version 2>/dev/null)" == "$ZIG_VERSION" ]] \
        && zig_complete "$(command -v zig)"; then
        say "zig $ZIG_VERSION complete installation found on PATH"
        ZIG="zig"
        return
    fi
    say "installing zig $ZIG_VERSION to ${managed%/*} (user space; other zig versions untouched)"
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
    local root="$(dirname "$managed")"
    mkdir -p "$(dirname "$root")"
    rm -rf "$root"  # herdr-owned tree only; never touches ~/.local/bin/zig
    cp -a "$tmp/$extracted" "$root"
    ZIG="$root/zig"
}

# Shallow-clone only branch $BRANCH at its current HEAD; no other history or
# branches. The clone lives in the throwaway $WORK dir and is removed by the
# EXIT trap in main().
clone_fork() {
    say "cloning $FORK_URL ($BRANCH, --depth=1)"
    git clone --depth=1 --branch "$BRANCH" "$FORK_URL" "$WORK/repo"
    HEAD_SHA="$(git -C "$WORK/repo" rev-parse --short HEAD)"
    say "checked out $BRANCH @ $HEAD_SHA"
}

# Build the release binary into the shared cargo target dir; non-zero on
# failure so install is skipped and the installed binary stays untouched.
build_release() {
    local dir="$1"
    ( cd "$dir" && HERDR_BUILD_CHANNEL=tabbycwd HERDR_BUILD_ID="$HEAD_SHA" ZIG="$ZIG" cargo build --release --locked )
}

build_and_install() {
    build_release "$WORK/repo"
    say "install -> $BIN_DIR/herdr"
    install -Dm755 "$CARGO_TARGET_DIR/release/herdr" "$BIN_DIR/herdr"
    say "install -> $BIN_DIR/update-herdr"
    install -Dm755 "$WORK/repo/scripts/update-herdr" "$BIN_DIR/update-herdr"
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
    local version upstream_version
    version="$("$BIN_DIR/herdr" --version)"
    if upstream_version="$(check_version_format "$version" "$HEAD_SHA")"; then
        say "installed: herdr $upstream_version+tabbycwd.$HEAD_SHA"
    else
        die "unexpected version (expected 'herdr <ver>+tabbycwd.$HEAD_SHA'): $version"
    fi
}

main() {
    # Test-only short-circuit: lets the isolated test prove the guard reaches
    # main() via stdin or direct execution without any network. Never set for
    # real use.
    if [[ "${HERDR_LOCAL_TEST:-}" == "1" ]]; then
        echo "main() reached (test)"
        return
    fi
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    require_linux
    require_commands
    ensure_bin_dir
    ensure_rust
    ensure_zig
    clone_fork
    build_and_install
    ensure_bashrc_path
    ensure_bashrc_guard
    verify
    echo
    echo "install complete."
    echo "  binary:  $BIN_DIR/herdr"
    echo "  updater: $BIN_DIR/update-herdr"
    echo "  source:  temporary clone (removed)"
    echo "update with: update-herdr"
}

# Executed paths: `bash install-tabbycwd.sh` (BASH_SOURCE[0] == $0) and
# `curl ... | bash` / `cat ... | bash` (BASH_SOURCE[0] unbound under `set -u`,
# empty with :-, $0 == bash). Sourced: BASH_SOURCE[0] is the file path, != $0,
# so main is skipped. `:-` keeps this safe under `set -u`.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi
