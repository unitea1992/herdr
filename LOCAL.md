# LOCAL — 個人フォーク運用

このリポジトリは `herdrdev/herdr`
(<https://github.com/herdrdev/herdr>) の個人フォークで、**Linux専用**です:
インストーラ、アップデータ、チェックモードは Windows/macOS ターゲット、
PowerShell、`just` を一切使いません。上流の `README.md` は意図的に
変更していません。

## リモート

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
  `$HOME/.local/share/herdr/zig-$ZIG_VERSION/` に完全ツリー(zig + lib/ +
  docs)として保持し、ビルドは `ZIG=<そのzigへの絶対パス>` で固定します。
  解決順: ① 管理対象の完全ツリー、② PATH 上の完全な 0.15.2、③ インストーラ
  によるインストール(アップデータはエラー)。`$HOME/.local/bin/zig` は
  PATH 上の他の zig を壊さないために一切使いません(旧インストーラが
  作った壊れた単体 zig がそこにあっても無視し、削除もしません)。
- Rust CLI は **cargo-binstall** で管理します(ユーザ空間、sudo/apt 不要):
  `cargo-binstall` 本体と `cargo-nextest`(`update-herdr --check` でのみ必要)。
- インストーラと `--check` は `just` を使わないため、PATH に古い apt の
  `just` があっても無関係です。

## ワンラインインストール(新しい Linux マシン)

    curl -fsSL https://raw.githubusercontent.com/unitea1992/herdr/local/tabby-cwd/install-tabbycwd.sh | bash

オーバーライド:

- `HERDR_LOCAL_REPO` — リポジトリのチェックアウト先(デフォルト
  `$HOME/projects/herdr`)
- `HERDR_LOCAL_BIN` — バイナリ配置ディレクトリ(デフォルト `$HOME/.local/bin`)

インストーラは冪等(再実行しても安全)で、dirty なチェックアウトには触れません。
rustup/cargo-binstall/cargo-nextest/Zig 0.15.2 の完全ツリー
(`$HOME/.local/share/herdr/zig-0.15.2/`)が無い場合だけインストールし、
フォークを clone、リモートを設定、`local/tabby-cwd` を checkout、
`upstream/master` に遅れていれば rebase(コンフリクトは自動解決しません)、
独自の version metadata 付きでビルドし、バイナリと `scripts/update-herdr` を
インストールします。`.bashrc` の編集(PATH 追記 + `herdr()` 更新ガード)は
marker でガードされ、二重に追記されることはありません。

## 更新フロー

`update-herdr`(実体は `scripts/update-herdr`、`$BIN_DIR/update-herdr` として
インストール):

利用マシンはこのフォークを取得・ビルドするだけなので、更新フローから
`upstream` の rebase と origin への push を取り除いています。upstream 追従・
rebase・push は開発マシン側で行い、`origin/local/tabby-cwd` が常に配布用の
最新状態です。更新は fast-forward のみなので、GitHub 認証(push に必要な
認証)は一切要求しません。

1. 事前チェック: 作業ツリーが clean、現在のブランチが `local/tabby-cwd`、
   `origin` リモートが存在する場合以外は中止。
2. `origin` を fetch する(public なので認証不要)。
3. `origin/local/tabby-cwd` へ fast-forward のみで追従する。既に最新なら
   そのまま、origin が前に進んでいるなら ff、local が diverge している場合は
   コミットを壊さずに明確なエラーで中止。
4. `cargo build --release --locked` でビルドし、成功時のみ
   `target/release/herdr` を `$BIN_DIR/herdr` にインストールする。
5. ローカル HEAD を報告する。実行中の herdr server を停止・再起動する
   ことはありません。都合の良いタイミングで再起動してください。

バリエーション:

- `update-herdr --check` — 同じ origin fetch/ff 追従の後に、Linux ネイティブの
  チェック(依存の事前確認、`cargo fmt --check`、`cargo clippy --all-targets
  --locked -- -D warnings`、`cargo nextest run --locked ...`、`cargo build
  --release --locked`)を**インストールなしで**実行します。
  `x86_64-pc-windows-msvc` ターゲットは追加せず、Windows/macOS の lint も
  実行しません。不足している依存(zig の完全ツリー含む)は自動インストール
  せず、installer への誘導とともにエラー終了します。
- `update-herdr --clean` — 通常の update/build の前に `cargo clean` を実行。
  リポジトリ移動後に、キャッシュされた古いパスが vendored の zig build を
  壊す場合(`cannot find -lghostty-vt`)に使います。通常の update では
  clean しません。

## カスタムバージョン

フォークのビルドは `herdr <upstream-version>+tabbycwd.<short-sha>` を
報告します:

- `<upstream-version>` は上流の `Cargo.toml` の version に自動追従します。
  このフォークで手編集することはありません。
- `tabbycwd` はこのフォークの固定ビルドチャネルです。
- `<short-sha>` は現在の `local/tabby-cwd` HEAD の短い SHA で、ビルド時に
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

## コンフリクト対応方針

- 利用マシンの `update-herdr` では rebase を行いません。local が
  `origin/local/tabby-cwd` と diverge した場合、自動的には何も壊さずに
  明確なエラーで停止します。通常は開発マシン側の配布状態と rebase 済みの
  追従状態をそのまま使います。ローカルの独自コミットが必要なら手動で
  merge/rebase してください。
- インストーラの初期セットアップだけは `upstream/master` への rebase を
  試み、コンフリクト時は中断します(初期セットアップのみ)。
