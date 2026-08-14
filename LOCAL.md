# LOCAL — personal fork operations

This repository is a personal fork of `herdrdev/herdr`
(<https://github.com/herdrdev/herdr>). It tracks upstream while carrying one
local patch. The upstream `README.md` is intentionally left unmodified.

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

### Build requirement

- Zig 0.15.2 must be resolvable from `PATH` (vendored libghostty-vt).

## Update flow

Normal update: run `~/.local/bin/update-herdr`. The script performs:

1. Aborts unless the working tree is clean and the current branch is
   `local/tabby-cwd`.
2. Fetches `upstream` and `origin`.
3. Rebases `local/tabby-cwd` onto `upstream/master`.
4. On success, force-pushes to origin with `--force-with-lease`.
5. Builds `cargo build --release` and, only on success, installs
   `target/release/herdr` to `~/.local/bin/herdr`.
6. Reports upstream before/after and local HEAD. It never stops or restarts a
   running herdr server; restart it at a convenient time.

Check mode: `update-herdr --check` runs `just check` instead of installing.

## Conflict policy

- Rebase conflicts are never auto-resolved. The script stops on conflict and
  lists the conflicted files; resolve manually, then `git rebase --continue`.
- Force pushes always use `--force-with-lease`.

## Why not `herdr update`

`herdr update` replaces the installed binary from the official channel and
would drop this fork's local patch (it is not in any released build). This
fork is updated exclusively through `update-herdr`.
