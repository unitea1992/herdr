---
name: herdr-throwaway-repro
description: Herdrの既定sessionを触らず、隔離したnamed sessionで実機再現するときに使う。
---

# Herdr throwaway reproduction

既存Herdr sessionへ影響を与えず、実際のserver・pane・PTY・agent・socket APIを使う再現が必要な場合に使う。

1. `references/workflow.md` を読み、現在のHerdr CLIの `--help` を正本として手順を補正する。
2. disposable named sessionと専用pane/temp領域だけを操作する。既定session・main server・無関係なpane/processを停止・削除しない。
3. 観測事実を採取し、作成した一時資産だけをcleanupする。
