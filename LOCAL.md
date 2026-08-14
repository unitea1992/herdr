# LOCAL — personal fork operations

This repository is a personal fork of `herdrdev/herdr`
(<https://github.com/herdrdev/herdr>) and is **Linux-only**: the installer,
updater, and check mode never use Windows/macOS targets, PowerShell, or
`just`. The upstream `README.md` is intentionally left unmodified.

## Remotes

- `origin`   → <https://github.com/unitea1992/herdr.git>
- `upstream` → <https://github.com/herdrdev/herdr.git>

## Local patch branch

- Branch: `local/tabby-cwd` — the only branch carrying local work.

### What the patch does

`feat: forward focused pane cwd to host terminal` forwards the focused pane's
working directory to the host terminal using the iTerm2/Tabby
`OSC 1337;CurrentDir=...` convention, so Tabby's SFTP panel follows the active
pane's cwd.

Behavior:

- Emits `OSC 1337;CurrentDir=<path>` whenever the focused pane's known cwd
  changes (live OSC 7 report first, then process cwd).
- Background pane cwd changes are never forwarded — only the focused pane's
  cwd is emitted.
- When pane focus moves, the new focused pane's known cwd is re-sent.
- The path is sent as raw UTF-8: Tabby consumes `CurrentDir` without
  percent-decoding, so percent-encoding would corrupt paths containing `%`.
  Only OSC-breaking control characters (ESC, BEL, ST) are stripped.

## Dependencies

- **Zig 0.15.2 fixed** (vendored libghostty-vt). Never auto-upgraded. A
  different zig version elsewhere on PATH is left untouched; builds pin the
  exact one via `ZIG=<path>` (PATH zig first, then `$HOME/.local/bin/zig`).
- Rust CLIs are managed with **cargo-binstall** (user space, no sudo/apt):
  `cargo-binstall` itself and `cargo-nextest` (only needed for
  `update-herdr --check`).
- `just` is not used by the installer or `--check`, so a stale apt `just` on
  PATH is irrelevant.

## One-line install (new Linux machine)

    curl -fsSL https://raw.githubusercontent.com/unitea1992/herdr/local/tabby-cwd/install-tabbycwd.sh | bash

Overrides:

- `HERDR_LOCAL_REPO` — repo checkout path (default `$HOME/projects/herdr`)
- `HERDR_LOCAL_BIN` — binary dir (default `$HOME/.local/bin`)

The installer is idempotent (safe to re-run) and refuses to touch a dirty
checkout. It installs rustup/cargo-binstall/cargo-nextest/Zig 0.15.2 only when
missing, clones the fork, sets remotes, checks out `local/tabby-cwd`, rebases
onto `upstream/master` when behind (never auto-resolving conflicts), builds
with custom version metadata, and installs both the binary and
`scripts/update-herdr`. `.bashrc` edits (PATH entry + `herdr()` update guard)
are marker-guarded and never duplicated.

## Update flow

`update-herdr` (source of truth: `scripts/update-herdr`, installed to
`$BIN_DIR/update-herdr`):

1. Preflight: aborts unless the working tree is clean, the current branch is
   `local/tabby-cwd`, and `origin`/`upstream` remotes exist.
2. Fetches `upstream` and `origin`.
3. Rebases `local/tabby-cwd` onto `upstream/master`.
4. On success, force-pushes to origin with `--force-with-lease`.
5. Builds `cargo build --release --locked` and, only on success, installs
   `target/release/herdr` to `$BIN_DIR/herdr`.
6. Reports upstream before/after and local HEAD. It never stops or restarts a
   running herdr server; restart it at a convenient time.

Variants:

- `update-herdr --check` — same fetch/rebase/push, then Linux-native checks
  (dependency preflight, `cargo fmt --check`, `cargo clippy --all-targets
  --locked -- -D warnings`, `cargo nextest run --locked ...`, `cargo build
  --release --locked`) **without installing**. Never adds the
  `x86_64-pc-windows-msvc` target or runs Windows/macOS lint. Missing
  dependencies fail with the install command instead of auto-installing.
- `update-herdr --clean` — `cargo clean` before the normal update/build. Use
  after repo moves when stale cache paths break the vendored zig build
  (`cannot find -lghostty-vt`). Normal updates do not clean.

## Custom version

Fork builds report `herdr <upstream-version>+tabbycwd.<short-sha>`:

- `<upstream-version>` follows upstream's `Cargo.toml` version automatically;
  it is never hand-edited in this fork.
- `tabbycwd` is the fixed build channel for this fork.
- `<short-sha>` is the current `local/tabby-cwd` HEAD short SHA, injected at
  build time.

It reuses Herdr's existing build metadata mechanism: builds run with

    HERDR_BUILD_CHANNEL=tabbycwd HERDR_BUILD_ID="$(git rev-parse --short HEAD)" cargo build --release --locked

so `herdr --version` always shows the exact commit being run. Stable and
preview channel output is unchanged.

## `herdr update` guard

The installed `$BIN_DIR/herdr` is a fork build and must not be replaced by the
official updater. `~/.bashrc` defines a `herdr` shell function that blocks
`herdr update`, prints

    Custom Herdr build detected.
    Use: update-herdr

and exits non-zero. All other invocations (`herdr`, `herdr agent ...`,
`herdr server ...`, `herdr --version`) call the real binary via `command herdr`
(no recursion).

## Why not `herdr update`

`herdr update` replaces the installed binary from the official channel and
would drop this fork's local patch (it is not in any released build). This
fork is updated exclusively through `update-herdr`.

## Conflict policy

- Rebase conflicts are never auto-resolved. `update-herdr` stops on conflict
  and lists the conflicted files; resolve manually, then
  `git rebase --continue`. The installer aborts the rebase (it only bootstraps;
  resolve and re-run `update-herdr`).
- Force pushes always use `--force-with-lease`.
