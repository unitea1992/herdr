#!/usr/bin/env bash
# Local tests for the personal fork installer/updater. Runs against an
# isolated HOME (fake tools, fake repos); never touches the real repo,
# ~/.bashrc, or the network. Run with: bash scripts/test_installer_local.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/install-tabbycwd.sh"
UPDATER="$REPO_ROOT/scripts/update-herdr"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- static checks ----------------------------------------------------------
for f in "$INSTALLER" "$UPDATER"; do
    grep -n '/home/helios' "$f" && fail "$f hardcodes /home/helios"
    grep -inE 'windows|msvc|powershell|darwin|macos' "$f" | grep -vE '^[0-9]+:#' && fail "$f references cross-platform tooling"
done
ok "no /home/helios hardcode; no windows/macos/ps1 references"

grep -q 'nextest run' "$UPDATER" || fail "update-herdr --check missing nextest"
grep -vE '^#' "$UPDATER" | grep -q 'just' && fail "update-herdr depends on just (a stale apt just on PATH must be irrelevant)"
grep -q 'HERDR_LOCAL_REPO' "$INSTALLER" || fail "installer missing HERDR_LOCAL_REPO"
grep -q 'HERDR_LOCAL_BIN' "$INSTALLER" || fail "installer missing HERDR_LOCAL_BIN"
grep -q '0.15.2' "$UPDATER" || fail "updater zig version not pinned to 0.15.2"
grep -q '0.15.2' "$INSTALLER" || fail "installer zig version not pinned to 0.15.2"
grep -q 'force-with-lease' "$UPDATER" || fail "updater missing --force-with-lease"
ok "static checks"

# --- isolated environment ---------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
export HERDR_LOCAL_REPO="$HOME/projects/herdr"
export HERDR_LOCAL_BIN="$HOME/.local/bin"

# source both scripts to test their functions (BASH_SOURCE guard skips main)
source "$INSTALLER"
source "$UPDATER"

make_zig() { # $1=version $2=path (#!/bin/bash: PATH is stubbed in tests, env cannot resolve bash)
    mkdir -p "$(dirname "$2")"
    printf '#!/bin/bash\nif [[ "${1:-}" == "version" ]]; then echo "%s"; fi\n' "$1" > "$2"
    chmod +x "$2"
}

# --- linux-only guard -------------------------------------------------------
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/bash\necho Darwin\n' > "$fakebin/uname"
chmod +x "$fakebin/uname"
if (PATH="$fakebin" require_linux) >/dev/null 2>&1; then
    fail "require_linux accepted a non-Linux uname"
fi
ok "require_linux rejects non-Linux"

# --- zig detection (installer + updater) ------------------------------------
zigpath="$tmp/zigpath"
mkdir -p "$zigpath"
make_zig 0.15.2 "$zigpath/zig"
got="$(PATH="$zigpath" resolve_zig)"
[[ "$got" == "zig" ]] || fail "resolve_zig did not pick PATH zig (got: $got)"
PATH="$zigpath" ensure_zig
[[ "${ZIG_BIN:-}" == "zig" ]] || fail "ensure_zig did not set ZIG_BIN=zig"
ok "zig 0.15.2 on PATH detected"

make_zig 0.14.0 "$zigpath/zig"   # wrong version on PATH
make_zig 0.15.2 "$HOME/.local/bin/zig"
got="$(PATH="$zigpath" resolve_zig)"
[[ "$got" == "$HOME/.local/bin/zig" ]] || fail "resolve_zig did not fall back to \$HOME/.local/bin/zig (got: $got)"
PATH="$zigpath" ensure_zig
[[ "${ZIG_BIN:-}" == "$HOME/.local/bin/zig" ]] || fail "ensure_zig did not use \$HOME/.local/bin/zig"
ok "wrong PATH zig falls back to \$HOME/.local/bin/zig 0.15.2 (other versions untouched)"

rm -f "$HOME/.local/bin/zig"
if out="$(PATH="$zigpath" resolve_zig 2>&1)"; then
    fail "resolve_zig succeeded with no zig 0.15.2 available"
fi
echo "$out" | grep -q 'zig 0.15.2' || fail "missing zig error message"
ok "missing zig 0.15.2 errors with install hint"

# --- dependency preflight (updater, report-only) -----------------------------
shim="$tmp/shim"
mkdir -p "$shim" "$tmp/emptybin"
printf '#!/bin/bash\necho "cargo 1.85.0 (fake)"\n' > "$shim/cargo"
printf '#!/bin/bash\necho "rustc 1.85.0 (fake)"\n' > "$shim/rustc"
make_zig 0.15.2 "$shim/zig"
chmod +x "$shim/cargo" "$shim/rustc"

if out="$(PATH="$shim:/usr/bin:/bin" preflight_check_deps 2>&1)"; then
    fail "preflight_check_deps passed without cargo-nextest"
fi
echo "$out" | grep -q 'cargo-nextest' || fail "missing nextest error"
echo "$out" | grep -q 'cargo binstall cargo-nextest --no-confirm' || fail "missing binstall hint"
ok "missing cargo-nextest errors with binstall hint"

if out="$(PATH="$tmp/emptybin" preflight_build_deps 2>&1)"; then
    fail "preflight_build_deps passed without cargo"
fi
echo "$out" | grep -q "required command 'cargo'" || fail "missing cargo error"
ok "missing cargo errors clearly"

# --- .bashrc edits are marker-guarded and idempotent -------------------------
( export PATH="/usr/bin:/bin"; ensure_bashrc_path; ensure_bashrc_path )
count=$(grep -c 'herdr: local bin PATH' "$HOME/.bashrc" || true)
[[ "$count" == "1" ]] || fail "PATH marker duplicated ($count)"
ok ".bashrc PATH append idempotent"

ensure_bashrc_guard
ensure_bashrc_guard
count=$(grep -c '^herdr()' "$HOME/.bashrc" || true)
[[ "$count" == "1" ]] || fail "herdr() guard duplicated ($count)"
grep -q 'Custom Herdr build detected' "$HOME/.bashrc" || fail "guard body missing"
grep -q 'command herdr "\$@"' "$HOME/.bashrc" || fail "guard does not forward via command herdr"
ok ".bashrc herdr() guard appended exactly once"

rm -f "$HOME/.bashrc"
printf 'herdr() { echo user-defined; }\n' > "$HOME/.bashrc"
ensure_bashrc_guard
count=$(grep -c '^herdr()' "$HOME/.bashrc" || true)
[[ "$count" == "1" ]] || fail "user-defined herdr() duplicated"
ok "existing user herdr() left untouched"

# --- execution guard: source vs stdin vs direct -------------------------------
# Regression: `curl ... | bash` runs the installer via stdin, where BASH_SOURCE[0]
# is unbound and $0 is bash. Under `set -u` the old guard died with
# "BASH_SOURCE[0]: unbound variable" before reaching main. HERDR_LOCAL_TEST=1
# lets these run to the marked main() without any network or real-env changes.
export HERDR_LOCAL_TEST=1
out="$(cat "$INSTALLER" | bash 2>&1)" || fail "stdin-executed installer crashed"
echo "$out" | grep -q 'main() reached (test)' || fail "installer run via stdin did not reach main()"
unset HERDR_LOCAL_TEST
ok "stdin (curl ... | bash) reaches main() under set -u"

out="$(env HERDR_LOCAL_TEST=1 bash "$INSTALLER" 2>&1)" || fail "direct-executed installer crashed"
echo "$out" | grep -q 'main() reached (test)' || fail "installer run as script did not reach main()"
ok "bash install-tabbycwd.sh reaches main() under set -u"

out="$(env HERDR_LOCAL_TEST=1 bash -c 'source "$1"' _ "$INSTALLER" 2>&1)" || fail "sourced installer crashed"
echo "$out" | grep -q 'main() reached (test)' && fail "sourced installer ran main()"
ok "source install-tabbycwd.sh does not invoke main()"

# --- dirty repo is never touched ---------------------------------------------
rm -f "$HOME/.bashrc"
git init -q "$REPO"
echo "user change" > "$REPO/important.txt"
if out="$(ensure_repo 2>&1)"; then
    fail "ensure_repo accepted a dirty repo"
fi
echo "$out" | grep -q 'uncommitted changes' || fail "dirty-repo message missing"
[[ -f "$REPO/important.txt" ]] || fail "dirty file was deleted"
[[ "$(cat "$REPO/important.txt")" == "user change" ]] || fail "dirty file content changed"
ok "dirty repo refused and preserved"

rm -rf "$REPO"
mkdir -p "$REPO"
if out="$(ensure_repo 2>&1)"; then
    fail "ensure_repo accepted a non-git directory"
fi
echo "$out" | grep -q 'not a git repository' || fail "non-git message missing"
ok "non-git directory refused"

# --- remotes + branch setup ---------------------------------------------------
rm -rf "$REPO"
git init -q --bare "$tmp/fork.git"
git -C "$tmp/fork.git" symbolic-ref HEAD refs/heads/master
git clone -q "$tmp/fork.git" "$tmp/seed"
git -C "$tmp/seed" config user.email t@t
git -C "$tmp/seed" config user.name t
git -C "$tmp/seed" commit -q --allow-empty -m base
git -C "$tmp/seed" push -q origin master
git -C "$tmp/seed" checkout -q -b local/tabby-cwd
git -C "$tmp/seed" commit -q --allow-empty -m patch
git -C "$tmp/seed" push -q origin local/tabby-cwd
git clone -q "$tmp/fork.git" "$REPO"
( ensure_remotes )
[[ "$(git -C "$REPO" remote get-url origin)" == "https://github.com/unitea1992/herdr.git" ]] || fail "origin not fork URL"
[[ "$(git -C "$REPO" remote get-url upstream)" == "https://github.com/herdrdev/herdr.git" ]] || fail "upstream not set"
ok "remotes guaranteed (origin=unitea1992/herdr, upstream=herdrdev/herdr)"

ensure_branch
[[ "$(git -C "$REPO" branch --show-current)" == "local/tabby-cwd" ]] || fail "branch not local/tabby-cwd"
ensure_branch
ok "branch checkout + idempotent re-run"

# --- version format ------------------------------------------------------------
up="$(check_version_format "herdr 0.8.0+tabbycwd.abcdef12" "abcdef12")" || fail "valid version rejected"
[[ "$up" == "0.8.0" ]] || fail "upstream version parse wrong (got: $up)"
if check_version_format "herdr 0.8.0+tabbycwd.1234567" "abcdef12" >/dev/null; then
    fail "sha mismatch accepted"
fi
if check_version_format "herdr 0.8.0" "abcdef12" >/dev/null; then
    fail "version without +tabbycwd metadata accepted"
fi
ok "version format (herdr <ver>+tabbycwd.<sha>) checks"

echo
echo "all installer/updater tests passed"
