andon の入れ方

andon は、Claude Code のセッションの状態（実行中・許可待ち・質問待ち・完了）を一覧し、
クリックでそのセッションの VS Code のウィンドウを前面に出す、Windows 向けの小さなツールです。
使い方と詳しいことは、GitHub の README にあります。
https://github.com/tbshiki/andon


■ 入れ方

1. zip を右クリックして「すべて展開」を選び、展開します。
   zip を開いただけで中の install.cmd をダブルクリックすると、
   「install.ps1 was not found」と出て止まります。先に展開してください。
2. 展開したフォルダの install.cmd をダブルクリックします。
3. 「開いているファイル - セキュリティの警告」が出たら、「実行」を押します。
   インターネットから落としたファイルを開くときに、Windows が出す確認です。
4. andon が起動し、画面の右下にウィンドウが開きます。
   通知領域（タスクトレイ）にもアイコンが出ます。

管理者の権限は要りません。インターネットにも接続しません。
失敗したときは、黒い画面に理由が出て、キーを押すまで閉じません。


■ andon が入る場所

andon は %LOCALAPPDATA%\Programs\andon に入り、そこから動きます。
スタートメニューに「andon」ができます。ログオンしたときにも起動します（スタートアップ）。
展開したフォルダと zip は、入れたあと消してかまいません。


■ 消し方

Windows の「設定」→「アプリ」→「インストールされているアプリ」
（Windows 10 では「アプリと機能」）で andon を選び、「アンインストール」を押します。
Windows 11 では、andon の右の「…」から「アンインストール」を選びます。


■ 本物の zip か確かめる

andon は、GitHub の Release のページからだけ落としてください。
https://github.com/tbshiki/andon/releases

GitHub CLI（gh）があれば、落とした zip が Release のものと同じかを、展開する前に確かめられます。
zip の名前が andon-0.2.0.zip なら、zip のあるフォルダで次を実行します。

  gh release verify-asset v0.2.0 andon-0.2.0.zip -R tbshiki/andon
