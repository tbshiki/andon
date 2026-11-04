# andon

複数の VS Code ウィンドウで Claude Code を動かしているときに、**入力を待っているセッションを一覧し、クリック 1 回でそのウィンドウへ移る**ための、Windows 向けの小さなウィンドウです。

全部のウィンドウを巡回して終わったものを目で探す代わりに、許可待ち・質問待ち・完了したセッションが色付きで上に並びます。名前は、工場で各工程の状態を並べて表示し、助けが必要な工程が点灯する表示盤「アンドン」から取りました。

## 表示

| 状態 | 色 | 意味 |
|---|---|---|
| 許可待ち / 質問待ち | 赤 | Claude があなたの承認や回答を待っている |
| 完了 | 黄 | 実行中から待機に変わり、まだ確認していない |
| 実行中 | 通常 | ツールの実行や応答の生成中 |
| 待機 | 灰 | 次のプロンプトを待っている（確認済み） |

- 行をクリックすると、そのセッションの VS Code ウィンドウが前面に出ます。
- 黄は、行をクリックする、右クリックの「既読にする」、「すべて既読」、そのセッションで次のプロンプトを送る、のいずれかで消えます。
- VS Code の Claude Code 拡張機能（パネル）のセッションは、パネルを開いているだけで待機中のまま常駐するので、待機中は表示しません。実行中・待ち・完了のときは表示します。
- andon はタスクバーには出ず、通知領域（タスクトレイ）にアイコンを置きます。アイコンは、赤があれば赤、黄があれば黄、どちらもなければ灰になります。赤と黄の件数は、ウィンドウのタイトルとアイコンのツールチップに出ます。
- 新しく待ちや完了が出たとき、andon が前面になければ Windows の通知を出し、ウィンドウのタイトルバーを点滅させます。通知をクリックすると、そのセッションの VS Code ウィンドウが前面に出ます。通知の送り元は、andon を動かしている PowerShell の名前（`Windows PowerShell` など）で表示されます。
- ウィンドウの × や最小化では、終了せずにトレイに隠れます。トレイのアイコンをクリックすると、表示と非表示が切り替わります。終了は、トレイのアイコンの右クリックのメニューから行います。
- Windows 11 では、新しいアイコンは最初、通知領域の `^` の中に隠れています。常に見えるようにするには、`^` の中からアイコンをタスクバーへドラッグします。

## 動作環境

- Windows 10 / 11
- Windows PowerShell 5.1 または PowerShell 7
- Claude Code（`claude agents --json` が対話セッションの `status` を返す版。動作確認は 2.1.318）
- VS Code の `code` コマンド（andon は、これを手がかりに `Code.exe` を探します）

Claude Code は VS Code の統合ターミナルなどで普通に `claude` を起動していれば対象になります。VS Code 拡張機能のパネルで会話したときに、状態が正しく変わるかは確認していません。

## 使い方

```powershell
git clone https://github.com/tbshiki/andon.git
Start-Process conhost.exe '--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\andon\andon.ps1'
```

画面の右下に、常に手前に表示されるウィンドウが開き、通知領域にアイコンが出ます。二重に起動しても 2 つ目はすぐ終了します（トレイに隠れているときは、トレイのアイコンから表示します）。

ログオン時に自動で起動するには、`Win + R` で `shell:startup` を開き、次のショートカットを置きます。

- リンク先: `conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<clone した場所>\andon.ps1"`

`conhost.exe --headless` は、PowerShell のコンソールをウィンドウなしで動かします。Windows 11 では既定のターミナルが Windows Terminal なので、`powershell.exe -WindowStyle Hidden` で起動すると、コンソールが Windows Terminal に引き渡されて隠れず、andon とは別にタスクバーに残ります。

`-FallbackSec` で、変化がなくても状態を取り直す間隔（既定 30 秒）を変えられます。`-ScanMs` で、変化を見る間隔（既定 1000 ミリ秒、200〜5000）を変えられます。長くすると、待ちに気付くのが遅れます。

## 仕組み

- **状態:** 公式の `claude agents --json` から読みます。対話セッションごとに `status`（`busy` / `waiting` / `idle`）と、`waiting` の理由（`waitingFor`）が返ります。
- **変化の検知:** `claude agents --json` は 1 回で CPU を 0.3 秒ほど使うので、短い間隔で呼び続けません。Claude Code は状態が変わるたびに `~/.claude/sessions/<pid>.json` を書き換えるので、1 秒ごと（`-ScanMs`）にそのファイル名と更新時刻だけを見て、変化があったときに呼びます。ファイルの中身は読みません。同じ場所にある `*.key` には触れません。`CLAUDE_CONFIG_DIR` を設定していればその下を見ます。
- **拡張機能のパネルの区別:** `claude agents --json` は、ターミナルのセッションも拡張機能のパネルのセッションも `kind: interactive` として返します。新しいセッションが出たときに一度だけ、そのプロセスの起動引数に `--input-format stream-json` があるかを見て区別します。
- **ウィンドウの特定:** セッションの作業フォルダから、次の順に開く対象を決めて VS Code に渡します。VS Code は、その workspace やフォルダを開いているウィンドウがあれば、新しく開かずにそのウィンドウを前面に出します。`code` コマンド（`code.cmd`）は cmd.exe を通り、パスの `%VAR%` が展開されてしまうので、隣にある `Code.exe` に直接渡します（`Code.exe` が見つからなければ `code.cmd` を使います）。
  1. 作業フォルダから repository の root まで遡り、`*.code-workspace` があれば最も近いもの
  2. repository の親フォルダと、その隣のフォルダにある `*.code-workspace` のうち、`folders` に repository（または作業フォルダを含む、その中のフォルダ）を挙げているもの（multi-root workspace）。複数あれば、作業フォルダに最も近いフォルダを挙げているもの
  3. どちらもなければ repository の root（git の外なら作業フォルダ）
- 無関係な workspace を開かないよう、repository の root より上の階層の `*.code-workspace` は、`folders` で repository を挙げていない限り使いません。`folders` に親フォルダ全体（`..` など）を挙げているだけの workspace も使いません。
- Claude Code が作る worktree（`<repo>\.claude\worktrees\<name>`）は、元の repository として扱います。

## 制約

- 前面に出せるのはウィンドウまでです。どのターミナルのタブかまでは選べません。
- workspace がないとき、repository のサブフォルダを直接開いているウィンドウや、repository より広いフォルダ（親フォルダ全体など）を開いているウィンドウは特定できません。repository の root が新しいウィンドウで開きます。
- andon を起動した時点で待機中のセッションは、いつ終わったか分からないので「待機」（確認済み）として表示します。
- 変化を見る間隔（`-ScanMs`）に `claude agents --json` の実行時間を足したくらいより短いやり取りは、「完了」を取りこぼすことがあります。
- `~/.claude/sessions` は Claude Code の内部のディレクトリなので、書き方が変わるかもしれません。その場合も `-FallbackSec` ごとの取得で状態には追従します。
- background セッション（`claude --bg` など）も一覧に出ますが、クリックで開けるのは作業フォルダの VS Code ウィンドウです。会話そのものは `claude agents` で開いてください。
- 動作確認は Windows の VS Code でのみ行っています。

## 開発

GUI に依存しない部分のテストを、Windows PowerShell 5.1 と PowerShell 7 の両方で実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Andon.ps1
pwsh -NoProfile -File .\tests\Test-Andon.ps1
```

`*.ps1` は UTF-8 BOM 付き・CRLF で保存します。BOM がないと、Windows PowerShell 5.1 が日本語を読み違えます。AI で開発するときの規約は [`AGENTS.md`](AGENTS.md) にあります。

## セキュリティ

脆弱性は公開の Issue に書かず、[SECURITY.md](SECURITY.md) の手順で非公開で報告してください。

## License

[MIT](LICENSE)
