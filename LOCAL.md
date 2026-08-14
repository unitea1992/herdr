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
  PATH 上の別バージョンの zig には触れず、ビルドは `ZIG=<path>` でこの
  バージョンに固定します(PATH の zig 優先、次に `$HOME/.local/bin/zig`)。
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
rustup/cargo-binstall/cargo-nextest/Zig 0.15.2 が無い場合だけインストールし、
フォークを clone、リモートを設定、`local/tabby-cwd` を checkout、
`upstream/master` に遅れていれば rebase(コンフリクトは自動解決しません)、
独自の version metadata 付きでビルドし、バイナリと `scripts/update-herdr` を
インストールします。`.bashrc` の編集(PATH 追記 + `herdr()` 更新ガード)は
marker でガードされ、二重に追記されることはありません。

## 更新フロー

`update-herdr`(実体は `scripts/update-herdr`、`$BIN_DIR/update-herdr` として
インストール):

1. 事前チェック: 作業ツリーが clean、現在のブランチが `local/tabby-cwd`、
   `origin`/`upstream` リモートが存在する場合以外は中止。
2. `upstream` と `origin` を fetch する。
3. `local/tabby-cwd` を `upstream/master` へ rebase する。
4. 成功時のみ `--force-with-lease` で origin へ force-push する。
5. `cargo build --release --locked` でビルドし、成功時のみ
   `target/release/herdr` を `$BIN_DIR/herdr` にインストールする。
6. upstream の before/after とローカル HEAD を報告する。実行中の herdr
   server を停止・再起動することはありません。都合の良いタイミングで
   再起動してください。

バリエーション:

- `update-herdr --check` — 同じ fetch/rebase/push の後に、Linux ネイティブの
  チェック(依存の事前確認、`cargo fmt --check`、`cargo clippy --all-targets
  --locked -- -D warnings`、`cargo nextest run --locked ...`、`cargo build
  --release --locked`)を**インストールなしで**実行します。
  `x86_64-pc-windows-msvc` ターゲットは追加せず、Windows/macOS の lint も
  実行しません。不足している依存は自動インストールせず、インストール
  コマンドとともにエラー終了します。
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

- rebase のコンフリクトは自動解決しません。`update-herdr` はコンフリクトで
  停止し、競合ファイルを列挙します。手動で解決してから
  `git rebase --continue` を実行してください。インストーラは rebase を
  中止します(あくまで初期セットアップのみ。解決して `update-herdr` を
  再実行してください)。
- force-push は常に `--force-with-lease` を使用します。
