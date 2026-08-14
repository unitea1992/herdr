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
grep -qE 'force-with-lease|git push' "$UPDATER" && fail "update-herdr must not push (GitHub auth)"
grep -qE 'git fetch upstream|upstream/master|force-with-lease' "$UPDATER" && fail "update-herdr must not reference upstream/rebase/push"
grep -q 'follow_origin' "$UPDATER" || fail "update-herdr missing follow_origin fast-forward logic"
grep -qE 'git fetch upstream|git rebase|ensure_rebased|git push|force-with-lease' "$INSTALLER" && fail "installer must not fetch upstream/rebase/push"
grep -q 'follow_origin' "$INSTALLER" || fail "installer missing follow_origin fast-forward logic"
grep -qE 'install -Dm755 scripts/update-herdr' "$INSTALLER" || fail "installer must redeploy scripts/update-herdr to \$BIN_DIR"
ok "static checks (no push/upstream in installer+updater)"

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

make_zig() { # $1=version $2=path; bare binary, no lib/ (old broken installer output)
    mkdir -p "$(dirname "$2")"
    printf '#!/bin/bash\nif [[ "${1:-}" == "version" ]]; then echo "%s"; fi\n' "$1" > "$2"
    chmod +x "$2"
}
make_zig_tree() { # $1=version $2=bin-path; complete layout: zig + sibling lib/
    make_zig "$1" "$2"
    mkdir -p "$(dirname "$2")/lib"
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

# --- zig: complete-tree layout (installer + updater) -------------------------
# Resolution never depends on $HOME/.local/bin/zig, other PATH zigs are left
# untouched, and the tarball fixture installs as a complete tree.
ZIG_ROOT="$HOME/.local/share/herdr/zig-$ZIG_VERSION"

# A complete 0.15.2 on PATH is reused, nothing installed.
zigpath="$tmp/zigpath"
mkdir -p "$zigpath"
make_zig_tree 0.15.2 "$zigpath/zig"
got="$(PATH="$zigpath" resolve_zig)"
[[ "$got" == "zig" ]] || fail "resolve_zig did not pick complete PATH zig (got: $got)"
PATH="$zigpath" ensure_zig
[[ "${ZIG_BIN:-}" == "zig" ]] || fail "ensure_zig did not set ZIG_BIN=zig"
ok "complete zig 0.15.2 on PATH re-used"

# Wrong-version PATH zig untouched; managed tree preferred (also covers the
# old broken ~/.local/bin/zig from the previous installer layout).
managedbin="$ZIG_ROOT/zig"
make_zig_tree 0.15.2 "$managedbin"
make_zig 0.14.0 "$zigpath/zig"
make_zig 0.15.2 "$HOME/.local/bin/zig"   # old broken standalone, no lib/
got="$(PATH="$zigpath" resolve_zig)"
[[ "$got" == "$managedbin" ]] || fail "resolve_zig did not prefer managed tree (got: $got)"
PATH="$zigpath" ensure_zig
[[ "${ZIG_BIN:-}" == "$managedbin" ]] || fail "ensure_zig did not prefer managed tree"
ok "managed complete tree preferred; PATH other-zig untouched"

# Missing managed tree + bare old-standalone on PATH -> clean error, never
# deletes the file (could be anyone's zig).
rm -rf "$ZIG_ROOT"
if out="$(PATH="$zigpath" resolve_zig 2>&1)"; then
    fail "resolve_zig succeeded with no complete zig available"
fi
echo "$out" | grep -q 'zig 0.15.2' || fail "missing zig error message"
[[ -f "$HOME/.local/bin/zig" ]] || fail "old broken ~/.local/bin/zig was deleted"
ok "no complete zig: errors, never uses/deletes ~/.local/bin/zig"

# Full install path: tarball fixture (zig + lib/) becomes the complete tree,
# and installer re-run is idempotent. curl is stubbed to serve the fixture.
if command -v xz >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    arch="$(uname -m)"
    extracted="zig-$arch-linux-$ZIG_VERSION"
    fixture_root="$tmp/fixture"
    mkdir -p "$fixture_root/$extracted/lib"
    printf '#!/bin/bash\nif [[ "${1:-}" == "version" ]]; then echo "%s"; fi\n' "$ZIG_VERSION" > "$fixture_root/$extracted/zig"
    chmod +x "$fixture_root/$extracted/zig"
    fixture_tarball="$tmp/zig.tar.xz"
    (cd "$fixture_root" && tar -cJf "$fixture_tarball" "$extracted")

    fakecurl="$tmp/fakecurl"
    mkdir -p "$fakecurl"
    printf '%s\n' \
        '#!/bin/bash' \
        '# fake curl: copy the fixture tarball to the -o target; URL irrelevant.' \
        'prev=' \
        'for arg in "$@"; do' \
        '    if [[ "$prev" == "-o" ]]; then target="$arg"; fi' \
        '    prev="$arg"' \
        'done' \
        'cp "$TEST_TARBALL" "$target"' \
        > "$fakecurl/curl"
    chmod +x "$fakecurl/curl"
    export TEST_TARBALL="$fixture_tarball"

    rm -f "$HOME/.local/bin/zig"   # clear the leftover from the case above
    PATH="$fakecurl:/usr/bin:/bin" ensure_zig
    [[ "${ZIG_BIN:-}" == "$ZIG_ROOT/zig" ]] || fail "ZIG_BIN not inside complete tree (got: ${ZIG_BIN:-})"
    [[ -x "$ZIG_ROOT/zig" ]] || fail "managed zig binary missing after install"
    [[ -d "$ZIG_ROOT/lib" ]] || fail "managed lib/ missing after install"
    [[ ! -e "$HOME/.local/bin/zig" ]] || fail "installer must not touch ~/.local/bin"
    ok "tarball fixture installed as complete tree (zig + lib/) at $ZIG_ROOT"

    PATH="$fakecurl:/usr/bin:/bin" ensure_zig   # re-run
    [[ "${ZIG_BIN:-}" == "$ZIG_ROOT/zig" ]] || fail "re-run changed ZIG_BIN"
    [[ -x "$ZIG_ROOT/zig" && -d "$ZIG_ROOT/lib" ]] || fail "complete tree lost on re-run"
    ok "installer re-run idempotent (complete tree kept)"
else
    ok "xz/tar absent — full-tree fixture test skipped"
fi

# --- dependency preflight (updater, report-only) -----------------------------
shim="$tmp/shim"
mkdir -p "$shim" "$tmp/emptybin"
printf '#!/bin/bash\necho "cargo 1.85.0 (fake)"\n' > "$shim/cargo"
printf '#!/bin/bash\necho "rustc 1.85.0 (fake)"\n' > "$shim/rustc"
make_zig_tree 0.15.2 "$shim/zig"
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
if git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
    fail "installer created unnecessary upstream remote"
fi
ok "install: origin=fork URL, upstream not created"

# An existing upstream remote is left untouched (still useful on a dev machine).
git -C "$REPO" remote add upstream "https://github.com/herdrdev/herdr.git"
( ensure_remotes )
[[ "$(git -C "$REPO" remote get-url upstream)" == "https://github.com/herdrdev/herdr.git" ]] || fail "existing upstream remote changed/deleted"
ok "existing upstream remote left untouched"

ensure_branch
[[ "$(git -C "$REPO" branch --show-current)" == "local/tabby-cwd" ]] || fail "branch not local/tabby-cwd"
ensure_branch
ok "branch checkout + idempotent re-run"

# --- update-herdr follow-origin (fast-forward only, no push) -----------------
# ensure_branch above cd'd into $REPO, so get back to a stable cwd before the
# re-clone deletes it (a deleted cwd makes the next git clone fail).
cd "$REPO_ROOT"
# Fresh clone so origin still points at the local bare fork (path, no auth; a
# real user machine likewise only fetches the public fork).
rm -rf "$REPO"
git clone -q "$tmp/fork.git" "$REPO"
git -C "$REPO" checkout -q local/tabby-cwd

# already up to date -> follow_origin succeeds, HEAD does not move.
head_before="$(git -C "$REPO" rev-parse HEAD)"
( cd "$REPO" && follow_origin ) >/dev/null
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$head_before" ]] || fail "follow_origin moved HEAD when already latest"
ok "update: already latest -> proceeds, HEAD unchanged"

# origin updated -> fast-forward follows, local commit kept.
git -C "$tmp/seed" checkout -q local/tabby-cwd
git -C "$tmp/seed" commit -q --allow-empty -m "origin advance"
git -C "$tmp/seed" push -q origin local/tabby-cwd
( cd "$REPO" && git fetch origin -q && follow_origin ) >/dev/null
[[ "$(git -C "$REPO" rev-parse --short HEAD)" == "$(git -C "$REPO" rev-parse --short "origin/local/tabby-cwd")" ]] || fail "fast-forward did not follow origin"
ok "update: origin ahead -> fast-forward follows origin"

# diverged -> explicit refusal, local commit intact.
git -C "$REPO" commit -q --allow-empty -m "local diverge"
head_diverge="$(git -C "$REPO" rev-parse HEAD)"
if out="$(cd "$REPO" && follow_origin 2>&1)"; then
    fail "follow_origin accepted a diverged branch"
fi
echo "$out" | grep -qi diverge || fail "diverged error lacks the word diverge"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$head_diverge" ]] || fail "diverged branch lost its local commit"
ok "update: diverged -> explicit error, no destruction"

# dirty tree -> update-herdr stops before fetch/build (exit 1, no push).
rm -rf "$REPO"; git init -q "$REPO"
git -C "$REPO" remote add origin "https://github.com/unitea1992/herdr.git"
git -C "$REPO" checkout -q -b local/tabby-cwd
printf 'user file\n' > "$REPO/user.txt"
if out="$(bash "$UPDATER" 2>&1)"; then
    fail "update-herdr accepted a dirty tree"
fi
echo "$out" | grep -q 'dirty' || fail "dirty message missing"
[[ -f "$REPO/user.txt" ]] || fail "dirty file was destroyed"
ok "update: dirty tree rejected before any fetch/build"

# --- installer origin-follow (same model as update-herdr) ----------------------
cd "$REPO_ROOT"
# Fresh clone = first install; repo already tracks origin/local/tabby-cwd.
rm -rf "$REPO"
git clone -q "$tmp/fork.git" "$REPO"
git -C "$REPO" checkout -q local/tabby-cwd
( cd "$REPO" && git fetch origin -q && ensure_branch && follow_origin ) >/dev/null
[[ "$(git -C "$REPO" rev-parse --short HEAD)" == "$(git -C "$REPO" rev-parse --short origin/local/tabby-cwd)" ]] || fail "fresh clone not on origin/local/tabby-cwd"
ok "install: fresh clone tracks origin/local/tabby-cwd"

FORK_URL="$tmp/fork.git"   # keep ensure_remotes' origin off the real network
install_flow() { cd "$REPO" && ensure_repo && ensure_remotes && git fetch origin -q && ensure_branch && follow_origin; }

# origin updated -> installer re-run fast-forwards.
git -C "$tmp/seed" checkout -q local/tabby-cwd
git -C "$tmp/seed" commit -q --allow-empty -m "installer ff"
git -C "$tmp/seed" push -q origin local/tabby-cwd
( install_flow ) >/dev/null
[[ "$(git -C "$REPO" rev-parse --short HEAD)" == "$(git -C "$REPO" rev-parse --short origin/local/tabby-cwd)" ]] || fail "installer re-run did not fast-forward"
[[ "$(git -C "$REPO" remote get-url origin)" == "$FORK_URL" ]] || fail "ensure_remotes did not point origin at fork URL"
ok "install: existing repo behind -> installer re-run fast-forwards"

# Up to date now.
head_before="$(git -C "$REPO" rev-parse HEAD)"
( install_flow ) >/dev/null
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$head_before" ]] || fail "installer re-run moved HEAD when already latest"
ok "install: already latest -> proceeds, HEAD unchanged"

# diverged -> installer refuses without destroying local commits.
git -C "$tmp/seed" checkout -q local/tabby-cwd
git -C "$tmp/seed" commit -q --allow-empty -m "origin diverge"
git -C "$tmp/seed" push -q origin local/tabby-cwd
( cd "$REPO" && git fetch origin -q )
git -C "$REPO" commit -q --allow-empty -m "local diverge"
head_diverge="$(git -C "$REPO" rev-parse HEAD)"
if out="$(install_flow 2>&1)"; then
    fail "installer accepted a diverged branch"
fi
echo "$out" | grep -qi diverge || fail "installer diverged error lacks the word diverge"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$head_diverge" ]] || fail "installer diverge path lost local commit"
ok "install: diverged -> explicit error, no destruction"

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
