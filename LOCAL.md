# LOCAL — 個人フォーク運用

このリポジトリは `herdrdev/herdr`
(<https://github.com/herdrdev/herdr>) の個人フォークで、**Linux専用**です:
インストーラ、アップデータ、チェックモードは Windows/macOS ターゲット、
PowerShell、`just` を一切使いません。上流の `README.md` は意図的に
変更していません。

## 開発マシンと利用マシンの区別

- **開発/保守マシン**だけがこのリポジトリの永続チェックアウトを持ちます。
  `upstream` の追従・rebase・`origin` への push は開発マシンだけで行い、
  `origin/local/tabby-cwd` が常に配布用の最新状態です。
- **利用マシン**は GitHub 上の完成済み `local/tabby-cwd` を使うだけです。
  source repo を永続 clone しません。インストーラ / アップデータは毎回
  `mktemp -d` の一時ディレクトリへ `--depth=1` で shallow clone して
  build → install → cleanup します。利用マシン側で改修・commit・push・
  rebase はしません。GitHub 認証も不要です(public の read-only clone のみ)。

## リモート(開発マシンのみ)

- `origin`   → <https://github.com/unitea1992/herdr.git>
- `upstream` → <https://github.com/herdrdev/herdr.git>

## ローカルパッチブランチ

- ブランチ: `local/tabby-cwd` — ローカルの変更を乗せる唯一のブランチ。

### パッチの内容

`feat: forward focused pane cwd to host terminal` は、フォーカス中のペインの
作業ディレクトリを、iTerm2/Tabby の `OSC 1337;CurrentDir=...` 規約に沿って
ホストターミナルへ転送するため、Tabby の SFTP パネルがアクティブなペインの
cwd に追従します。

動作:

- フォーカス中のペインの既知 cwd が変わったら `OSC 1337;CurrentDir=<path>` を
  送信します(まずライブの OSC 7 レポートを使い、次にプロセスの cwd)。
- バックグラウンドのペインの cwd 変更は転送しません。フォーカス中のペインの
  cwd だけを送信します。
- ペインのフォーカスが移動したら、新しいフォーカス中のペインの既知 cwd を
  再送します。
- パスは生の UTF-8 で送信します。Tabby は `CurrentDir` を percent-decode
  せずに解釈するため、percent-encoding すると `%` を含むパスが壊れます。
  OSC を壊す制御文字(ESC, BEL, ST)のみ除去します。

## 依存ツール

- **Zig 0.15.2 固定**(vendored libghostty-vt)。自動アップグレードはしません。
  Zig は単体バイナリでは動作せず `lib/` を含む配布ツリー全体が必要なので、
  `$HOME/.local/share/herdr/zig-0.15.2/` に完全ツリー(zig + lib/ + docs)として
  保持し、ビルドは `ZIG=<そのzigへの絶対パス>` で固定します。解決順: ① 管理
  対象の完全ツリー、② PATH 上の完全な 0.15.2、③ インストーラによるインストール
  (アップデータはエラー)。`$HOME/.local/bin/zig` は PATH 上の他の zig を壊さない
  ために一切使いません(旧インストーラが作った壊れた単体 zig がそこにあっても
  無視し、削除もしません)。
- Rust CLI は **cargo-binstall** で管理します(ユーザ空間、sudo/apt 不要):
  `cargo-binstall` 本体と `cargo-nextest`(`update-herdr --check` でのみ必要)。
- インストーラと `--check` は `just` を使わないため、PATH に古い apt の
  `just` があっても無関係です。

## ワンラインインストール(新しい Linux マシン)

    curl -fsSL https://raw.githubusercontent.com/unitea1992/herdr/local/tabby-cwd/install-tabbycwd.sh | bash

オーバーライド:

- `HERDR_LOCAL_BIN` — バイナリ配置ディレクトリ(デフォルト `$HOME/.local/bin`)

インストーラは冪等(再実行しても安全)です。rustup / cargo-binstall /
cargo-nextest / Zig 0.15.2 の完全ツリーが無い場合だけ用意し、フォークを
`local/tabby-cwd` から `--depth=1` で一時ディレクトリへ shallow clone、
build は `CARGO_TARGET_DIR="$HOME/.cache/herdr/target"` の共有 cache を使い、
成功時のみ `herdr` と `scripts/update-herdr` を `$BIN_DIR` へ install します。
build 失敗時は既存の installed binary を上書きせず、cache を一度消して再試行
します。一時 clone は成功・失敗どちらでも削除されます。`.bashrc` の編集
(PATH 追記 + `herdr()` 更新ガード)は marker でガードされ、二重に追記される
ことはありません。

## 利用マシンに残るもの

インストール後、利用マシンに永続的に残るのは基本これだけです:

- `$HOME/.local/bin/herdr` — 本体
- `$HOME/.local/bin/update-herdr` — アップデータ(実行のたびに自己更新)
- `$HOME/.local/share/herdr/zig-0.15.2/` — Zig 0.15.2 完全ツリー
- `$HOME/.cache/herdr/target/` — Cargo build cache(任意、消しても再構築される)

source repo の永続 checkout(`$HOME/projects/herdr` など)は作りません。

## 更新フロー

`update-herdr`(実体は `scripts/update-herdr`、`$BIN_DIR/update-herdr` として
インストール)は毎回:

1. 依存(cargo / rustc / Zig 完全ツリー)を事前確認。
2. `mktemp -d` の一時ディレクトリへ `local/tabby-cwd` を `--depth=1` で
   shallow clone。
3. HEAD の short SHA を取得。
4. `CARGO_TARGET_DIR="$HOME/.cache/herdr/target"` で release build
   (失敗時は cache を一度消して再試行)。
5. 成功時のみ installed `herdr` を置換し、clone 内の最新
   `scripts/update-herdr` を `$BIN_DIR/update-herdr` へ再配置(self-update)。
6. version 表示、一時 clone を削除。

`fetch` / rebase / push / upstream 操作は利用マシンでは行いません
(GitHub 認証不要)。実行中の herdr server は停止・再起動しません。都合の
良いタイミングで再起動してください。

### `update-herdr --check`

一時 clone 上で Linux ネイティブのチェック(`cargo fmt --check`、
`cargo clippy --all-targets --locked -- -D warnings`、
`cargo nextest run --locked`、`cargo build --release --locked`)を
**インストールなしで**実行します。installed binary と updater 自身は
変更しません。`x86_64-pc-windows-msvc` ターゲットは追加せず、Windows/macOS
の lint も実行しません。不足している依存(zig の完全ツリー含む)は自動
インストールせず、installer への誘導とともにエラー終了します。

### 共有 build cache の復旧

`~/.cache/herdr/target` は無くても正常動作し、build 失敗時は一度削除して
再試行します。それでも壊れている場合は手動で削除して再実行してください:

    rm -rf ~/.cache/herdr/target && update-herdr

## 旧インストールからの移行

旧インストーラで `$HOME/projects/herdr` の永続 clone が残っている利用マシンが
あります。新方式のインストーラ / アップデータはそのディレクトリを一切必要と
せず、読み書きもしません(勝手に削除もしません)。不要になったらユーザー自身で
手動削除できます:

    rm -rf ~/projects/herdr

`~/.local/bin/zig`(旧インストーラが作った壊れた単体 zig)も従来どおり
勝手に削除しません。残っていても無視されます。

## カスタムバージョン

フォークのビルドは `herdr <upstream-version>+tabbycwd.<short-sha>` を
報告します:

- `<upstream-version>` は上流の `Cargo.toml` の version に自動追従します。
  このフォークで手編集することはありません。
- `tabbycwd` はこのフォークの固定ビルドチャネルです。
- `<short-sha>` は build した `local/tabby-cwd` HEAD の短い SHA で、ビルド時に
  注入されます。

Herdr の既存のビルドメタデータ仕組みを再利用して、以下のコマンドで
ビルドしています:

    HERDR_BUILD_CHANNEL=tabbycwd HERDR_BUILD_ID="$(git rev-parse --short HEAD)" cargo build --release --locked

したがって `herdr --version` は常に実行中の正確なコミットを表示します。
stable / preview チャネルの出力は変わりません。

## `herdr update` ガード

インストール済みの `$BIN_DIR/herdr` はフォークのビルドなので、公式
アップデータで置き換えられてはいけません。`~/.bashrc` で `herdr` シェル関数を
定義し、`herdr update` をブロックして以下を表示します:

    Custom Herdr build detected.
    Use: update-herdr

そして非ゼロで終了します。それ以外の呼び出し(`herdr`, `herdr agent ...`,
`herdr server ...`, `herdr --version`)は `command herdr` で実バイナリを
呼びます(再帰なし)。

## `herdr update` を使わない理由

`herdr update` は公式チャネルからインストール済みバイナリを置き換えるため、
このフォークのローカルパッチが失われてしまいます(パッチはどのリリース
ビルドにも含まれていません)。このフォークは `update-herdr` でのみ更新します。
