# セキュリティポリシー

## 脆弱性の報告

脆弱性を見つけた場合は、公開の Issue や Pull Request には書かず、GitHub の非公開の報告（[Report a vulnerability](https://github.com/tbshiki/andon/security/advisories/new)）から知らせてください。

次の内容を含めてもらえると助かります。

- 影響（何ができてしまうか）
- 再現の手順
- 確認した環境（Windows、PowerShell、Claude Code、VS Code の版）

個人で開発しているため、返信や修正の時期は約束できませんが、確認して対応します。

## 対象

最新の `main` だけを対象にします。

## andon が行うこと

報告の範囲を判断する参考にしてください。andon が行うのは次のことだけです。

- `claude agents --json` を実行し、セッションの一覧を読む
- Claude Code の設定ディレクトリ（既定は `~/.claude`）にある `sessions/*.json` の、ファイル名と更新時刻を見る（中身は読まない。`*.key` には触れない）
- セッションの作業フォルダとその周辺の `*.code-workspace` を読み、開く対象を VS Code（`Code.exe`）に渡す

andon 自身はネットワークに通信せず、認証情報も読みません。
