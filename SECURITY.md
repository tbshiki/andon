# セキュリティポリシー

## 脆弱性の報告

脆弱性を見つけた場合は、公開の Issue や Pull Request には書かず、GitHub の非公開の報告（[Report a vulnerability](https://github.com/tbshiki/andon/security/advisories/new)）から知らせてください。

次の内容を含めてもらえると助かります。

- 影響（何ができてしまうか）
- 再現の手順
- 確認した環境（Windows、PowerShell、Claude Code、VS Code、Codex CLI のバージョン）

個人で開発しているため、返信や修正の時期は約束できませんが、確認して対応します。

## 対象

最新の [Release](https://github.com/tbshiki/andon/releases/latest) だけを対象にします。Release の zip が本物かは、README の「インストール」にある `gh release verify-asset` で確かめられます。

## andon が行うこと

報告の範囲を判断する参考にしてください。andon が行うのは次のことだけです。

- `claude agents --json` を実行し、セッションの一覧を読む
- トレイのメニューの「Codex の状態を出す」を選んだときだけ、Codex の hooks の設定（`~/.codex/hooks.json`。`CODEX_HOME` があればその下）に、andon の hook（`andon-codex-hook.ps1` を `async: true` で動かすもの）を足す、または消す。ほかの hook は変えない。書き換える前に、`hooks.json.andon-backup` に写しを作る。JSON として読めなければ触らない。Codex の `config.toml` には触らない。メニューを開いたときは、チェックを決めるために `hooks.json` を読む
- `andon-codex-hook.ps1` は、Codex が hook として動かす。Codex から渡る JSON のうち、セッションの ID、状態、作業フォルダ、ターンの ID だけを使い、`%LOCALAPPDATA%\andon\codex\<セッションの ID>.json` に書く（プロンプト、コマンド、返事の中身は書かない）。セッションの最初のイベントのときだけ、プロセスの一覧（`Win32_Process` の PID、親の PID、起動時刻、名前、起動引数）を読み、自分の親をたどって Codex のプロセスを探す。何も出力しない。Codex が信頼するのは、このスクリプトを動かすコマンドなので、スクリプトの中身は andon のアップデートで変わる
- andon は、`%LOCALAPPDATA%\andon\codex` のファイル名と更新時刻を見て、変わったら中身を読む。Codex のプロセスが終わったセッションと、24 時間たったセッションの記録を消す
- Claude Code の設定ディレクトリ（既定は `~/.claude`）にある `sessions/*.json` の、ファイル名と更新時刻を見る（中身は読まない。`*.key` には触れない）
- セッションの作業フォルダとその周辺の `*.code-workspace` を読み、開く対象を VS Code（`Code.exe`）に渡す
- プロセスの一覧（`Win32_Process` の PID、親の PID、起動時刻、名前）を読み、セッションのプロセス（Codex のセッションは、記録した Codex のプロセスがターミナルの中の `codex.exe` のときだけ、そのプロセス）から親へたどる。新しいセッションが出たときは、拡張機能のパネルのセッションかを見分けるため、そのプロセスの起動引数も読む
- セッションの行や通知をクリックしたときと、新しく待ちや完了が出たとき（点滅と通知の前）に、コンソールのウィンドウ（Windows Terminal や VS Code の統合ターミナルが持つ、隠れたウィンドウを含む）を数え、そのクラスと持ち主を見る。クリックしたときは、セッションを映しているウィンドウを前面に出す（最小化していれば元に戻す）。Windows が断ったときは、前面のウィンドウの入力に一時的につないで（`AttachThreadInput`）、もう一度試す
- 同じとき、Orca のプロセス（`Orca.exe`）が見えるウィンドウを持つかと、その実行ファイルのパスを読む。セッションが Orca の区画で動いていれば、クリックのときは Orca のウィンドウを前面に出し、新しく待ちや完了が出たときは、「Orca のセッションも通知する」を選んでいなければ Windows の通知を出さない。トレイのメニューを開いたときも、このメニューを出すかを決めるために、Orca が動いているかを見る
- クリックのときは、そのあと、その `Orca.exe` と同じフォルダの Orca の CLI（`resources\bin\orca.exe`。PATH は見ない）を、ウィンドウを出さずに起動し、`orca terminal list --json` で Orca のターミナルの一覧（handle、worktree のパス、エージェントの種類）を読む。セッションのタブが 1 つに決まれば、`orca terminal switch --terminal <handle> --json` でそのタブに切り替える。CLI には `ORCA_` で始まる環境変数を渡さない。5 秒で終わらなければ止める。Orca の内部のファイルは読まない
- トレイのメニューの「Orca のリモートを出す」でペアリング先（ペアリングした Orca サーバー）を選んだときだけ、この PC で Orca のウィンドウが出ているあいだ、Orca の CLI を `orca worktree ps --environment <ペアリング先の ID> --limit 500 --json` で定期的に動かす（実行中か待ちのセッションがあれば 10 秒ごと、なければ 60 秒ごと。15 秒で終わらなければ止める）。CLI は、Orca がペアリングのときに覚えた繋ぎ先を使って、この PC からペアリング先のマシンへ通信する。andon は、繋ぎ先も、ペアリングの鍵も読まない。CLI の出力にはプロンプトや返事の文字も入るが、使うのは、状態、エージェントの種類、区画の ID、プロジェクトと workspace の名前、パス、状態が変わった時刻だけで、ほかは捨て、保存しない。ID は、英数字と `_` `.` `:` `-` だけのものに限って使う。andon は Orca を起動しない
- 同じメニューを開いたときと、リモートを読み始めるときに、`orca environment list --json` でペアリング先の一覧を読み、ID と名前だけを使う（Orca が保存しているペアリング先を読むコマンドで、ペアリング先へは通信しない見込み）。リモートのセッションの行や通知をクリックしたときは、`orca terminal list --environment <ID> --json` と `orca terminal switch --terminal <handle> --environment <ID> --json` で、この PC の Orca をそのタブに切り替える
- 点滅を止めるため、前面のウィンドウを調べ、VS Code のウィンドウなら題名を読む
- 通知の送り元を `andon` と表示させるため、`HKCU\Software\Classes\AppUserModelId\tbshiki.andon` に表示名を書く
- ウィンドウの位置と大きさ、「常に手前」、テーマ、縦表示、Orca のセッションも通知するか、選んだ Orca のペアリング先の ID を、`HKCU\Software\tbshiki\andon` に書き、起動したときに読む（数値と、ペアリング先の ID の並びだけ。読めない値は使わない）
- テーマを「Windows に合わせる」にしているときは、Windows のアプリ モード（`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` の `AppsUseLightTheme`）を読む（書かない）
- トレイのメニューの「ログオン時に起動」を選んだときだけ、スタートアップのフォルダに `andon.lnk`（スタートメニューの `andon` のショートカットの写し）を作る、または消す。あわせて、タスク マネージャーの有効・無効の記録（`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder` の値 `andon.lnk`）を消す。インストールした andon だけが行い、clone から動かしている andon は行わない
- 名前付きのイベント `Local\andon-exit` の合図を受けたら終了する（同じ Windows のセッションのプロセスなら、andon を終了できる）
- 起動して少し後と、その後 1 日 1 回、`https://api.github.com/repos/tbshiki/andon/releases/latest` を取得して、新しいバージョンがあるかを確かめる。送るのは普通の HTTP の要求（User-Agent は `andon/<バージョン>`）だけで、セッションやファイルの情報は送らない。`-NoUpdateCheck` を付けたときと、`andon.ps1` の隣に `.git` があるときは確かめない
- アップデートするかを尋ねる画面（通知のクリックか、トレイの「アップデート」で出る）で「アップデートする」を選んだときだけ、そのバージョンの `andon-<バージョン>.zip` を、このリポジトリの Release から落とす。使うのは、公開済みで immutable の Release だけ。zip が、Release が示す sha256 と同じかを確かめてから一時フォルダ（`%TEMP%\andon-update-*`）に展開し、新しいバージョンの `install.ps1` を実行するコンソールを開いて、andon は終了する

andon が自分で通信するのは、上の GitHub だけです。GitHub にはログインせずに問い合わせ、認証情報は読みません。Orca の CLI は、ふつうは繋ぎ先を指定せずに動かし、CLI の既定（ふつうは同じ PC で動いている Orca）に任せます。「Orca のリモートを出す」でペアリング先を選んだときだけ、そのペアリング先を指定して動かし、CLI がそのマシンへ通信します。

`install.ps1` が行うのは次のことだけです。ネットワークには通信しません。管理者の権限を求めません。

- 同じフォルダにある `andon.ps1`・`install.ps1`・`install.cmd`・`README.txt`・`andon.ico`・`LICENSE`・`andon-codex-hook.ps1` を `%LOCALAPPDATA%\Programs\andon` に置き、ダウンロードした印（Mark of the Web）を外す
- スタートメニューに、andon を起動するショートカットを作る。スタートアップのショートカットは、アップデートのときにあれば書き直す（新しくインストールするときは作らない）
- Windows の「インストールされているアプリ」に andon を登録する（`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\tbshiki.andon`）。登録するアンインストールのコマンドは、cmd.exe を通さず、Windows PowerShell 5.1 を絶対パスで起動して `install.ps1 -Uninstall -PauseOnError` を実行する
- 動いている andon を終了する。合図を受けられない古いバージョンは、`andon.ps1` を `-File` で動かしている PowerShell のプロセスを止める
- `-Uninstall` を付けたときは、Codex の `hooks.json` から andon の hook を消し（ほかの hook は残す）、`%LOCALAPPDATA%\andon` を消す。あわせて、これらと、andon と Windows が作ったレジストリのキーと値（`AppUserModelId\tbshiki.andon`、`Notifications\Settings\tbshiki.andon`、`Uninstall\tbshiki.andon`、`StartupApproved\StartupFolder` の `andon.lnk`、設定の `Software\tbshiki\andon`。`Software\tbshiki` は、ほかに何もなければ消す）を消す

`install.cmd` は、同じフォルダの `install.ps1` を、Windows PowerShell 5.1 を絶対パスで起動して実行するだけです。失敗したときだけ、閉じる前にキーを待ちます。
