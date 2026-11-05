# セキュリティポリシー

## 脆弱性の報告

脆弱性を見つけた場合は、公開の Issue や Pull Request には書かず、GitHub の非公開の報告（[Report a vulnerability](https://github.com/tbshiki/andon/security/advisories/new)）から知らせてください。

次の内容を含めてもらえると助かります。

- 影響（何ができてしまうか）
- 再現の手順
- 確認した環境（Windows、PowerShell、Claude Code、VS Code のバージョン）

個人で開発しているため、返信や修正の時期は約束できませんが、確認して対応します。

## 対象

最新の [Release](https://github.com/tbshiki/andon/releases/latest) だけを対象にします。Release の zip が本物かは、README の「インストール」にある `gh release verify-asset` で確かめられます。

## andon が行うこと

報告の範囲を判断する参考にしてください。andon が行うのは次のことだけです。

- `claude agents --json` を実行し、セッションの一覧を読む
- Claude Code の設定ディレクトリ（既定は `~/.claude`）にある `sessions/*.json` の、ファイル名と更新時刻を見る（中身は読まない。`*.key` には触れない）
- セッションの作業フォルダとその周辺の `*.code-workspace` を読み、開く対象を VS Code（`Code.exe`）に渡す
- 通知の送り元を `andon` と表示させるため、`HKCU\Software\Classes\AppUserModelId\tbshiki.andon` に表示名を書く
- 名前付きのイベント `Local\andon-exit` の合図を受けたら終了する（同じ Windows のセッションのプロセスなら、andon を終了できる）
- 起動して少し後と、その後 1 日 1 回、`https://api.github.com/repos/tbshiki/andon/releases/latest` を取得して、新しいバージョンがあるかを確かめる。送るのは普通の HTTP の要求（User-Agent は `andon/<バージョン>`）だけで、セッションやファイルの情報は送らない。`-NoUpdateCheck` を付けたときと、`andon.ps1` の隣に `.git` があるときは確かめない
- アップデートするかを尋ねる画面（通知のクリックか、トレイの「アップデート」で出る）で「アップデートする」を選んだときだけ、そのバージョンの `andon-<バージョン>.zip` を、このリポジトリの Release から落とす。使うのは、公開済みで immutable の Release だけ。zip が、Release が示す sha256 と同じかを確かめてから一時フォルダ（`%TEMP%\andon-update-*`）に展開し、新しいバージョンの `install.ps1` を実行するコンソールを開いて、andon は終了する

andon が通信するのは、上の GitHub だけです。GitHub にはログインせずに問い合わせ、認証情報は読みません。

`install.ps1` が行うのは次のことだけです。ネットワークには通信しません。管理者の権限を求めません。

- 同じフォルダにある `andon.ps1`・`install.ps1`・`install.cmd`・`README.txt`・`andon.ico`・`LICENSE` を `%LOCALAPPDATA%\Programs\andon` に置き、ダウンロードした印（Mark of the Web）を外す
- スタートメニューとスタートアップに、andon を起動するショートカットを作る
- Windows の「インストールされているアプリ」に andon を登録する（`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\tbshiki.andon`）。登録するアンインストールのコマンドは、cmd.exe を通さず、Windows PowerShell 5.1 を絶対パスで起動して `install.ps1 -Uninstall -PauseOnError` を実行する
- 動いている andon を終了する。合図を受けられない古いバージョンは、`andon.ps1` を `-File` で動かしている PowerShell のプロセスを止める
- `-Uninstall` を付けたときは、これらと、andon と Windows が作ったレジストリのキーと値（`AppUserModelId\tbshiki.andon`、`Notifications\Settings\tbshiki.andon`、`Uninstall\tbshiki.andon`、`StartupApproved\StartupFolder` の `andon.lnk`）を消す

`install.cmd` は、同じフォルダの `install.ps1` を、Windows PowerShell 5.1 を絶対パスで起動して実行するだけです。失敗したときだけ、閉じる前にキーを待ちます。
