# Repository instructions

回答は日本語で行う。

## セットアップ・更新の経路

- このリポジトリの変更を環境へ適用するときは、先にPRを作成して `main` にマージする。
- セットアップはWindowsの `Downloads/setup-wsl.cmd` から実行する。この環境の指定パスは
  `/mnt/c/Users/reisu/Downloads/setup-wsl.cmd`（Windowsでは `C:\Users\reisu\Downloads\setup-wsl.cmd`）。
- `~/.codex/skills` やWindows側の `.codex/skills` への直接コピー、`install.sh` や
  `scripts/install-skill.sh` の直接実行による環境への適用は行わない。CMDから呼ばれる内部処理は許可する。
- CMDは公開済み `main` を取得する。未マージの変更をローカルコピーで先行適用しない。
- セットアップが失敗したら原因を明示し、直接インストールへの切り替えやローカル変更の破棄で回避しない。
- 一時ディレクトリを使う自動テストは環境へのセットアップとは区別する。

## 検証

- Bashの回帰テストは `tests/*.tests.sh`、通知処理は `python3 tests/ralph-notify.tests.py`。
- Windowsランチャーの検証はPowerShellで `tests/setup-wsl-path.tests.ps1` を実行する。
- 実際のセットアップ完了と、ソースコード・模擬処理のテスト成功を区別して報告する。
