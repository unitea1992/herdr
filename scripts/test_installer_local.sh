#!/usr/bin/env bash
# Local tests for the personal fork installer/updater. Runs against an
# isolated HOME and a local bare git repo standing in for the public fork;
# fakes cargo/rust/zig so nothing touches the real toolchain or network.
# Run with: bash scripts/test_installer_local.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/install-tabbycwd.sh"
UPDATER="$REPO_ROOT/scripts/update-herdr"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- static checks -----------------------------------------------------------
for f in "$INSTALLER" "$UPDATER"; do
    grep -n '/home/helios' "$f" && fail "$f hardcodes /home/helios"
    grep -inE 'windows|msvc|powershell|darwin|macos' "$f" | grep -vE '^[0-9]+:#' && fail "$f references cross-platform tooling"
done
ok "no /home/helios hardcode; no windows/macos/ps1 references"

grep -q 'nextest run' "$UPDATER" || fail "update-herdr --check missing nextest"
grep -q 'HERDR_LOCAL_BIN' "$INSTALLER" || fail "installer missing HERDR_LOCAL_BIN"
grep -q '0.15.2' "$INSTALLER" || fail "installer zig not pinned to 0.15.2"
grep -q '0.15.2' "$UPDATER" || fail "updater zig not pinned to 0.15.2"

for f in "$INSTALLER" "$UPDATER"; do
    grep -qE 'git push|force-with-lease' "$f" && fail "$f must not push (GitHub auth)"
    grep -qE 'git rebase|git fetch|fetch upstream|remote.*upstream' "$f" && fail "$f must not fetch/rebase/upstream"
    grep -q 'HERDR_LOCAL_REPO' "$f" && fail "$f must not reference HERDR_LOCAL_REPO (no persistent repo)"
    grep -qE 'git clone --depth=1 --branch' "$f" || fail "$f must shallow-clone the branch"
    grep -q 'local/tabby-cwd' "$f" || fail "$f missing branch local/tabby-cwd"
    grep -q 'CARGO_TARGET_DIR' "$f" || fail "$f missing shared cargo target dir"
    grep -q 'mktemp -d' "$f" || fail "$f missing throwaway temp dir"
    grep -q 'trap.*EXIT' "$f" || fail "$f missing cleanup trap"
done
ok "no push/rebase/upstream/fetch/persistent-repo in installer+updater"

grep -qE 'install -Dm755 .*update-herdr' "$INSTALLER" || fail "installer must deploy update-herdr"
grep -qE 'install -Dm755 .*update-herdr' "$UPDATER" || fail "updater must self-update"
grep -qE -- '--clean|clean_mode|cargo clean' "$UPDATER" && fail "update-herdr must not keep --clean"
ok "installer deploys updater; updater self-updates; --clean removed"

# --- isolated environment ----------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fakebin="$tmp/fakebin"
mkdir -p "$fakebin"

cat > "$fakebin/cargo" <<'EOF'
#!/bin/bash
case "${1:-}" in
    --version) exit 0 ;;
    fmt)
        [[ "${2:-}" == "--version" ]] && exit 0
        [[ -n "${ZIG:-}" ]] || { echo "fake: ZIG unset for fmt --check" >&2; exit 1; }
        exit 0
        ;;
    clippy)
        [[ "${2:-}" == "--version" ]] && exit 0
        [[ -n "${ZIG:-}" ]] || { echo "fake: ZIG unset for clippy" >&2; exit 1; }
        exit 0
        ;;
    nextest)
        [[ -n "${ZIG:-}" ]] || { echo "fake: ZIG unset for nextest" >&2; exit 1; }
        exit 0
        ;;
    build)
        [[ -n "${ZIG:-}" ]] || { echo "fake: ZIG unset for build" >&2; exit 1; }
        if [[ "${FAKE_BUILD_FAIL:-0}" == "1" ]]; then
            echo "error: fake build failure" >&2
            exit 1
        fi
        sha="$(git rev-parse --short HEAD 2>/dev/null || echo deadbeef)"
        mkdir -p "${CARGO_TARGET_DIR:-$HOME/.cache/herdr/target}/release"
        printf '#!/bin/bash\necho "herdr 0.9.9+tabbycwd.%s"\n' "$sha" \
            > "${CARGO_TARGET_DIR:-$HOME/.cache/herdr/target}/release/herdr"
        chmod +x "${CARGO_TARGET_DIR:-$HOME/.cache/herdr/target}/release/herdr"
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$fakebin/cargo"
for c in rustc cargo-binstall cargo-nextest curl; do
    printf '#!/bin/bash\nexit 0\n' > "$fakebin/$c"
    chmod +x "$fakebin/$c"
done

# Local bare repo stands in for the public fork (same shallow-clone shape).
fork="$tmp/fork.git"
git init -q --bare "$fork"
git -C "$fork" symbolic-ref HEAD refs/heads/local/tabby-cwd
git clone -q "$fork" "$tmp/seed" 2>/dev/null
git -C "$tmp/seed" config user.email t@t
git -C "$tmp/seed" config user.name t
mkdir -p "$tmp/seed/scripts"
printf '#!/bin/bash\necho "fake update-herdr v1"\n' > "$tmp/seed/scripts/update-herdr"
chmod +x "$tmp/seed/scripts/update-herdr"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" commit -q -m seed
git -C "$tmp/seed" push -q origin local/tabby-cwd
sha1="$(git -C "$tmp/seed" rev-parse --short HEAD)"

# Integration HOME: throwaway clones go under $work (via TMPDIR); the managed
# zig complete tree is pre-created so no download happens.
home="$tmp/home"
mkdir -p "$home"
work="$tmp/work"
mkdir -p "$work"
mkdir -p "$home/.local/share/herdr/zig-0.15.2/lib"
printf '#!/bin/bash\n[[ "${1:-}" == version ]] && echo 0.15.2\nexit 0\n' \
    > "$home/.local/share/herdr/zig-0.15.2/zig"
chmod +x "$home/.local/share/herdr/zig-0.15.2/zig"

# Run the full installer/updater main() in an isolated subshell, sourcing the
# script so FORK_URL can point at the local bare repo (no network).
run_installer() { # $1 = optional extra env (e.g. FAKE_BUILD_FAIL=1)
    (
        export HOME="$home" HERDR_LOCAL_BIN="$home/.local/bin" TMPDIR="$work"
        export PATH="$fakebin:$PATH"
        source "$INSTALLER"
        FORK_URL="$fork"
        [[ -n "${1:-}" ]] && export "$1"
        main
    )
}
run_updater() { # $@ = updater flags (e.g. --check); parsed by the sourced script
    (
        export HOME="$home" HERDR_LOCAL_BIN="$home/.local/bin" TMPDIR="$work"
        export PATH="$fakebin:$PATH"
        source "$UPDATER"
        FORK_URL="$fork"
        main
    )
}

# Run the installer/updater and assert its exit status. The set +e / rc dance
# is required: calling main() from an `if`/`||` condition suppresses `set -e`
# inside the sourced script (which would swallow build failures). As a plain
# statement, the sourced script's own `set -e` stays in force and a failure
# propagates to $rc.
expect_rc() { # $1 = expected 0/1, $2 = log file, $3.. = command to run
    local want="$1" log="$2"; shift 2
    set +e
    "$@" >"$log" 2>&1
    local rc=$?
    set -e
    [[ "$rc" == "$want" ]] || { cat "$log"; fail "expected exit $want, got $rc: $*"; }
}

# --- linux-only guard --------------------------------------------------------
fb="$tmp/fakeuname"; mkdir -p "$fb"
printf '#!/bin/bash\necho Darwin\n' > "$fb/uname"; chmod +x "$fb/uname"
if ( export PATH="$fb"; source "$INSTALLER"; require_linux ) >/dev/null 2>&1; then
    fail "require_linux accepted a non-Linux uname"
fi
ok "require_linux rejects non-Linux"

# --- zig: complete-tree resolution (never a bare binary, never ~/.local/bin) --
got="$( ( export HOME="$home"; source "$UPDATER"; resolve_zig ) )" || fail "resolve_zig failed"
[[ "$got" == "$home/.local/share/herdr/zig-0.15.2/zig" ]] || fail "resolve_zig did not prefer managed tree (got: $got)"

got="$( ( export HOME="$home"; source "$INSTALLER"; ensure_zig >/dev/null; echo "$ZIG" ) )" || fail "ensure_zig failed"
[[ "$got" == "$home/.local/share/herdr/zig-0.15.2/zig" ]] || fail "ensure_zig did not pick managed tree (got: $got)"

zh="$tmp/zighome"; mkdir -p "$zh/.local/bin"
printf '#!/bin/bash\necho 0.15.2\n' > "$zh/.local/bin/zig"; chmod +x "$zh/.local/bin/zig"
if out="$( ( export HOME="$zh" PATH="$zh/.local/bin:/usr/bin:/bin"; source "$UPDATER"; resolve_zig ) 2>&1 )"; then
    fail "resolve_zig succeeded with only a bare ~/.local/bin/zig"
fi
echo "$out" | grep -q 'zig 0.15.2' || fail "missing-zig error message"
[[ -f "$zh/.local/bin/zig" ]] || fail "bare ~/.local/bin/zig was deleted"
ok "complete-tree zig resolution; bare ~/.local/bin/zig ignored and preserved"

# --- dependency preflight (updater) ------------------------------------------
mkdir -p "$tmp/emptybin" "$tmp/shim"
printf '#!/bin/bash\nexit 0\n' > "$tmp/shim/cargo"
printf '#!/bin/bash\nexit 0\n' > "$tmp/shim/rustc"
chmod +x "$tmp/shim/cargo" "$tmp/shim/rustc"

if out="$( ( export PATH="$tmp/emptybin"; export HOME="$home"; source "$UPDATER"; preflight_build_deps ) 2>&1 )"; then
    fail "preflight_build_deps passed without cargo"
fi
echo "$out" | grep -q "required command 'cargo'" || fail "missing-cargo error"
ok "missing cargo errors clearly"

if out="$( ( export PATH="$tmp/shim:/usr/bin:/bin"; export HOME="$home"; source "$UPDATER"; preflight_check_deps ) 2>&1 )"; then
    fail "preflight_check_deps passed without cargo-nextest"
fi
echo "$out" | grep -q 'cargo-nextest' || fail "missing nextest error"
echo "$out" | grep -q 'cargo binstall cargo-nextest --no-confirm' || fail "missing binstall hint"
ok "missing cargo-nextest errors with binstall hint"

# --- .bashrc edits are marker-guarded and idempotent -------------------------
bh="$tmp/bhome"; mkdir -p "$bh"
( export HOME="$bh" PATH="/usr/bin:/bin"; source "$INSTALLER"; ensure_bashrc_path; ensure_bashrc_path )
count=$(grep -c 'herdr: local bin PATH' "$bh/.bashrc" || true)
[[ "$count" == "1" ]] || fail "PATH marker duplicated ($count)"
ok ".bashrc PATH append idempotent"

( export HOME="$bh" PATH="/usr/bin:/bin"; source "$INSTALLER"; ensure_bashrc_guard; ensure_bashrc_guard )
count=$(grep -c '^herdr()' "$bh/.bashrc" || true)
[[ "$count" == "1" ]] || fail "herdr() guard duplicated ($count)"
grep -q 'Custom Herdr build detected' "$bh/.bashrc" || fail "guard body missing"
grep -q 'command herdr "\$@"' "$bh/.bashrc" || fail "guard does not forward via command herdr"
ok ".bashrc herdr() guard appended exactly once"

rm -f "$bh/.bashrc"
printf 'herdr() { echo user-defined; }\n' > "$bh/.bashrc"
( export HOME="$bh" PATH="/usr/bin:/bin"; source "$INSTALLER"; ensure_bashrc_guard )
count=$(grep -c '^herdr()' "$bh/.bashrc" || true)
[[ "$count" == "1" ]] || fail "user-defined herdr() duplicated"
ok "existing user herdr() left untouched"

# --- execution guard: source vs stdin vs direct -------------------------------
export HERDR_LOCAL_TEST=1
out="$(cat "$INSTALLER" | bash 2>&1)" || fail "stdin-executed installer crashed"
echo "$out" | grep -q 'main() reached (test)' || fail "installer via stdin did not reach main()"
unset HERDR_LOCAL_TEST
ok "stdin (curl ... | bash) reaches main() under set -u"

out="$(env HERDR_LOCAL_TEST=1 bash "$INSTALLER" 2>&1)" || fail "direct-executed installer crashed"
echo "$out" | grep -q 'main() reached (test)' || fail "installer run as script did not reach main()"
ok "bash install-tabbycwd.sh reaches main() under set -u"

out="$(env HERDR_LOCAL_TEST=1 bash -c 'source "$1"' _ "$INSTALLER" 2>&1)" || fail "sourced installer crashed"
echo "$out" | grep -q 'main() reached (test)' && fail "sourced installer ran main()"
ok "source install-tabbycwd.sh does not invoke main()"

# --- version format ------------------------------------------------------------
up="$( ( source "$INSTALLER"; check_version_format "herdr 0.8.0+tabbycwd.abcdef12" "abcdef12" ) )" || fail "valid version rejected"
[[ "$up" == "0.8.0" ]] || fail "upstream version parse wrong (got: $up)"
if ( source "$INSTALLER"; check_version_format "herdr 0.8.0+tabbycwd.1234567" "abcdef12" ) >/dev/null; then
    fail "sha mismatch accepted"
fi
if ( source "$INSTALLER"; check_version_format "herdr 0.8.0" "abcdef12" ) >/dev/null; then
    fail "version without +tabbycwd metadata accepted"
fi
ok "version format (herdr <ver>+tabbycwd.<sha>) checks"

# --- installer integration: fresh install ------------------------------------
expect_rc 0 "$tmp/install.log" run_installer
[[ -x "$home/.local/bin/herdr" ]] || fail "herdr binary not installed"
ver="$("$home/.local/bin/herdr" --version)"
[[ "$ver" == "herdr 0.9.9+tabbycwd.$sha1" ]] || fail "wrong version (got: $ver, want sha $sha1)"
[[ -f "$home/.local/bin/update-herdr" ]] || fail "update-herdr not installed"
grep -q 'fake update-herdr v1' "$home/.local/bin/update-herdr" || fail "installed update-herdr wrong content"
[[ ! -e "$home/projects/herdr" ]] || fail "installer created a persistent repo"
[[ -z "$(ls -A "$work" 2>/dev/null)" ]] || fail "throwaway clone not cleaned up"
[[ $(grep -c 'herdr: local bin PATH' "$home/.bashrc" || true) == "1" ]] || fail "PATH marker duplicated"
[[ $(grep -c '^herdr()' "$home/.bashrc" || true) == "1" ]] || fail "guard duplicated"
ok "installer: build+install, no persistent repo, clone cleaned, version verified"

# --- installer re-run idempotent ----------------------------------------------
expect_rc 0 "$tmp/install2.log" run_installer
[[ -x "$home/.local/bin/herdr" ]] || fail "binary lost on re-run"
[[ $(grep -c 'herdr: local bin PATH' "$home/.bashrc" || true) == "1" ]] || fail "PATH marker duplicated on re-run"
[[ $(grep -c '^herdr()' "$home/.bashrc" || true) == "1" ]] || fail "guard duplicated on re-run"
ok "installer re-run idempotent"

# --- installer build failure: no clobber, cleanup, cache cleared --------------
before="$(cat "$home/.local/bin/herdr")"
expect_rc 1 "$tmp/fail.log" run_installer FAKE_BUILD_FAIL=1
[[ "$(cat "$home/.local/bin/herdr")" == "$before" ]] || fail "failed build clobbered installed binary"
[[ -z "$(ls -A "$work" 2>/dev/null)" ]] || fail "throwaway clone not cleaned up after failure"
[[ ! -e "$home/.cache/herdr/target" ]] || fail "cache not cleared by retry after failure"
ok "installer build failure: binary preserved, clone cleaned, cache cleared"

# --- updater: normal run updates herdr + self-updates -------------------------
printf '#!/bin/bash\necho "fake update-herdr v2"\n' > "$tmp/seed/scripts/update-herdr"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" commit -q -m advance
git -C "$tmp/seed" push -q origin local/tabby-cwd
sha2="$(git -C "$tmp/seed" rev-parse --short HEAD)"

printf '#!/bin/bash\necho "stale herdr"\n' > "$home/.local/bin/herdr"
printf '#!/bin/bash\necho "stale updater"\n' > "$home/.local/bin/update-herdr"
chmod +x "$home/.local/bin/herdr" "$home/.local/bin/update-herdr"

expect_rc 0 "$tmp/upd.log" run_updater
[[ "$("$home/.local/bin/herdr" --version)" == "herdr 0.9.9+tabbycwd.$sha2" ]] || fail "updater did not update herdr (sha $sha2)"
grep -q 'fake update-herdr v2' "$home/.local/bin/update-herdr" || fail "updater did not self-update"
[[ ! -e "$home/projects/herdr" ]] || fail "updater created a persistent repo"
[[ -z "$(ls -A "$work" 2>/dev/null)" ]] || fail "updater throwaway clone not cleaned up"
ok "updater: updates herdr + self-updates, no persistent repo, clone cleaned"

# --- updater --check: installed binaries untouched ----------------------------
before="$(cat "$home/.local/bin/herdr")"
before_upd="$(cat "$home/.local/bin/update-herdr")"
expect_rc 0 "$tmp/chk.log" run_updater --check
[[ "$(cat "$home/.local/bin/herdr")" == "$before" ]] || fail "--check modified installed herdr"
[[ "$(cat "$home/.local/bin/update-herdr")" == "$before_upd" ]] || fail "--check modified installed update-herdr"
[[ -z "$(ls -A "$work" 2>/dev/null)" ]] || fail "--check throwaway clone not cleaned up"
ok "updater --check: installed binaries untouched, clone cleaned"

# --- pre-existing ~/projects/herdr is never touched ---------------------------
mkdir -p "$home/projects/herdr"
echo "precious" > "$home/projects/herdr/keep.txt"
expect_rc 0 "$tmp/install3.log" run_installer
[[ "$(cat "$home/projects/herdr/keep.txt")" == "precious" ]] || fail "installer touched ~/projects/herdr"
ok "pre-existing ~/projects/herdr left untouched"

echo
echo "all installer/updater tests passed"
