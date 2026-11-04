# AI 開発ガイドライン

このファイルは、このリポジトリで作業する AI への共通指示の正典です。

## プロジェクト概要

- andon は、Claude Code の対話セッションの状態（実行中・許可待ち・質問待ち・完了）を一覧し、クリックでそのセッションの VS Code ウィンドウを前面に出す、Windows 向けの小さな GUI ツールである。
- 技術スタック: PowerShell + Windows Forms。Windows PowerShell 5.1 と PowerShell 7 の両方で動かす。ビルドはない。
- 状態の正本は公式の `claude agents --json` とする。Claude Code の設定ディレクトリ（既定は `~/.claude`）の内部ファイルは、変化の検知（ファイル名と更新時刻）にだけ使い、中身を解釈しない。内部の形式が変わっても定期取得で動き続けること（フェイルソフト）を必須とする。
- 公開リポジトリである。実在のパス、user 名、セッション名、メールアドレスなどの個人の値を、コード、テスト、文書、コミットメッセージに書かない。例には placeholder を使う。

## コミュニケーション

- ユーザーへの応答、進捗、検証結果は日本語で記述する。
- 不明点が軽微なら安全な仮定を明示して進め、結果に影響する判断だけを確認する。

## 作業規約

- 作業開始時に `git status --short` を確認し、既存の未コミット変更を保持する。
- `~/.claude/sessions/*.key`、`~/.claude/.credentials.json`、`.env`、鍵、トークンなどの秘密情報を読み取ったり、表示したり、コミットしたりしない。
- 既存の設計と設定を尊重し、タスクに無関係な変更を混ぜない。

## ファイルエンコーディング

- 通常のテキストは UTF-8・LF。PowerShell スクリプト（`*.ps1`）は UTF-8 BOM 付き・CRLF で保存する。
- Windows PowerShell 5.1 は BOM なし UTF-8 をレガシーコードページとして読む。日本語のコメントが次の行を飲み込み、その行のコードが黙って消えることがある。PowerShell 7 では再現しないので、7 で動いても 5.1 で壊れる。
- この規約は `.editorconfig` と `.gitattributes` に定義してあるが、**AI やツールのファイル書き込みはこれらを適用しない**。`*.ps1` を新規作成・編集したら BOM と CRLF を自分で確認して直す。テストもこれを検査する。
- PowerShell 7 の `Set-Content -Encoding UTF8` は BOM を付けない。BOM 付きで書くには `-Encoding utf8BOM` か `New-Object Text.UTF8Encoding($true)` を使う。
- PowerShell からテキストを読む処理は `Get-Content` / `Select-String` に `-Encoding UTF8` を明示する。

## Git 運用

- このリポジトリの Git 運用（ブランチ作成、コミット、マージ）は AI が主体的に行ってよい。
- 基本の流れは「（必要なら作業用ブランチを作成）→ 日本語でコミット」まで。タスクが完了しても、その場では `main` へマージしない。
- コミットメッセージは Conventional Commits 形式（`type: short description`）を使う。主な type は `feat`（機能追加）、`fix`（修正）、`docs`（文書）、`chore`（雑務・設定）、`refactor`（リファクタリング）、`test`（テスト）とする。
- 例: `feat: 待ちの件数をタスクバーに表示`、`fix: 空白を含むパスでウィンドウを開けない`、`chore: AI開発ガイドラインを更新`
- コミットメッセージの末尾に、作業した AI の `Co-Authored-By:` 行を付ける。モデル名は実行中のモデルのものを使う。
- コミット後は、ユーザーから別途止める指示がない限り、作業ブランチをリモートへプッシュする。外部公開操作のため、実行環境の承認が必要な場合はその承認を求める。
- `main` へのマージは、これまでと異なるタスクを開始するタイミングで行う。次の依頼が現在の作業ブランチと無関係な場合、AI は現在の変更をコミット済みか確認し、作業ブランチを `main` へ `--no-ff` でマージしてから、新しい作業ブランチを作成して次の作業とコミットを行う。関連する続きの場合は、マージせず現在のブランチで継続する。
- マージ済みの作業用ブランチは削除してよい。
- tag の作成・プッシュは、通常のブランチプッシュとは別にユーザーへ確認する。
- コミット前に `git status --short` と対象ファイルを確認し、秘密情報と個人の値が含まれていないことを確かめる。

## 実装と検証

- GUI に依存しない処理は、`andon.ps1` のドットソース境界（`if ($MyInvocation.InvocationName -eq '.') { return }`）より前に置き、テストから呼べるようにする。
- 変更後は `tests/Test-Andon.ps1` を Windows PowerShell 5.1 と PowerShell 7 の両方で実行する。

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Andon.ps1
  pwsh -NoProfile -File .\tests\Test-Andon.ps1
  ```

- GUI、`claude agents --json`、`code` コマンドに依存する部分はテストで確かめられない。触った場合は実際に起動して確かめ、確かめた操作を報告する。
- 最終報告には変更内容、実施した検証、検証できなかった項目と残るリスクを含める。
