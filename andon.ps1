#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code の対話セッションを一覧し、許可待ち・質問待ち・完了を目立たせる小さなウィンドウ。

.DESCRIPTION
    状態の正本は公式の `claude agents --json`（status: busy / waiting / idle）である。
    Claude Code は状態が変わるたびに `<設定ディレクトリ>/sessions/<pid>.json` を書き換えるので、
    その名前と更新時刻だけを見て、変化があったときに `claude agents --json` を呼ぶ。
    ファイルの中身は読まない。同じ場所にある *.key には触れない。

    Codex（OpenAI の Codex CLI）のセッションも出す。Codex の状態は、Codex の hooks で受け取る。トレイのメニューの
    「Codex の状態を出す」で、~/.codex/hooks.json に andon の hook（andon-codex-hook.ps1）を足したり消したりする
    （ほかの hook は変えない）。hook は、セッションごとの状態を %LOCALAPPDATA%\andon\codex に書き、andon は、そのフォルダの
    ファイル名と更新時刻を見て、変わったら読む。andon は Codex のプロセスにも、Codex のサーバー（デーモン）にも繋がない。
    Codex のセッションは、クリックで作業フォルダを VS Code で開く。ただし、Codex のプロセスがターミナルの中の codex.exe なら
    （共有のデーモンや VS Code の拡張機能で動いていなければ）、Claude のセッションと同じく、そのウィンドウを探して前面に出す。
    VS Code の拡張機能のセッションは、待機なら出さない。

    - waiting（許可待ち・質問待ち）を赤、busy から idle に変わった未確認のもの（完了）を黄で上に並べる。
      busy（実行中）の行は薄い緑にする。
    - VS Code の拡張機能のパネルなど、SDK から動かしているセッションは、待機中（確認済み）なら出さない。
      拡張機能は、パネルを閉じても claude を終了させず、待機中のまま残すため。
    - タスクバーには出さず、通知領域（タスクトレイ）のアイコンの色で状態を示す。
      待ちがあれば赤、完了があれば黄、全部が実行中なら緑、それ以外（実行中と待機が混ざる、0 件など）は灰。
      × で閉じるとトレイに隠れる。終了はトレイの右クリックのメニューから行う。
    - トレイのメニューの「ログオン時に起動」で、スタートアップのショートカットを作ったり消したりする。
      インストールした andon だけで出す。チェックは、ショートカットがあり、タスク マネージャーで無効にしていないこと。
    - ウィンドウの位置と大きさ、「常に手前」を HKCU\Software\tbshiki\andon に覚え、次に起動したときに戻す。
      動かし終えたとき、大きさを変え終えたとき、「常に手前」を切り替えたとき、終わるときに保存する。
      覚えた位置が画面の外なら、一番近い画面に収める。読めなければ既定（主画面の右下）。
    - トレイのメニューの「テーマ」で、ライト・ダーク・Windows に合わせる（既定）を選ぶ。選んだものも同じ場所に覚える。
      Windows に合わせるときは、Windows のアプリ モードが変わったら、すぐに塗り直す。ライトは、これまでと同じ見た目。
    - トレイのメニューの「縦表示」で、1 件を 3 段（上の段に状態と経過、中の段にセッション名、下の段にフォルダ）で出す一覧に切り替える。
      縦に細長いウィンドウ向け。フォルダが入りきらなければ、途中を「…」で省略して最後のフォルダ名を残す。選んだものも同じ場所に覚える。
      切り替えても、ウィンドウの位置と大きさは変えない。
    - 新しい待ちや完了が出たとき、このウィンドウが前面になければ Windows の通知を出す。
      通知をクリックすると、そのセッションを開く。送り元は、プロセスにアプリ ID（tbshiki.andon）を付け、
      その表示名を HKCU に登録して「andon」と表示させる。
      ID はプロセス全体に付くので、andon のためだけに起動した PowerShell で動かしたときだけ付ける。
    - ウィンドウを表示していれば、タイトルバーも点滅させる。点滅は、andon を前面に出したときのほか、
      きっかけになったセッションのウィンドウを前面に出したときや、そのセッションが待ちでも完了でもなくなったときに止める。
      VS Code のウィンドウは題名のフォルダ名や workspace 名で、VS Code の外のターミナルのウィンドウはウィンドウそのもので見分ける。
    - 行をクリックすると、そのセッションを開く。VS Code の外のターミナル（Windows Terminal、cmd や PowerShell のウィンドウ）で
      動いていれば、そのウィンドウを前面に出す（最小化していれば元に戻す）。どのウィンドウかは、セッションのプロセスから親へたどり、
      コンソールを映しているウィンドウで決める。VS Code の中（統合ターミナル、拡張機能のパネル）のセッションと、ウィンドウが
      分からないセッション（background のセッションを含む）は、cwd を含む *.code-workspace（なければ repository の root）を
      VS Code で開く。既に開いているウィンドウがあれば、そのウィンドウが前面に出る。ターミナルのタブまでは選ばない。
    - Orca の区画（ターミナル）で動いているセッションは、Orca のウィンドウを前面に出す。区画のコンソールは映しているウィンドウが
      分からないので、さらに親へたどり、ウィンドウを持つ Orca.exe で決める。そのうえで、Orca の CLI（その Orca.exe と同じフォルダの
      resources\bin\orca.exe）でターミナルの一覧を裏で取り、作業フォルダを含む worktree に同じ種類のエージェント（Claude か Codex）の
      ターミナルが 1 つだけなら、そのタブに切り替える。見分けられなければ、ウィンドウを前面に出すだけにする。
    - VS Code（code.cmd）が見つからなくても起動する。そのときは、VS Code のウィンドウもそのまま前面に出し、
      ウィンドウが分からないセッションは、クリックで既読にするだけにする。VS Code を探すのは起動したときだけ。
    - install.ps1 がアップデートや削除の前に終わらせられるよう、名前付きのイベント（Local\andon-exit）の合図を受けたら終わる。
    - 起動して少し後と、その後 1 日 1 回、GitHub の Release（releases/latest）に新しい版があるかを確かめる。
      あれば、トレイのメニューに「アップデート（v<版>）」を出し、起動ごとに 1 回だけ通知する。自動では入れ替えない。
      通知のクリックとトレイの「アップデート」は、どちらもアップデートするかを尋ねる画面を出す。「アップデートする」を選んだときだけ
      zip を落とし、Release が示す sha256 と照らして展開し、新しい版の install.ps1 を見えるコンソールで起動して終わる。-NoUpdateCheck を付けたときと、andon.ps1 の隣に .git があるとき
      （clone で開発しているとき）は確かめない。

.PARAMETER FallbackSec
    更新時刻に変化がなくても `claude agents --json` を呼ぶ間隔（秒）。
    Codex の hook の記録を、変化がなくても読み直す間隔にも使う（Codex のプロセスが終わったセッションを消すため）。

.PARAMETER ScanMs
    sessions/*.json の名前と更新時刻を見る間隔（ミリ秒）。長くすると、状態の変化に気付くのが遅れる。
    経過時間の表示は 5 秒ごとに更新するので、それより長くはできない。

.PARAMETER NoUpdateCheck
    新しい版があるかを確かめない（GitHub に通信しない）。

.EXAMPLE
    Start-Process conhost.exe '--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\andon.ps1'
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 600)]
    [int]$FallbackSec = 30,

    [ValidateRange(200, 5000)]
    [int]$ScanMs = 1000,

    [switch]$NoUpdateCheck
)

# 版（MAJOR.MINOR.PATCH）。Release の tag（v<版>）と同じにする。install.ps1 はこの行から版を読む
$script:AndonVersion = '0.3.0'
# 新しい版を確かめる GitHub のリポジトリ
$script:AndonRepository = 'tbshiki/andon'

# ---------------------------------------------------------------------------
# 状態の管理（GUI に依存しない部分。ドットソースして単体で確かめられる）
# ---------------------------------------------------------------------------

$script:State = @{}        # pid -> エントリ

function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertFrom-SessionJson {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'claude agents --json の出力が空です' }
    # 前後に通知などの行が混ざっても読めるよう、行頭の [ と行末の ] の組を順に試し、JSON として読めるものを使う
    $starts = @([regex]::Matches($Json, '(?m)^[ \t]*\[') | ForEach-Object { $_.Index + $_.Length - 1 })
    $ends = @([regex]::Matches($Json, '\][ \t]*\r?$', 'Multiline') | ForEach-Object { $_.Index })
    [array]::Reverse($ends)
    foreach ($start in $starts) {
        foreach ($end in $ends) {
            if ($end -lt $start) { break }
            try { $parsed = ConvertFrom-Json -InputObject $Json.Substring($start, $end - $start + 1) -ErrorAction Stop }
            catch { continue }
            # Windows PowerShell 5.1 は配列を 1 つのオブジェクトとして返すので、ここで展開する
            return , @(foreach ($x in $parsed) { $x })
        }
    }
    throw 'claude agents --json の出力が JSON 配列ではありません'
}

function New-StateEntry {
    <# 一覧に初めて出たセッション。起動時点で idle のものは、いつ終わったか分からないので既読として扱う #>
    param([string]$Key, [string]$Status, $StartedAt, [datetime]$Now)
    $entry = [pscustomobject]@{
        Key = $Key; Status = $Status; Since = $null; Unread = ($Status -eq 'waiting')
        Name = ''; Cwd = ''; Kind = ''; WaitingFor = ''; AlertAt = $null
        Sdk = $null   # 拡張機能のパネルなど、ターミナルではなく SDK から動かしているか。$null は未判定
        StartedAt = $StartedAt
        CodexAt = $null   # Codex のセッションの、最後に当てたイベントの時刻（Update-CodexState）
        # Codex のセッションの、Codex のプロセス（PID と起動時刻（UTC の Ticks））と、その種類（terminal、daemon、vscode）
        HostPid = 0; HostStart = [long]0; HostKind = ''
    }
    if ($entry.Unread) { $entry.AlertAt = $Now }
    return $entry
}

function Set-EntryStatus {
    <# セッションの状態を変える。新しく待ち・完了（busy から idle）になったら $true #>
    param($Entry, [string]$Status, [datetime]$Now)
    if ($Entry.Status -eq $Status) { return $false }
    $prev = $Entry.Status
    $Entry.Status = $Status
    $Entry.Since = $Now
    if ($Status -eq 'waiting' -or ($Status -eq 'idle' -and $prev -eq 'busy')) {
        $Entry.Unread = $true
        $Entry.AlertAt = $Now
        return $true
    }
    $Entry.Unread = $false   # busy に戻った = 誰かが応答した。waiting -> idle は手元で拒否した場合
    return $false
}

function Update-SessionState {
    <# claude agents --json の一覧を取り込み、新しく「待ち」か「完了」になったセッションがあれば $true を返す。
       Codex のセッション（キーが codex: で始まるもの）は Update-CodexState が扱うので、ここでは消さない #>
    param([object[]]$Sessions, [datetime]$Now)
    $alert = $false
    $alive = @{}
    foreach ($s in $Sessions) {
        $procId = Get-JsonValue $s 'pid'
        if (-not $procId) { continue }   # プロセスが終わった background セッションは扱わない
        $key = [string]$procId
        $alive[$key] = $true
        $status = Get-JsonValue $s 'status'
        if (-not $status) { $status = 'unknown' }
        $startedAt = Get-JsonValue $s 'startedAt'

        $entry = $script:State[$key]
        # 終わったセッションの PID を新しいセッションが使い回したときは、前の状態を引き継がない
        if ($entry -and $null -ne $startedAt -and $null -ne $entry.StartedAt -and $entry.StartedAt -ne $startedAt) {
            $entry = $null
        }
        if (-not $entry) {
            $entry = New-StateEntry -Key $key -Status $status -StartedAt $startedAt -Now $Now
            $script:State[$key] = $entry
            if ($entry.Unread) { $alert = $true }
        }
        elseif (Set-EntryStatus -Entry $entry -Status $status -Now $Now) { $alert = $true }
        $entry.Name = [string](Get-JsonValue $s 'name')
        $entry.Cwd = [string](Get-JsonValue $s 'cwd')
        $entry.Kind = [string](Get-JsonValue $s 'kind')
        $entry.WaitingFor = [string](Get-JsonValue $s 'waitingFor')
        if ($null -ne $startedAt) { $entry.StartedAt = $startedAt }
    }
    foreach ($k in @($script:State.Keys)) {
        if (-not (Test-CodexKey $k) -and -not $alive.ContainsKey($k)) { $script:State.Remove($k) }
    }
    return $alert
}

function Get-Rank {
    param($Entry)
    if ($Entry.Status -eq 'waiting') { return 0 }
    if ($Entry.Status -eq 'idle' -and $Entry.Unread) { return 1 }
    if ($Entry.Status -eq 'busy') { return 2 }
    return 3
}

function Get-StatusLabel {
    param($Entry)
    switch ($Entry.Status) {
        'waiting' {
            if ($Entry.WaitingFor -eq 'permission prompt') { return '許可待ち' }
            if ($Entry.WaitingFor -eq 'input needed') { return '質問待ち' }
            if ($Entry.WaitingFor) { return "待ち（$($Entry.WaitingFor)）" }
            return '待ち'
        }
        'idle' { if ($Entry.Unread) { return '完了' } else { return '待機' } }
        'busy' { return '実行中' }
        default { return [string]$Entry.Status }
    }
}

function Test-SdkCommandLine {
    <# プロセスの起動引数から、ターミナルではなく SDK（VS Code の拡張機能のパネルなど）が動かしているセッションかを判定する。
       claude agents --json はどちらも kind: interactive として返すので、起動引数で区別する #>
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }
    return [regex]::IsMatch($CommandLine, '(?:^|\s)--input-format(?:=|\s+)"?stream-json\b')
}

function Get-ProcessCommandLine {
    <# プロセスの起動引数。取れなければ $null #>
    param([int]$Id)
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction Stop
        if ($p) { return [string]$p.CommandLine }
    }
    catch { }
    return $null
}

function Test-SessionVisible {
    <# 拡張機能のパネルのセッションは、パネルを閉じても待機中のまま残るので、待機中（確認済み）なら一覧に出さない #>
    param($Entry)
    return -not ($Entry.Sdk -and (Get-Rank $Entry) -eq 3)
}

function Get-AlertLevel {
    <# トレイのアイコンの色を決める。待ちがあれば waiting、完了があれば done、全部が実行中なら busy、それ以外は none。
       実行中と待機が混ざるとき、セッションが 0 件のときは none。$Entries には一覧に出すものだけを渡す
       （一覧に出さない拡張機能のパネルの待機は、緑を止めない） #>
    param([object[]]$Entries)
    $ranks = @(foreach ($e in $Entries) { Get-Rank $e })
    if ($ranks -contains 0) { return 'waiting' }
    if ($ranks -contains 1) { return 'done' }
    if ($ranks.Count -gt 0 -and @($ranks | Where-Object { $_ -ne 2 }).Count -eq 0) { return 'busy' }
    return 'none'
}

function Get-AlertNotice {
    <# 時刻 $Now に新しく待ち・完了になったセッションから、通知の題・本文と、クリックで開くセッションを作る。なければ $null #>
    param([object[]]$Entries, [datetime]$Now, [int]$MaxLines = 3)
    $hits = @($Entries | Where-Object { $_.AlertAt -eq $Now -and (Get-Rank $_) -le 1 } |
            Sort-Object @{ Expression = { Get-Rank $_ } }, @{ Expression = { $_.Key } })
    if ($hits.Count -eq 0) { return $null }
    $lines = foreach ($e in ($hits | Select-Object -First $MaxLines)) {
        $title = $e.Name
        if (-not $title -and $e.Cwd) { $title = Split-Path -Leaf $e.Cwd }
        if (-not $title) { $title = $e.Key }
        '{0}: {1}' -f (Get-StatusLabel $e), $title
    }
    if ($hits.Count -gt $MaxLines) { $lines = @($lines) + ('ほか {0} 件' -f ($hits.Count - $MaxLines)) }
    $text = @($lines) -join "`n"
    if ($text.Length -gt 250) { $text = $text.Substring(0, 249) + '…' }   # 通知の本文は 255 文字まで
    # 題は、先頭のセッションで決める（Claude Code か Codex か）
    $tool = 'Claude Code'
    if (Test-CodexKey $hits[0].Key) { $tool = 'Codex' }
    $heading = "$tool が完了しました"
    if ((Get-Rank $hits[0]) -eq 0) { $heading = "$tool が待っています" }
    return [pscustomobject]@{ Title = $heading; Text = $text; Key = $hits[0].Key }
}

function Get-PendingFlashKeys {
    <# 点滅のきっかけになったセッション（キー -> ウィンドウの見分け方。Get-FlashMark）のうち、まだ点滅を続ける理由があるもの。
       終わったもの、待ちでも完了でもなくなったもの、そのセッションのウィンドウが前面にあるものは外す。
       VS Code の外のターミナルのセッション（Window あり）は前面のウィンドウ（$ForegroundWindow）で、それ以外は前面の
       VS Code のウィンドウの題名（$ForegroundTitle。前面が VS Code でなければ空）で見分ける #>
    param([hashtable]$FlashKeys, [hashtable]$State, [string]$ForegroundTitle, [long]$ForegroundWindow = 0)
    $keep = @{}
    foreach ($k in @($FlashKeys.Keys)) {
        $e = $State[$k]
        if (-not $e -or (Get-Rank $e) -gt 1) { continue }
        $mark = $FlashKeys[$k]
        if ($mark.Window) {
            if ($ForegroundWindow -ne 0 -and [long]$mark.Window -eq $ForegroundWindow) { continue }
        }
        elseif (Test-VSCodeWindowTitle -Title $ForegroundTitle -RootName $mark.RootName) { continue }
        $keep[$k] = $mark
    }
    return $keep
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 60) { return '{0}秒' -f [int][Math]::Floor($Span.TotalSeconds) }
    if ($Span.TotalMinutes -lt 60) { return '{0}分' -f [int][Math]::Floor($Span.TotalMinutes) }
    return '{0}時間{1}分' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes
}

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return Join-Path $env:USERPROFILE '.claude'
}

function Get-SessionSignature {
    <# sessions/*.json の名前と更新時刻だけで作る署名。中身は読まない。*.key は対象にしない #>
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return '' }
    $parts = foreach ($f in [IO.Directory]::GetFiles($Path, '*.json')) {
        '{0}:{1}' -f [IO.Path]::GetFileName($f), [IO.File]::GetLastWriteTimeUtc($f).Ticks
    }
    return ($parts | Sort-Object) -join '|'
}

# ---------------------------------------------------------------------------
# VS Code のウィンドウの特定
# ---------------------------------------------------------------------------

function Test-PathUnder {
    param([string]$Path, [string]$Root)
    $p = $Path.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    return ($p -ieq $r) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function ConvertFrom-Jsonc {
    <# JSONC（コメントと末尾のカンマを許す JSON。*.code-workspace の形式）を読む。文字列の中は変えない #>
    param([string]$Text)
    $keepStrings = {
        param($m)
        if ($m.Value.StartsWith('"')) { return $m.Value }
        return ''
    }
    # コメントを先に消す。カンマの後にコメントが続くと、末尾のカンマと判定できないため
    $json = [regex]::Replace($Text, '"(?:[^"\\]|\\.)*"|//[^\r\n]*|/\*[\s\S]*?\*/', $keepStrings)
    $json = [regex]::Replace($json, '"(?:[^"\\]|\\.)*"|,(?=\s*[\]}])', $keepStrings)
    return ConvertFrom-Json -InputObject $json -ErrorAction Stop
}

function Get-WorkspaceFolders {
    <# *.code-workspace の folders[].path を絶対パスで返す。読めなければ空 #>
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $text) { return @() }
    try { $workspace = ConvertFrom-Jsonc $text } catch { return @() }
    $result = @()
    foreach ($folder in @(Get-JsonValue $workspace 'folders')) {
        if ($null -eq $folder) { continue }
        $p = Get-JsonValue $folder 'path'   # リモートの uri だけを持つものは扱わない
        if (-not $p) { continue }
        try { $result += [IO.Path]::GetFullPath([IO.Path]::Combine($dir, [string]$p)) } catch { }
    }
    return $result
}

function Get-WorkspaceFile {
    <# フォルダの直下にある *.code-workspace を名前順に返す #>
    param([string]$Dir)
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
}

function Resolve-VSCodeTarget {
    <# セッションの作業フォルダから、`code` で開く対象（*.code-workspace かフォルダ）を決める #>
    param([string]$Cwd)
    # Claude が作る worktree（<repo>\.claude\worktrees\<name>）は元の repository として扱う
    $base = $Cwd -replace '\\\.claude\\worktrees\\.*$', ''

    # repository の root。git の外なら作業フォルダそのもの。
    # これより上の階層にある workspace は、無関係な物（ダウンロードした物など）を開かないよう、手順 1 では使わない
    $top = $base
    $dir = $base
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $top = $dir; break }
        $dir = Split-Path -Parent $dir
    }

    # 1) 作業フォルダから repository の root まで遡り、*.code-workspace があれば最も近いものを使う
    $dir = $base
    while ($dir) {
        $ws = Get-WorkspaceFile -Dir $dir | Select-Object -First 1
        if ($ws) { return $ws.FullName }
        if ($dir -ieq $top) { break }
        $dir = Split-Path -Parent $dir
    }

    # 2) repository の親フォルダと、その隣のフォルダにある *.code-workspace のうち、folders に repository
    #    （または作業フォルダを含む、その中のフォルダ）を挙げているものを使う（multi-root）。
    #    親フォルダ全体（".." など）のように repository より広いフォルダは数えない。隣の repository の workspace が
    #    すべての兄弟フォルダを取ってしまわないようにするため。複数あれば、作業フォルダに最も近いフォルダを挙げているもの
    $parent = Split-Path -Parent $top
    if ($parent) {
        $candidates = @(Get-WorkspaceFile -Dir $parent) +
            @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
                ForEach-Object { Get-WorkspaceFile -Dir $_.FullName })
        $best = $null
        $bestLength = -1
        foreach ($ws in $candidates) {
            foreach ($folder in (Get-WorkspaceFolders -Path $ws.FullName)) {
                if ((Test-PathUnder -Path $base -Root $folder) -and (Test-PathUnder -Path $folder -Root $top)) {
                    $length = $folder.TrimEnd('\').Length
                    if ($length -gt $bestLength) { $best = $ws.FullName; $bestLength = $length }
                }
            }
        }
        if ($best) { return $best }
    }

    # 3) 見つからなければ repository の root（git の外なら作業フォルダ）を開く。
    #    サブフォルダを開くと、root を開いている既存のウィンドウではなく新しいウィンドウになるため
    return $top
}

function Find-VSCodeTarget {
    <# クリックのたびに決め直す（後から作った workspace もすぐ反映される） #>
    param([string]$Cwd)
    if (-not $Cwd) { return $null }
    return Resolve-VSCodeTarget -Cwd $Cwd
}

function Get-VSCodeRootName {
    <# VS Code がウィンドウの題名に出す、開いているものの名前。workspace はファイル名から拡張子を除いたもの、
       フォルダはフォルダ名。分からなければ $null #>
    param([string]$Target)
    if (-not $Target) { return $null }
    if ($Target -imatch '\.code-workspace$') { $name = [IO.Path]::GetFileNameWithoutExtension($Target) }
    else { $name = Split-Path -Leaf $Target.TrimEnd('\') }
    if (-not $name) { return $null }
    return $name
}

function Test-VSCodeWindowTitle {
    <# VS Code のウィンドウの題名に、開いているものの名前（Get-VSCodeRootName）が入っているか。
       題名は既定で「ファイル - 名前 - Visual Studio Code」で、workspace は「名前 (Workspace)」と出る。
       3 つ以上に分かれるときは、先頭（エディタで開いているファイル）は見ない #>
    param([string]$Title, [string]$RootName)
    if (-not $Title -or -not $RootName) { return $false }
    $parts = @($Title -split ' - ' | ForEach-Object { $_.Trim() })
    if ($parts.Count -ge 3) { $parts = $parts[1..($parts.Count - 1)] }
    foreach ($p in $parts) {
        if ($p -ieq $RootName -or $p.StartsWith($RootName + ' (', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Find-CodeCmd {
    $cmd = Get-Command code.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
            (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Find-CodeExe {
    <# code.cmd（<VS Code>\bin\code.cmd）の隣の Code.exe を返す。なければ $null #>
    param([string]$CodeCmd)
    if (-not $CodeCmd) { return $null }
    $exe = Join-Path (Split-Path -Parent (Split-Path -Parent $CodeCmd)) 'Code.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    return $null
}

function ConvertTo-ArgumentString {
    <# 1 つの引数を、CommandLineToArgvW の規則で元に戻る形に引用する。
       Windows のパスは " を含まないので、閉じる " の直前の \ を重ねるだけでよい（"C:\" は C:" になってしまう） #>
    param([string]$Value)
    return '"' + ($Value -replace '(\\+)$', '$1$1') + '"'
}

function Start-VSCode {
    <# VS Code に workspace かフォルダを開かせる。開いているウィンドウがあれば、VS Code がそれを前面に出す #>
    param([string]$Target, [string]$CodeExe, [string]$CodeCmd)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.Arguments = ConvertTo-ArgumentString $Target
    if ($CodeExe) {
        # code.cmd は cmd.exe を通るので、パスの %VAR% が展開されてしまう。Code.exe に直接渡す
        $psi.FileName = $CodeExe
        # 引き継ぐと Code.exe が Node として動き、パスをスクリプトとして実行しようとする
        $psi.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
    }
    else {
        $psi.FileName = $CodeCmd
        $psi.CreateNoWindow = $true
    }
    $p = [Diagnostics.Process]::Start($psi)
    if ($p) { $p.Dispose() }
}

# ---------------------------------------------------------------------------
# セッションを映しているウィンドウの特定（VS Code の外のターミナル）
# ---------------------------------------------------------------------------

function Find-SessionConsoleWindow {
    <# セッション（PID $Id）を映しているウィンドウを、プロセスの一覧（ProcessId、ParentProcessId、CreationDate、Name）と、
       コンソールのウィンドウの一覧（Get-ConsoleWindowList）から探す。見つからなければ $null。
       セッションから親へたどり、最初にコンソールのウィンドウを持つプロセスで決める。Windows は、コンソールのウィンドウを、
       そのコンソールを作ったプロセス（シェルなど）のものとして返すため。
       - ConsoleWindowClass（conhost が自分で描くコンソール）は、そのウィンドウ
       - PseudoConsoleWindow（Windows Terminal や VS Code のターミナルが持つ、隠れたウィンドウ）は、その持ち主（映しているウィンドウ）
       見えていないウィンドウと、持ち主のない PseudoConsoleWindow は、映しているウィンドウが分からないので $null（それより上はたどらない）。
       ただし、Orca の区画（ターミナル）は、持ち主のない PseudoConsoleWindow を持つ。そのときは、さらに親へたどり、先祖に
       見えるウィンドウを持つ Orca（$AppWindows にあるもの）がいれば、その Orca のウィンドウにする（Find-OrcaWindow。D-131）。
       たどる途中で VS Code（$CodeProcessName）に着いたら、VS Code が動かしているセッション（拡張機能のパネルなど）なので $null。
       親は、子より前に起動したものだけをたどる（終わった親の PID が使い回されていても、無関係なプロセスをたどらない）。
       見つかれば、Handle（前面に出すウィンドウ）と、そのウィンドウが VS Code のものか（IsCode）と、Orca のウィンドウなら
       その Orca.exe のパス（OrcaPath。Orca の CLI を探すのに使う。Orca でなければ $null）を返す。
       親のプロセスでは決めない。VS Code のターミナルから別のウィンドウ（Windows Terminal など）で開いたシェルは、親をたどると
       VS Code に着くが、映しているのはそのウィンドウのため #>
    param([object[]]$Processes, [object[]]$Windows, [int]$Id, [string]$CodeProcessName = 'Code', [object[]]$AppWindows = @())
    $byId = @{}
    foreach ($p in $Processes) { if ($null -ne $p) { $byId[[int]$p.ProcessId] = $p } }
    $cur = $byId[$Id]
    for ($depth = 0; $cur -and $depth -lt 32; $depth++) {
        $curId = [int]$cur.ProcessId
        if ($depth -gt 0 -and [IO.Path]::GetFileNameWithoutExtension([string]$cur.Name) -ieq $CodeProcessName) { return $null }
        foreach ($w in $Windows) {
            if ($null -eq $w -or [int]$w.ProcessId -ne $curId) { continue }
            if ($w.ClassName -eq 'ConsoleWindowClass') {
                if (-not $w.Visible) { return $null }
                return [pscustomobject]@{ Handle = [long]$w.Handle; IsCode = $false; OrcaPath = $null }
            }
            if ($w.ClassName -eq 'PseudoConsoleWindow') {
                if (-not [long]$w.OwnerHandle -or -not $w.OwnerVisible) {
                    return Find-OrcaWindow -ById $byId -Start $cur -AppWindows $AppWindows -CodeProcessName $CodeProcessName
                }
                $owner = $byId[[int]$w.OwnerProcessId]
                $isCode = [bool]($owner -and [IO.Path]::GetFileNameWithoutExtension([string]$owner.Name) -ieq $CodeProcessName)
                # 持ち主が Orca のウィンドウなら（Orca が区画のコンソールに持ち主を付けるようになったとき）、タブも選べるようにする
                $orcaPath = $null
                if ($owner -and [IO.Path]::GetFileNameWithoutExtension([string]$owner.Name) -ieq $script:OrcaProcessName) {
                    foreach ($a in $AppWindows) {
                        if ($a -and [int]$a.ProcessId -eq [int]$owner.ProcessId) { $orcaPath = [string]$a.Path; break }
                    }
                }
                return [pscustomobject]@{ Handle = [long]$w.OwnerHandle; IsCode = $isCode; OrcaPath = $orcaPath }
            }
        }
        $parent = $byId[[int]$cur.ParentProcessId]
        if (-not (Test-ParentProcess -Child $cur -Parent $parent)) { return $null }
        $cur = $parent
    }
    return $null
}

function Test-ParentProcess {
    <# $Parent が $Child の親としてたどってよいプロセスか。子より後に起動した「親」は、終わった親の PID の使い回しなので、たどらない #>
    param($Child, $Parent)
    return [bool]($Parent -and [int]$Parent.ProcessId -ne [int]$Child.ProcessId -and $null -ne $Child.CreationDate -and
        $null -ne $Parent.CreationDate -and $Parent.CreationDate -le $Child.CreationDate)
}

$script:OrcaProcessName = 'Orca'   # Orca のプロセス名（Orca.exe）

function Find-OrcaWindow {
    <# Orca の区画で動いているセッションの、Orca のウィンドウを探す（D-131）。$Start（持ち主のない PseudoConsoleWindow を持つ
       プロセス）から親へたどり、見えるウィンドウを持つ Orca のプロセス（$AppWindows にあるもの）に着けば、そのウィンドウを返す。
       区画を動かす Orca（daemon-host）はウィンドウを持たないので、その親（Orca の本体）まで、たどり続ける。
       Orca に着かなければ、映しているウィンドウが分からないので $null。たどる途中で VS Code に着いても $null。
       $ById は ProcessId -> プロセス。$AppWindows は Get-OrcaWindowList の形（ProcessId、Handle、Path） #>
    param([hashtable]$ById, $Start, [object[]]$AppWindows, [string]$CodeProcessName = 'Code')
    $cur = $Start
    for ($depth = 0; $cur -and $depth -lt 32; $depth++) {
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$cur.Name)
        if ($depth -gt 0 -and $name -ieq $CodeProcessName) { return $null }
        if ($name -ieq $script:OrcaProcessName) {
            foreach ($a in $AppWindows) {
                if ($a -and [int]$a.ProcessId -eq [int]$cur.ProcessId -and [long]$a.Handle) {
                    return [pscustomobject]@{ Handle = [long]$a.Handle; IsCode = $false; OrcaPath = [string]$a.Path }
                }
            }
        }
        $parent = $ById[[int]$cur.ParentProcessId]
        if (-not (Test-ParentProcess -Child $cur -Parent $parent)) { return $null }
        $cur = $parent
    }
    return $null
}

function Initialize-SessionWindowType {
    <# コンソールのウィンドウを数え、ウィンドウを前面に出す型（AndonSessionWindow）を定義する。
       AndonNative と別の型にするのは、AndonAppId と同じ理由（同じセッションに前の版の型が残っていると、定義し直せない）。
       Windows PowerShell 5.1 は C# 5 でコンパイルするので、それより新しい書き方を使わない #>
    if ('AndonSessionWindow' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class AndonConsoleWindow {
    public long Handle;
    public string ClassName;
    public int ProcessId;
    public bool Visible;
    public long OwnerHandle;
    public int OwnerProcessId;
    public bool OwnerVisible;
}
public static class AndonSessionWindow {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // コンソールのウィンドウ。ConsoleWindowClass は conhost が自分で描くコンソール、PseudoConsoleWindow は Windows Terminal や
    // VS Code のターミナルが持つ隠れたウィンドウ（持ち主が、映しているウィンドウ）。どちらも、コンソールを作ったプロセスのものとして返る
    public static List<AndonConsoleWindow> GetConsoleWindows() {
        List<AndonConsoleWindow> list = new List<AndonConsoleWindow>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            string cls = sb.ToString();
            if (cls != "ConsoleWindowClass" && cls != "PseudoConsoleWindow") return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            IntPtr owner = GetWindow(h, 4);   // GW_OWNER
            uint ownerPid = 0;
            if (owner != IntPtr.Zero) GetWindowThreadProcessId(owner, out ownerPid);
            AndonConsoleWindow w = new AndonConsoleWindow();
            w.Handle = h.ToInt64();
            w.ClassName = cls;
            w.ProcessId = (int)pid;
            w.Visible = IsWindowVisible(h);
            w.OwnerHandle = owner.ToInt64();
            w.OwnerProcessId = (int)ownerPid;
            w.OwnerVisible = owner != IntPtr.Zero && IsWindowVisible(owner);
            list.Add(w);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // ウィンドウを前面に出す。最小化していれば元に戻す。andon が前面にないとき（通知のクリックなど）は Windows が断ることがあるので、
    // 前面のウィンドウの入力に一時的につないでから、もう一度試す。前面に出せたら true
    public static bool Show(long handle) {
        IntPtr h = new IntPtr(handle);
        if (!IsWindow(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        if (SetForegroundWindow(h) && GetForegroundWindow() == h) return true;
        IntPtr fg = GetForegroundWindow();
        uint unused;
        uint fgThread = fg == IntPtr.Zero ? 0u : GetWindowThreadProcessId(fg, out unused);
        uint self = GetCurrentThreadId();
        bool attached = fgThread != 0u && fgThread != self && AttachThreadInput(self, fgThread, true);
        try {
            BringWindowToTop(h);
            SetForegroundWindow(h);
        }
        finally {
            if (attached) AttachThreadInput(self, fgThread, false);
        }
        return GetForegroundWindow() == h;
    }
}
'@
}

function Get-ConsoleWindowList {
    <# コンソールのウィンドウ（ConsoleWindowClass と PseudoConsoleWindow）の一覧。Find-SessionConsoleWindow に渡す。
       1 件だけのときに配列でなくならないよう、呼ぶ側は @() で囲む #>
    Initialize-SessionWindowType
    return @([AndonSessionWindow]::GetConsoleWindows())
}

function Get-OrcaWindowList {
    <# Orca のプロセスのうち、見えるウィンドウ（MainWindowHandle）を持つものの一覧（ProcessId、Handle、Path）。
       Find-SessionConsoleWindow に渡す。Orca が動いていなければ空。1 件だけのときに配列でなくならないよう、呼ぶ側は @() で囲む。
       実行ファイルのパスが読めなければ、Path は $null（ウィンドウは前面に出せるが、CLI が見つからないのでタブは選ばない） #>
    $result = @()
    foreach ($p in @(Get-Process -Name $script:OrcaProcessName -ErrorAction SilentlyContinue)) {
        try {
            $h = $p.MainWindowHandle.ToInt64()
            if ($h -ne 0) {
                $path = $null
                try { $path = [string]$p.Path } catch { }
                $result += [pscustomobject]@{ ProcessId = [int]$p.Id; Handle = [long]$h; Path = $path }
            }
        }
        catch { }
        finally { $p.Dispose() }
    }
    return $result
}

function Get-SessionWindowProcessId {
    <# ウィンドウを探す起点のプロセス（Find-SessionConsoleWindow の $Id）。探さないセッションは 0。
       - Claude のセッションは、セッションのプロセス。background のセッション（claude agents --json の kind が interactive でないもの）は、
         起動したターミナルで動いていないので探さない（README のとおり、作業フォルダを VS Code で開く）。kind が分からなければ、
         対話のセッションとして探す
       - Codex のセッションは、Codex のプロセスがターミナルの中の codex.exe（HostKind が terminal）のときだけ、そのプロセス（D-127）。
         共有のデーモン（daemon）と VS Code の拡張機能（vscode）は、どのターミナルで動いているかが分からないので探さない #>
    param($Entry)
    if ($Entry.Kind -eq 'codex') {
        if ($Entry.HostKind -eq 'terminal' -and [int]$Entry.HostPid -gt 0) { return [int]$Entry.HostPid }
        return 0
    }
    if ($Entry.Kind -and $Entry.Kind -ne 'interactive') { return 0 }
    return [int]$Entry.Key
}

function Find-SessionWindow {
    <# 今のプロセスとウィンドウから、セッションを映しているウィンドウを探す（Find-SessionConsoleWindow）。見つからなければ $null。
       $Processes、$Windows、$AppWindows を渡せば、それを使う（点滅を始めるときに、何件かをまとめて調べるため）。
       どのセッションで探すかは Get-SessionWindowProcessId。Codex のプロセスは、起動時刻が記録と違えば（PID の使い回し）探さない #>
    param($Entry, [string]$CodeProcessName = 'Code', [object[]]$Processes = $null, [object[]]$Windows = $null, [object[]]$AppWindows = $null)
    $id = Get-SessionWindowProcessId $Entry
    if ($id -le 0) { return $null }
    if ($null -eq $Processes) {
        $Processes = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name -ErrorAction Stop)
    }
    if ($Entry.Kind -eq 'codex' -and [long]$Entry.HostStart -gt 0) {
        $self = @($Processes | Where-Object { $null -ne $_ -and [int]$_.ProcessId -eq $id }) | Select-Object -First 1
        if (-not $self -or $null -eq $self.CreationDate) { return $null }
        $start = ([datetime]$self.CreationDate).ToUniversalTime().Ticks
        if ([Math]::Abs($start - [long]$Entry.HostStart) -ge [TimeSpan]::TicksPerSecond) { return $null }
    }
    if ($null -eq $Windows) { $Windows = @(Get-ConsoleWindowList) }
    if ($null -eq $AppWindows) { $AppWindows = @(Get-OrcaWindowList) }
    return Find-SessionConsoleWindow -Processes $Processes -Windows $Windows -Id $id -CodeProcessName $CodeProcessName -AppWindows $AppWindows
}

function Get-SessionAgent {
    <# Orca がターミナルに付けるエージェントの種類（orca terminal list --json の agentIdentity）のうち、このセッションのもの #>
    param($Entry)
    if ($Entry.Kind -eq 'codex') { return 'codex' }
    return 'claude'
}

function ConvertFrom-OrcaTerminalList {
    <# orca terminal list --json の出力から、ターミナルの一覧（result.terminals）を返す。ok でなければ、読めなければ例外。
       一覧が切れていれば（result.truncated）も例外。同じ worktree の 2 つ目が切れて 1 つに見え、別のタブを選ぶおそれがあるため #>
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'orca terminal list --json の出力が空です' }
    $start = $Json.IndexOf('{')
    $end = $Json.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { throw 'orca terminal list --json の出力が JSON ではありません' }
    $o = ConvertFrom-Json -InputObject $Json.Substring($start, $end - $start + 1) -ErrorAction Stop
    if ((Get-JsonValue $o 'ok') -ne $true) { throw 'orca terminal list --json が失敗しました' }
    $result = Get-JsonValue $o 'result'
    if ((Get-JsonValue $result 'truncated') -eq $true) { throw 'orca terminal list --json の一覧が切れています' }
    return , @(foreach ($t in @(Get-JsonValue $result 'terminals')) { if ($null -ne $t) { $t } })
}

function Select-OrcaTerminal {
    <# Orca のターミナルの一覧（ConvertFrom-OrcaTerminalList）から、セッションのタブを選ぶ（D-124、D-131）。
       エージェントの種類（agentIdentity）が $Agent で、セッションの作業フォルダ $Cwd を含む worktree にあるもののうち、
       最も深い worktree のものが 1 つだけなら、その handle。なければ、2 つ以上あって見分けられなければ $null。
       handle は CLI の引数に渡すので、英数字で始まり、英数字と _ . : - だけのものに限る（ほかの形なら $null）。
       Orca はパスを C:/… の形で返すので、/ を \ にし、大文字・小文字を区別せずに比べる #>
    param([object[]]$Terminals, [string]$Cwd, [string]$Agent)
    if (-not $Cwd -or -not $Agent) { return $null }
    $path = $Cwd.Replace('/', '\')
    $best = @()
    $bestLength = -1
    foreach ($t in $Terminals) {
        if ($null -eq $t) { continue }
        if ([string](Get-JsonValue $t 'agentIdentity') -ine $Agent) { continue }
        if ((Get-JsonValue $t 'orphaned') -eq $true) { continue }
        $handle = [string](Get-JsonValue $t 'handle')
        $root = [string](Get-JsonValue $t 'worktreePath')
        if (-not $handle -or -not $root) { continue }
        $root = $root.Replace('/', '\')
        if (-not (Test-PathUnder -Path $path -Root $root)) { continue }
        $length = $root.TrimEnd('\').Length
        if ($length -gt $bestLength) { $best = @($handle); $bestLength = $length }
        elseif ($length -eq $bestLength) { $best += $handle }
    }
    # 形の違う handle も数えてから確かめる（除いてから数えると、残ったもう 1 つを選んでしまうため）
    if ($best.Count -eq 1 -and $best[0] -cmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]*$') { return $best[0] }
    return $null
}

function Get-OrcaCliPath {
    <# Orca の CLI（orca.exe）のパス。ウィンドウを持つ Orca.exe と同じフォルダの resources\bin\orca.exe（D-131）。
       PATH は見ない（別の orca を起動しないため）。なければ $null #>
    param([string]$OrcaPath)
    if (-not $OrcaPath) { return $null }
    $dir = Split-Path -Parent $OrcaPath
    if (-not $dir) { return $null }
    $cli = Join-Path $dir 'resources\bin\orca.exe'
    if (Test-Path -LiteralPath $cli -PathType Leaf) { return $cli }
    return $null
}

function New-OrcaCliStartInfo {
    <# Orca の CLI を、ウィンドウを出さずに起動する情報。andon を Orca の区画から起動したときに、区画の環境変数（ORCA_ で始まるもの。
       今の区画や、繋ぐ先の Orca を示す）が CLI に渡らないよう、消してから渡す。$Capture なら標準出力を受け取る #>
    param([string]$Cli, [string[]]$Arguments, [switch]$Capture)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Cli
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ArgumentString $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:USERPROFILE
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$name -like 'ORCA_*') { $psi.EnvironmentVariables.Remove([string]$name) }
    }
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    }
    return $psi
}

function Get-FlashMark {
    <# 点滅を止めるときの、セッションのウィンドウの見分け方。VS Code の外のターミナルで動いていれば、そのウィンドウ（Window）。
       そうでなければ、VS Code のウィンドウの題名に出る名前（RootName）。$SessionWindow は Find-SessionWindow の結果 #>
    param($Entry, $SessionWindow)
    if ($SessionWindow -and -not $SessionWindow.IsCode) {
        return [pscustomobject]@{ RootName = $null; Window = [long]$SessionWindow.Handle }
    }
    return [pscustomobject]@{ RootName = (Get-VSCodeRootName (Find-VSCodeTarget -Cwd $Entry.Cwd)); Window = [long]0 }
}

function Test-DedicatedProcess {
    <# プロセスの起動引数に、このスクリプト（andon.ps1）があるか。README の起動方法やスタートアップのショートカットのように、
       andon のためだけに起動した PowerShell なら $true。対話で使っているシェルで直接動かしたときは $false #>
    param([string[]]$Arguments, [string]$ScriptName)
    if (-not $ScriptName) { return $false }
    $pattern = '(^|[\\/])' + [regex]::Escape($ScriptName) + '$'
    foreach ($a in $Arguments) {
        if ($a -and [regex]::IsMatch($a.Trim('"', "'"), $pattern, 'IgnoreCase')) { return $true }
    }
    return $false
}

function Register-AppUserModelId {
    <# アプリ ID に、通知の送り元として出す表示名を登録する（HKCU なので管理者の権限は要らない）。登録できたら $true。
       登録しないと、Windows は ID の文字列をそのまま送り元に出す #>
    param([string]$Id, [string]$DisplayName, [string]$Root = 'HKCU:\Software\Classes\AppUserModelId')
    try {
        $key = Join-Path $Root $Id
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name DisplayName -Value $DisplayName -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Get-ProcessDescendant {
    <# $Processes（ProcessId、ParentProcessId、CreationDate を持つもの。Win32_Process の一覧）から、$Id のプロセスの子孫を、
       止める順（深いものから）に返す。$StartTime は $Id のプロセスの起動時刻。
       親より前に起動したプロセスは、子として扱わない。Windows は親が終わっても子の ParentProcessId を書き換えないので、
       親の PID が使い回されると、無関係なプロセスが子に見えるため。起動時刻が分からないものも扱わない #>
    param([object[]]$Processes, [int]$Id, [datetime]$StartTime)
    $result = @()
    foreach ($p in $Processes) {
        if ($null -eq $p -or [int]$p.ParentProcessId -ne $Id -or [int]$p.ProcessId -eq $Id) { continue }
        if ($null -eq $p.CreationDate -or $p.CreationDate -lt $StartTime) { continue }
        $result += @(Get-ProcessDescendant -Processes $Processes -Id ([int]$p.ProcessId) -StartTime $p.CreationDate)
        $result += $p
    }
    return $result
}

function Stop-ProcessTree {
    <# プロセスと、その子孫のプロセスを止める。claude が .cmd の場合、cmd.exe だけを止めると node が残るため。
       $StartTime は $Id のプロセスの起動時刻（Process.StartTime）。渡さなければ、いま動いているそのプロセスの起動時刻を使う。
       どちらも分からなければ（もう終わっていれば）、子孫は止めない。子孫を起動時刻で見分けられず、無関係なプロセスを止めうるため #>
    param([int]$Id, $StartTime = $null)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    if ($null -eq $StartTime) {
        $self = @($all | Where-Object { [int]$_.ProcessId -eq $Id })
        if ($self.Count -gt 0) { $StartTime = $self[0].CreationDate }
    }
    if ($null -ne $StartTime) {
        foreach ($p in @(Get-ProcessDescendant -Processes $all -Id $Id -StartTime ([datetime]$StartTime))) {
            try { (Get-Process -Id ([int]$p.ProcessId) -ErrorAction Stop).Kill() } catch { }
        }
    }
    try { (Get-Process -Id $Id -ErrorAction Stop).Kill() } catch { }
}

# ---------------------------------------------------------------------------
# アップデートの確認（GitHub の Release）
# ---------------------------------------------------------------------------

function Test-NewerVersion {
    <# $Version が $Current より新しい版か。どちらかが MAJOR.MINOR.PATCH の形でなければ $false #>
    param([string]$Version, [string]$Current)
    if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Current -notmatch '^\d+\.\d+\.\d+$') { return $false }
    try { return ([version]$Version) -gt ([version]$Current) }
    catch { return $false }   # 数が大きすぎて版として読めない
}

function Get-UpdateInfo {
    <# releases/latest の応答（ConvertFrom-Json したもの）から、入れられる新しい版を返す。なければ $null。
       - 公開済み（下書きでも pre-release でもない）で、immutable（公開したあとは asset と tag を変えられない）の Release だけを使う
       - tag は v<MAJOR.MINOR.PATCH> で、$CurrentVersion より新しいもの
       - zip は andon-<版>.zip。落とす場所は、このリポジトリのその tag の Release に限る。sha256 の digest がないものは使わない #>
    param($Release, [string]$CurrentVersion, [string]$Repository = $script:AndonRepository)
    if ($null -eq $Release) { return $null }
    foreach ($flag in @(@('draft', $false), @('prerelease', $false), @('immutable', $true))) {
        $value = Get-JsonValue $Release $flag[0]
        if ($value -isnot [bool] -or $value -ne $flag[1]) { return $null }
    }
    $tag = [string](Get-JsonValue $Release 'tag_name')
    $m = [regex]::Match($tag, '^v(\d+\.\d+\.\d+)$')
    if (-not $m.Success) { return $null }
    $version = $m.Groups[1].Value
    if (-not (Test-NewerVersion -Version $version -Current $CurrentVersion)) { return $null }

    $name = "andon-$version.zip"
    $url = "https://github.com/$Repository/releases/download/$tag/$name"
    $asset = $null
    foreach ($a in @(Get-JsonValue $Release 'assets')) {
        if ($null -ne $a -and [string](Get-JsonValue $a 'name') -ceq $name) { $asset = $a; break }
    }
    if (-not $asset) { return $null }
    if ([string](Get-JsonValue $asset 'browser_download_url') -cne $url) { return $null }
    $d = [regex]::Match([string](Get-JsonValue $asset 'digest'), '^sha256:([0-9a-fA-F]{64})$')
    if (-not $d.Success) { return $null }
    return [pscustomobject]@{
        Version = $version
        ZipUrl  = $url
        Sha256  = $d.Groups[1].Value.ToLowerInvariant()
    }
}

function Get-UpdatePrompt {
    <# アップデートするかを尋ねる画面の文。通知のクリックとトレイの「アップデート」の両方で、同じ画面を出す #>
    param([string]$Version, [string]$CurrentVersion)
    return (@(
            "andon v$Version があります（今のバージョンは v$CurrentVersion）。"
            ''
            'アップデートは、いま起動している andon を終了して新しいバージョンをインストールして起動しなおします。'
        ) -join "`r`n")
}

function Test-UpdateCheckEnabled {
    <# 新しい版を確かめるか。-NoUpdateCheck を付けたとき（$Disabled）と、andon.ps1 の隣に .git があるとき
       （clone で開発しているとき）は確かめない。worktree では .git がファイルなので、種類は問わない #>
    param([string]$ScriptDir, [bool]$Disabled)
    if ($Disabled -or -not $ScriptDir) { return $false }
    return -not (Test-Path -LiteralPath (Join-Path $ScriptDir '.git'))
}

function New-UpdateWorkDir {
    <# アップデートの zip を展開するフォルダ（<一時フォルダ>\andon-update-<版>-<乱数>）を作る。
       前のアップデートで残ったフォルダ（andon-update-*）は、消せれば消す #>
    param([string]$Version, [string]$TempDir = [IO.Path]::GetTempPath())
    foreach ($old in @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter 'andon-update-*' -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
    $dir = Join-Path $TempDir ('andon-update-{0}-{1}' -f $Version, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Expand-UpdatePackage {
    <# 落とした zip（$Bytes）を確かめて $WorkDir に展開し、展開した install.ps1 のパスを返す。確かめられなければ例外。
       - sha256 が、Release が示す digest（$Sha256）と同じか
       - 直下に andon.ps1 と install.ps1 があるか。フォルダやパスを含む項目（展開で別の場所に書かせるもの）は拒む
       配るファイルの一覧（install.ps1 の Get-AndonPayload）とは照らさない。配るファイルを足した版も入れられるようにするため。
       余分なファイルがあっても、新しい版の install.ps1 は自分の一覧にあるファイルしか置かない #>
    param([byte[]]$Bytes, [string]$Sha256, [string]$WorkDir, [long]$MaxBytes = 16MB)
    if (-not $Bytes -or $Bytes.Length -eq 0) { throw 'zip が空です' }
    if ($Bytes.Length -gt $MaxBytes) { throw 'zip が大きすぎます' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    if (-not $Sha256 -or $actual -ne $Sha256.ToLowerInvariant()) { throw 'zip の sha256 が、Release が示す値と違います' }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $stream = New-Object IO.MemoryStream(, $Bytes)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            $entries = @{}   # 名前の大文字小文字を区別しない（Windows のファイル名と同じ）
            $total = 0
            foreach ($e in $zip.Entries) {
                if ($e.FullName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "zip に扱えない項目があります: $($e.FullName)" }
                if ($entries.ContainsKey($e.FullName)) { throw "zip に同じ名前の項目が 2 つあります: $($e.FullName)" }
                $entries[$e.FullName] = $e
                $total += $e.Length
            }
            if ($total -gt $MaxBytes) { throw 'zip を展開すると大きすぎます' }
            foreach ($required in @('andon.ps1', 'install.ps1')) {
                if (-not $entries.ContainsKey($required)) { throw "zip に $required がありません" }
            }
            if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
            foreach ($e in $entries.Values) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $WorkDir $e.FullName), $false)
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $stream.Dispose() }
    return Join-Path $WorkDir 'install.ps1'
}

function Get-UpdateCommand {
    <# 展開した新しい版の install.ps1 を、見えるコンソールで実行するコマンド。andon はこれを起動して終わる。
       - 引数は付けない。どの版の install.ps1 も、引数なしで実行すればアップデートになる（ショートカットの引数とスタートアップは引き継ぐ）
       - install.ps1 が失敗したら（終了コードが 0 でなければ）、理由を読めるよう、Enter キーを押すまで閉じない。
         成功したら、結果を読めるよう少し待ってから閉じる
       - パスの引用を誤らないよう、-EncodedCommand で渡す。単一引用符の中では、U+2018 や U+2019 なども ' として扱われるので重ねる #>
    param([string]$InstallScript, [string]$SystemRoot = $env:SystemRoot)
    $quoted = $InstallScript -replace '([''\u2018\u2019\u201A\u201B])', '$1$1'
    $command = @"
`$Host.UI.RawUI.WindowTitle = 'andon のアップデート'
try { & '$quoted'; `$code = `$LASTEXITCODE } catch { Write-Host (`$_.Exception.Message) -ForegroundColor Red; `$code = 1 }
if (`$null -eq `$code) { `$code = 0 }
if (`$code -ne 0) { [void](Read-Host 'アップデートできませんでした。Enter キーで閉じます') } else { Start-Sleep -Seconds 3 }
exit `$code
"@
    return [pscustomobject]@{
        FilePath  = Join-Path $SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    }
}

# ---------------------------------------------------------------------------
# ログオン時に起動（トレイのメニュー）。スタートアップのショートカットがあるかないかを、そのまま設定として使う。
# 関数の名前は install.ps1 と重ねない（テストは andon.ps1 と install.ps1 を同じスコープにドットソースする）
# ---------------------------------------------------------------------------

function Get-LogonStartupLayout {
    <# インストール先、スタートメニューとスタートアップのショートカット、タスク マネージャーの「スタートアップ アプリ」での
       有効・無効を Windows が記録するキー。install.ps1 の Get-AndonLayout と同じ場所 #>
    return [pscustomobject]@{
        InstallDir  = Join-Path $env:LOCALAPPDATA 'Programs\andon'
        StartMenu   = Join-Path ([Environment]::GetFolderPath('Programs')) 'andon.lnk'
        Startup     = Join-Path ([Environment]::GetFolderPath('Startup')) 'andon.lnk'
        ApprovedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }
}

function Test-LogonStartupAvailable {
    <# トレイのメニューに「ログオン時に起動」を出すか。インストール先の andon.ps1 を動かしていて、
       写す元のスタートメニューのショートカットがあるときだけ出す。clone から動かしているときは出さない #>
    param([string]$ScriptDir, [string]$InstallDir, [string]$StartMenu)
    if (-not $ScriptDir -or -not $InstallDir -or -not $StartMenu) { return $false }
    try {
        if ([IO.Path]::GetFullPath($ScriptDir).TrimEnd('\') -ine [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')) { return $false }
    }
    catch { return $false }
    return (Test-LogonStartupShortcut -Path $StartMenu)
}

function Test-LogonStartupShortcut {
    <# andon.ps1 を起動するショートカットか。同じ名前でも、別のものを起動するショートカットは andon のものとして扱わない #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    try { $arguments = [string]$shell.CreateShortcut($Path).Arguments }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    return [bool]($arguments -match '(?i)[\\/"\s]andon\.ps1')
}

function Test-LogonStartupDisabled {
    <# タスク マネージャーで andon.lnk を無効にした記録があるか。先頭のバイトの下位のビットが 1 なら無効
       （02 が有効、03 が無効。install.ps1 の Test-StartupDisabled と同じ見方） #>
    param([string]$ApprovedKey)
    if (-not $ApprovedKey -or -not (Test-Path -LiteralPath $ApprovedKey)) { return $false }
    $value = (Get-Item -LiteralPath $ApprovedKey).GetValue('andon.lnk')
    return [bool]($value -is [byte[]] -and $value.Length -gt 0 -and ($value[0] -band 1))
}

function Get-LogonStartup {
    <# 「ログオン時に起動」のチェック。スタートアップに andon のショートカットがあり、タスク マネージャーで無効にしていなければ $true #>
    param([string]$Startup, [string]$ApprovedKey)
    if (-not (Test-LogonStartupShortcut -Path $Startup)) { return $false }
    return -not (Test-LogonStartupDisabled -ApprovedKey $ApprovedKey)
}

function Set-LogonStartup {
    <# 「ログオン時に起動」を変える。
       - 入れるとき: スタートメニューのショートカットをスタートアップに写す（andon のものがあれば残す）。
         install.ps1 が作るものと中身が同じになり、リンク先の末尾に付けた引数（-ScanMs など）も揃う
       - 外すとき: スタートアップの andon のショートカットを消す
       どちらでも、Windows が残しているタスク マネージャーの有効・無効の記録を消す。ショートカットを消しても記録は残り、
       入れ直したときに前の「無効」がまた効いてしまうため。記録がなければ、Windows は有効として扱う #>
    param([bool]$Enabled, [string]$StartMenu, [string]$Startup, [string]$ApprovedKey)
    if ($Enabled) {
        if (-not (Test-LogonStartupShortcut -Path $Startup)) {
            if (-not (Test-LogonStartupShortcut -Path $StartMenu)) { throw "スタートメニューに andon のショートカットがありません: $StartMenu" }
            $dir = Split-Path -Parent $Startup
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath $StartMenu -Destination $Startup -Force
        }
    }
    elseif (Test-LogonStartupShortcut -Path $Startup) {
        Remove-Item -LiteralPath $Startup -Force
    }
    # andon のものでない andon.lnk が残っているなら、記録はそのショートカットのものなので触れない
    if ((Test-Path -LiteralPath $Startup -PathType Leaf) -and -not (Test-LogonStartupShortcut -Path $Startup)) { return }
    if ($ApprovedKey -and (Test-Path -LiteralPath $ApprovedKey) -and ((Get-Item -LiteralPath $ApprovedKey).GetValueNames() -contains 'andon.lnk')) {
        Remove-ItemProperty -LiteralPath $ApprovedKey -Name 'andon.lnk'
    }
}

# ---------------------------------------------------------------------------
# 設定（レジストリの HKCU\Software\tbshiki\andon に、値ごとに DWORD で置く）。ウィンドウの位置と大きさ、「常に手前」、テーマ、縦表示。
# 読めなくても、ありえない値でも、既定で動き続ける。関数の名前は install.ps1 と重ねない
# ---------------------------------------------------------------------------

function Get-AndonSettingsKey {
    <# 設定を置くキー。install.ps1 の Remove-AndonRegistry は、アンインストールでこのキーを消す #>
    return 'HKCU:\Software\tbshiki\andon'
}

function Read-AndonSettings {
    <# 覚えた設定を読む。値がない、DWORD でない、ありえない値なら、その組（位置、大きさ、常に手前、テーマ、縦表示）を $null にし、既定を使わせる。
       位置はマイナスもありうる（主画面の左や上の画面）。小さすぎる大きさは、戻すと操作しにくいので使わない。
       キーが読めなくても失敗しない #>
    param([string]$Key, [int]$MinWidth = 160, [int]$MinHeight = 80, [int]$Limit = 100000)
    $raw = @{}
    try {
        if ($Key -and (Test-Path -LiteralPath $Key)) {
            $item = Get-Item -LiteralPath $Key
            $names = $item.GetValueNames()
            foreach ($name in 'Left', 'Top', 'Width', 'Height', 'TopMost', 'Theme', 'Vertical') {
                if ($names -notcontains $name) { continue }
                if ($item.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { continue }
                $raw[$name] = [int]$item.GetValue($name)
            }
        }
    }
    catch { $raw = @{} }
    $s = [pscustomobject]@{ Left = $null; Top = $null; Width = $null; Height = $null; TopMost = $null; Theme = $null; Vertical = $null }
    if ($raw.ContainsKey('Left') -and $raw.ContainsKey('Top') -and
        [Math]::Abs($raw['Left']) -le $Limit -and [Math]::Abs($raw['Top']) -le $Limit) {
        $s.Left = $raw['Left']; $s.Top = $raw['Top']
    }
    if ($raw.ContainsKey('Width') -and $raw.ContainsKey('Height') -and
        $raw['Width'] -ge $MinWidth -and $raw['Height'] -ge $MinHeight -and $raw['Width'] -le $Limit -and $raw['Height'] -le $Limit) {
        $s.Width = $raw['Width']; $s.Height = $raw['Height']
    }
    if ($raw.ContainsKey('TopMost') -and ($raw['TopMost'] -eq 0 -or $raw['TopMost'] -eq 1)) { $s.TopMost = ($raw['TopMost'] -eq 1) }
    if ($raw.ContainsKey('Theme') -and $raw['Theme'] -ge 0 -and $raw['Theme'] -lt $script:ThemeChoices.Count) { $s.Theme = $script:ThemeChoices[$raw['Theme']] }
    if ($raw.ContainsKey('Vertical') -and ($raw['Vertical'] -eq 0 -or $raw['Vertical'] -eq 1)) { $s.Vertical = ($raw['Vertical'] -eq 1) }
    return $s
}

# ---------------------------------------------------------------------------
# テーマ（Windows に合わせる・ライト・ダーク）。設定の Theme には、$script:ThemeChoices の番号を書く。
# 色は R, G, B の配列で持ち、GUI の部分で Color に直す。ライトのウィンドウの色は $null（Windows の既定のまま。これまでと同じ見た目）
# ---------------------------------------------------------------------------

$script:ThemeChoices = @('System', 'Light', 'Dark')   # 0: Windows に合わせる（既定）、1: ライト、2: ダーク

function Get-SystemAppsTheme {
    <# Windows の「アプリ モード」。AppsUseLightTheme が 0 なら Dark、それ以外（1、値がない、読めない）は Light #>
    param([string]$Key)
    try {
        if ($Key -and (Test-Path -LiteralPath $Key)) {
            $item = Get-Item -LiteralPath $Key
            if ($item.GetValueNames() -contains 'AppsUseLightTheme' -and
                $item.GetValueKind('AppsUseLightTheme') -eq [Microsoft.Win32.RegistryValueKind]::DWord -and
                [int]$item.GetValue('AppsUseLightTheme') -eq 0) { return 'Dark' }
        }
    }
    catch { }
    return 'Light'
}

function Resolve-AndonTheme {
    <# 選んだテーマ（System、Light、Dark。それ以外と $null は System）と、Windows のアプリ モードから、使う色の組（Light か Dark）を決める #>
    param([string]$Choice, [string]$SystemTheme)
    if ($Choice -eq 'Light' -or $Choice -eq 'Dark') { return $Choice }
    if ($SystemTheme -eq 'Dark') { return 'Dark' }
    return 'Light'
}

function Get-ThemePalette {
    <# 色の組。Rows は、並び順（Get-Rank）ごとの行の背景（Back）、字（Fore）、太字（Bold）と、縦表示でマウスを乗せたときの背景（Hover。
       ライトは少し暗く、ダークは少し明るく。D-77）。RowLine は、縦表示の行の区切りの線。$null の色は既定のまま #>
    param([string]$Theme)
    if ($Theme -eq 'Dark') {
        return [pscustomobject]@{
            Name = 'Dark'
            Back = @(32, 32, 32); Text = @(235, 235, 235); SubText = @(160, 160, 160)
            List = @(25, 25, 25); ListText = @(235, 235, 235); RowLine = @(55, 55, 55)
            Header = @(43, 43, 43); HeaderText = @(235, 235, 235); HeaderLine = @(70, 70, 70)
            Button = @(55, 55, 55); ButtonHover = @(70, 70, 70); ButtonBorder = @(90, 90, 90)
            Menu = @(43, 43, 43); MenuText = @(235, 235, 235); MenuDisabled = @(130, 130, 130); MenuSelected = @(65, 65, 65); MenuBorder = @(70, 70, 70)
            # Hover は、背景に白を 12% 重ねた色。待機は、灰色の字が読める（コントラスト比 4.5 以上の）明るさに留める
            Rows = @{
                0 = [pscustomobject]@{ Back = @(110, 38, 38); Fore = @(255, 255, 255); Bold = $true; Hover = @(127, 64, 64) }    # 待ち: 暗い赤
                1 = [pscustomobject]@{ Back = @(105, 85, 20); Fore = @(255, 255, 255); Bold = $true; Hover = @(123, 105, 48) }   # 完了: 暗い黄
                2 = [pscustomobject]@{ Back = @(30, 64, 38); Fore = @(235, 235, 235); Bold = $false; Hover = @(56, 86, 64) }     # 実行中: 暗い緑
                3 = [pscustomobject]@{ Back = @(25, 25, 25); Fore = @(140, 140, 140); Bold = $false; Hover = @(37, 37, 37) }     # 待機
            }
        }
    }
    return [pscustomobject]@{
        Name = 'Light'
        Back = $null; Text = $null; SubText = @(105, 105, 105)   # 状態の表示は DimGray（これまでと同じ）
        List = $null; ListText = $null; RowLine = @(225, 225, 225)
        Header = $null; HeaderText = $null; HeaderLine = $null
        Button = $null; ButtonHover = $null; ButtonBorder = $null
        Menu = $null; MenuText = $null; MenuDisabled = $null; MenuSelected = $null; MenuBorder = $null
        # Hover は、背景（待機は白）に黒を 7% 重ねた色
        Rows = @{
            0 = [pscustomobject]@{ Back = @(255, 210, 210); Fore = $null; Bold = $true; Hover = @(237, 195, 195) }
            1 = [pscustomobject]@{ Back = @(255, 240, 180); Fore = $null; Bold = $true; Hover = @(237, 223, 167) }
            2 = [pscustomobject]@{ Back = @(228, 248, 230); Fore = $null; Bold = $false; Hover = @(212, 230, 214) }
            3 = [pscustomobject]@{ Back = $null; Fore = @(128, 128, 128); Bold = $false; Hover = @(237, 237, 237) }      # Gray
        }
    }
}

function Get-ContrastRatio {
    <# 2 つの色（R, G, B）のコントラスト比（WCAG 2）。読みやすさを確かめるのに使う #>
    param([int[]]$Fore, [int[]]$Back)
    $lum = {
        param([int[]]$c)
        $v = foreach ($x in $c) {
            $s = $x / 255.0
            if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
        }
        0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2]
    }
    $a = & $lum $Fore
    $b = & $lum $Back
    return ([Math]::Max($a, $b) + 0.05) / ([Math]::Min($a, $b) + 0.05)
}

function Write-AndonSettings {
    <# 設定を書く。$Values は名前 -> 整数で、DWORD で書く。キーがなければ作る #>
    param([string]$Key, [System.Collections.IDictionary]$Values)
    if (-not $Key) { throw '設定のキーがありません' }
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    foreach ($name in $Values.Keys) {
        New-ItemProperty -LiteralPath $Key -Name $name -PropertyType DWord -Value ([int]$Values[$name]) -Force | Out-Null
    }
}

function Get-WindowPlacement {
    <# ウィンドウの位置と大きさを決める。$Screens は画面の作業領域（タスクバーを除いた範囲。Left、Top、Width、Height を持つもの）で、
       先頭が主画面。$Saved は Read-AndonSettings の結果。
       - 位置を覚えていなければ、主画面の右下（端から $Margin）に置く
       - 位置を覚えていれば、重なりの一番大きい画面（どの画面とも重ならなければ、中心が一番近い画面）の中に収まるよう動かす
       - 大きさは覚えたもの（なければ $DefaultWidth × $DefaultHeight）。画面より大きければ縮める #>
    param($Saved, [object[]]$Screens, [int]$DefaultWidth, [int]$DefaultHeight, [int]$Margin = 8)
    $w = $DefaultWidth
    $h = $DefaultHeight
    if ($null -ne $Saved -and $null -ne $Saved.Width -and $null -ne $Saved.Height) { $w = [int]$Saved.Width; $h = [int]$Saved.Height }
    $hasPosition = $null -ne $Saved -and $null -ne $Saved.Left -and $null -ne $Saved.Top
    # 整数にそろえる（文字列のままだと、+ が連結になって計算が狂う）
    $left = 0
    $top = 0
    if ($hasPosition) { $left = [int]$Saved.Left; $top = [int]$Saved.Top }
    $screen = $Screens[0]
    if ($hasPosition) {
        $best = $null
        $bestArea = 0
        foreach ($s in $Screens) {
            $overlapX = [Math]::Min($left + $w, $s.Left + $s.Width) - [Math]::Max($left, $s.Left)
            $overlapY = [Math]::Min($top + $h, $s.Top + $s.Height) - [Math]::Max($top, $s.Top)
            if ($overlapX -gt 0 -and $overlapY -gt 0 -and [double]$overlapX * $overlapY -gt $bestArea) {
                $best = $s
                $bestArea = [double]$overlapX * $overlapY
            }
        }
        if (-not $best) {
            $bestDistance = [double]::MaxValue
            foreach ($s in $Screens) {
                $dx = ($left + $w / 2.0) - ($s.Left + $s.Width / 2.0)
                $dy = ($top + $h / 2.0) - ($s.Top + $s.Height / 2.0)
                if ($dx * $dx + $dy * $dy -lt $bestDistance) { $best = $s; $bestDistance = $dx * $dx + $dy * $dy }
            }
        }
        $screen = $best
    }
    $w = [Math]::Min($w, $screen.Width)
    $h = [Math]::Min($h, $screen.Height)
    if ($hasPosition) {
        $x = [Math]::Min([Math]::Max($left, $screen.Left), $screen.Left + $screen.Width - $w)
        $y = [Math]::Min([Math]::Max($top, $screen.Top), $screen.Top + $screen.Height - $h)
    }
    else {
        $x = [Math]::Max($screen.Left, $screen.Left + $screen.Width - $w - $Margin)
        $y = [Math]::Max($screen.Top, $screen.Top + $screen.Height - $h - $Margin)
    }
    return [pscustomobject]@{ Left = [int]$x; Top = [int]$y; Width = [int]$w; Height = [int]$h }
}

# ---------------------------------------------------------------------------
# 縦表示（トレイのメニューの「縦表示」。D-35、D-74〜D-79）。1 件を 3 段で出す。上の段に状態（左）と経過（右端）、
# 中の段にセッション名、下の段にフォルダ。設定の Vertical に 1（縦）か 0（横）を書く。行は GUI の部分で描く（Show-VerticalItem）
# ---------------------------------------------------------------------------

function Get-VerticalName {
    <# 縦表示の中の段の文。セッション名。名前がなければ、フォルダの名前（cwd の最後のフォルダ。通知の題と同じ決め方）。
       ドライブの直下などで、フォルダの名前が取れなければ cwd のまま。下の段には、どちらのときも cwd を出す #>
    param([string]$Name, [string]$Cwd)
    if (-not [string]::IsNullOrWhiteSpace($Name)) { return $Name }
    if (-not $Cwd) { return '' }
    $leaf = ''
    try { $leaf = [IO.Path]::GetFileName($Cwd.TrimEnd('\', '/')) }
    catch { }   # パスに使えない文字があれば、cwd のまま出す
    if (-not $leaf) { return $Cwd }
    return $leaf
}

function Get-VerticalRowHeight {
    <# 縦表示の 1 件の高さ。3 段の字（1 段の高さ $LineHeight）と、上下の余白 #>
    param([int]$LineHeight, [int]$Padding)
    return 3 * $LineHeight + 2 * $Padding
}

function Get-VerticalItemLayout {
    <# 縦表示の 1 件の中で、字を置く場所（Left、Top、Width、Height）。$Left、$Top、$Width は、行の場所と幅。
       上の段は、状態を左に、経過を右端に置く（経過は、上の段の幅いっぱいの場所に右寄せで描く）。状態は、経過の幅（$ElapsedWidth）と
       間（$Gap）の分だけ狭めて、重ならないようにする。中の段はセッション名、下の段はフォルダ。幅が足りなければ 0 で止める #>
    param([int]$Left, [int]$Top, [int]$Width, [int]$LineHeight, [int]$Padding, [int]$ElapsedWidth, [int]$Gap)
    $x = $Left + $Padding
    $w = [Math]::Max(0, $Width - 2 * $Padding)
    $y = $Top + $Padding
    $statusWidth = $w
    if ($ElapsedWidth -gt 0) { $statusWidth = [Math]::Max(0, $w - $ElapsedWidth - $Gap) }
    return [pscustomobject]@{
        Status  = [pscustomobject]@{ Left = $x; Top = $y; Width = $statusWidth; Height = $LineHeight }
        Elapsed = [pscustomobject]@{ Left = $x; Top = $y; Width = $w; Height = $LineHeight }
        Name    = [pscustomobject]@{ Left = $x; Top = $y + $LineHeight; Width = $w; Height = $LineHeight }
        Folder  = [pscustomobject]@{ Left = $x; Top = $y + 2 * $LineHeight; Width = $w; Height = $LineHeight }
    }
}

# ---------------------------------------------------------------------------
# Codex のセッション（D-109〜D-115）。Codex の hooks で動く andon-codex-hook.ps1 が、セッションごとの状態を
# %LOCALAPPDATA%\andon\codex\<セッションの ID>.json に書く。andon は、そのフォルダのファイル名と更新時刻を見て、
# 変わったら読む（andon の hook が書いたファイルなので、中身を読む）。Codex のセッションのキーは codex:<セッションの ID>。
# ふつうのターミナルの codex は共有のデーモンの中で動くので、ウィンドウは探さず、作業フォルダを VS Code で開く。
# Codex のプロセスがターミナルの中の codex.exe（HostKind が terminal。Orca の区画の Codex など）なら、Claude と同じく
# そのプロセスからウィンドウを探す（Get-SessionWindowProcessId。D-127）
# ---------------------------------------------------------------------------

$script:CodexKeyPrefix = 'codex:'

# hooks.json を扱う関数と、記録の場所は、hook のスクリプトにある。読めなければ Codex のセッションを出さない
$script:CodexHookScript = Join-Path $PSScriptRoot 'andon-codex-hook.ps1'
$script:CodexHookLoaded = $false
if (Test-Path -LiteralPath $script:CodexHookScript -PathType Leaf) {
    try {
        . $script:CodexHookScript
        $script:CodexHookLoaded = $true
    }
    catch { $script:CodexHookLoaded = $false }
}

function Test-CodexKey {
    param([string]$Key)
    return $Key.StartsWith($script:CodexKeyPrefix, [StringComparison]::Ordinal)
}

function ConvertTo-CodexSession {
    <# hook が書いた記録を、Update-CodexState に渡す形にする。読めないもの、知らない状態のものは $null #>
    param($State)
    $id = [string](Get-JsonValue $State 'SessionId')
    $status = [string](Get-JsonValue $State 'Status')
    if (-not $id -or @('busy', 'waiting', 'idle') -notcontains $status) { return $null }
    return [pscustomobject]@{
        Key = $script:CodexKeyPrefix + $id; Status = $status; WaitingFor = [string](Get-JsonValue $State 'WaitingFor')
        Done = [bool](Get-JsonValue $State 'Done'); Interrupted = [bool](Get-JsonValue $State 'Interrupted')
        Cwd = [string](Get-JsonValue $State 'Cwd'); At = [long](Get-JsonValue $State 'At')
        HostPid = [int](Get-JsonValue $State 'HostPid'); HostStart = [long](Get-JsonValue $State 'HostStart')
        HostKind = [string](Get-JsonValue $State 'HostKind')
    }
}

function Read-CodexSessions {
    <# 記録のフォルダから、Codex のセッションを読む。最後のイベントから $StaleHours 時間たったものと、Codex のプロセスが
       なくなったもの（$IsAlive が $false を返すもの）は、記録を消して除く（SessionEnd が来ないまま終わったときのため）。
       $IsAlive は、Codex のプロセスの PID と起動時刻（UTC の Ticks）を受け取る。読めない記録は、消さずに飛ばす #>
    param([string]$Dir, [datetime]$Now, [scriptblock]$IsAlive, [int]$StaleHours = 24)
    $result = @()
    if (-not [IO.Directory]::Exists($Dir)) { return , $result }
    $limit = $Now.ToUniversalTime().AddHours(-$StaleHours).Ticks
    foreach ($f in [IO.Directory]::GetFiles($Dir, '*.json')) {
        $s = $null
        try { $s = ConvertTo-CodexSession (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f)) -ErrorAction Stop) }
        catch { $s = $null }
        if (-not $s) { continue }
        $dead = $s.At -lt $limit
        if (-not $dead -and $s.HostPid -gt 0 -and $IsAlive) { $dead = -not (& $IsAlive $s.HostPid $s.HostStart) }
        if ($dead) {
            try { [IO.File]::Delete($f) } catch { }
            continue
        }
        $result += $s
    }
    return , $result
}

function Test-CodexHostAlive {
    <# Codex のプロセスがまだ動いているか。起動時刻が違えば、PID が使い回されたものとして $false。起動時刻を読めなければ $true #>
    param([int]$HostPid, [long]$HostStart)
    $p = $null
    try { $p = [Diagnostics.Process]::GetProcessById($HostPid) }
    catch { return $false }
    try {
        if ($HostStart -le 0) { return $true }
        $start = $p.StartTime.ToUniversalTime().Ticks
        return [Math]::Abs($start - $HostStart) -lt [TimeSpan]::TicksPerSecond
    }
    catch { return $true }
    finally { $p.Dispose() }
}

function Update-CodexState {
    <# Codex のセッションの一覧（ConvertTo-CodexSession の形）を取り込み、新しく待ち・完了になったものがあれば $true を返す。
       一覧にない Codex のセッションは消す。Claude のセッションには触れない。
       完了（Stop）は、前の状態によらず未確認にする（PostToolUse を使わないので、許可したあとのターンの終わりも、待ちから
       待機に見えるため）。中断（Interrupt）は既読にする（手元で止めたので）。VS Code の拡張機能のセッションは、
       待機なら一覧に出さない（Sdk。D-112） #>
    param([object[]]$Sessions, [datetime]$Now)
    $alert = $false
    $alive = @{}
    foreach ($s in $Sessions) {
        if (-not $s) { continue }
        $alive[$s.Key] = $true
        $entry = $script:State[$s.Key]
        if (-not $entry) {
            $entry = New-StateEntry -Key $s.Key -Status $s.Status -StartedAt $null -Now $Now
            $entry.Kind = 'codex'   # ウィンドウは、Codex のプロセスがターミナルの中にあるときだけ探す（Get-SessionWindowProcessId）
            $script:State[$s.Key] = $entry
            if ($entry.Unread) { $alert = $true }
        }
        elseif ($entry.CodexAt -ne $s.At) {
            $changed = $false
            if ($s.Done) {
                if ($entry.Status -ne $s.Status) { $entry.Status = $s.Status; $entry.Since = $Now }
                $entry.Unread = $true
                $entry.AlertAt = $Now
                $changed = $true
            }
            elseif (Set-EntryStatus -Entry $entry -Status $s.Status -Now $Now) { $changed = $true }
            if ($s.Interrupted) {
                $entry.Unread = $false
                $entry.AlertAt = $null
                $changed = $false
            }
            if ($changed) { $alert = $true }
        }
        $entry.CodexAt = $s.At
        $entry.Cwd = $s.Cwd
        $entry.WaitingFor = $s.WaitingFor
        $entry.Sdk = ($s.HostKind -eq 'vscode')
        $entry.HostPid = $s.HostPid
        $entry.HostStart = $s.HostStart
        $entry.HostKind = $s.HostKind
    }
    foreach ($k in @($script:State.Keys)) {
        if ((Test-CodexKey $k) -and -not $alive.ContainsKey($k)) { $script:State.Remove($k) }
    }
    return $alert
}

function Clear-CodexState {
    <# Codex のセッションを全部消す（andon の hook を外したとき）。消したものがあれば $true #>
    $removed = $false
    foreach ($k in @($script:State.Keys)) {
        if (Test-CodexKey $k) { $script:State.Remove($k); $removed = $true }
    }
    return $removed
}

# ドットソースされたときは関数の定義だけで止める
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# 起動
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\andon', [ref]$createdNew)
if (-not $createdNew) { return }   # 二重起動しない

# install.ps1 が、ファイルを置き換える前や消す前に andon を終わらせるための合図。timer で見る。
# 作れなくても、install.ps1 がプロセスを止めるだけなので続ける
$script:ExitEvent = $null
try { $script:ExitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\andon-exit') }
catch { }

$script:ClaudeExe = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$script:CodeCmd = Find-CodeCmd
if (-not $script:ClaudeExe) {
    [void][System.Windows.Forms.MessageBox]::Show('claude が PATH に見つかりません。', 'andon')
    return
}
# VS Code（code.cmd）は、なくても起動する。クリックで VS Code を開けないだけ（ターミナルのウィンドウは前面に出せる）
$script:CodeExe = Find-CodeExe -CodeCmd $script:CodeCmd
$script:SessionsDir = Join-Path (Get-ClaudeConfigDir) 'sessions'
# Codex の hook が書く記録のフォルダ。hook のスクリプトがなければ、Codex のセッションを出さない
$script:CodexStateDir = $null
if ($script:CodexHookLoaded) { $script:CodexStateDir = Get-AndonCodexStateDir }

# 通知の送り元を、PowerShell ではなく andon と表示させる。Windows はトレイの通知の送り元を、プロセスのアプリ ID
# （AppUserModelID）から決める。ID は、andon のウィンドウを作る前に付けなければならない。
# 上のメッセージボックスを出したときは、そのまま終わるので ID は要らない。
# 付けられなくても、送り元が PowerShell のままになるだけなので続ける。
# ID はプロセス全体に付き、外せない。対話で使っているシェルで直接動かしたときは、andon を終えたあともシェルに残るので付けない。
# ID は、ほかのアプリと通知の設定が混ざらないよう tbshiki.andon にし、送り元に andon と出るよう表示名を登録する。
# 登録できなければ、ID の文字列がそのまま送り元に出るので、ID を andon にする。
# AndonNative とは別の型にする。同じセッションで前の版の andon を動かしていると、前の版の AndonNative が残っていて、
# 定義し直せないため
if (Test-DedicatedProcess -Arguments ([Environment]::GetCommandLineArgs()) -ScriptName ([IO.Path]::GetFileName($PSCommandPath))) {
    $appId = 'andon'
    if (Register-AppUserModelId -Id 'tbshiki.andon' -DisplayName 'andon') { $appId = 'tbshiki.andon' }
    try {
        if (-not ('AndonAppId' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class AndonAppId {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
        }
        [void][AndonAppId]::SetCurrentProcessExplicitAppUserModelID($appId)
    }
    catch { }
}

if (-not ('AndonNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AndonNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    // FLASHW_ALL | FLASHW_TIMERNOFG: ウィンドウが前面に来るまで点滅させる（タスクバーには出していないので、タイトルバーだけ）
    public static void Flash(IntPtr hwnd) {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = hwnd; f.dwFlags = 3 | 12; f.uCount = 0; f.dwTimeout = 0;
        FlashWindowEx(ref f);
    }
}
'@
}

# 点滅を止めるときに、前面のウィンドウを調べる。AndonNative と別の型にするのは、AndonAppId と同じ理由
if (-not ('AndonWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AndonWindow {
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    // FLASHW_STOP: 点滅を止めて、元の表示に戻す
    public static void StopFlash(IntPtr hwnd) {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = hwnd; f.dwFlags = 0; f.uCount = 0; f.dwTimeout = 0;
        FlashWindowEx(ref f);
    }
    public static uint GetProcessId(IntPtr hWnd) { uint pid; GetWindowThreadProcessId(hWnd, out pid); return pid; }
    public static string GetTitle(IntPtr hWnd) {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@
}

# セッションを映しているターミナルのウィンドウを探し、前面に出す型。起動したときに定義しておく（初めてクリックしたときに待たせない）。
# 定義できなければ、ウィンドウが分からないセッションとして扱う（VS Code で開く）
try { Initialize-SessionWindowType } catch { }

# ダークのとき、タイトルバーと、一覧のスクロールバー・見出しを暗くする。AndonNative と別の型にするのは、AndonAppId と同じ理由
if (-not ('AndonThemeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AndonThemeNative {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string appName, string idList);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // DWMWA_USE_IMMERSIVE_DARK_MODE は、Windows 10 20H1 から 20、それより前は 19
    public static void SetDarkTitleBar(IntPtr hwnd, bool dark) {
        int value = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, 20, ref value, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref value, 4);
        // 枠を描き直させる（SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED）
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
    }
    // theme が null なら、既定の見た目に戻す
    public static void SetTheme(IntPtr hwnd, string theme) { SetWindowTheme(hwnd, theme, null); }
    // 一覧（ListView）の見出しのウィンドウ（LVM_GETHEADER）
    public static IntPtr GetListViewHeader(IntPtr listView) { return SendMessage(listView, 0x101F, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

function Start-Poll {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ClaudeExe
    $psi.Arguments = 'agents --json'
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $script:PollProc = [Diagnostics.Process]::Start($psi)
    # 止めるときに、子孫を起動時刻で見分ける（Stop-ProcessTree）。取れなければ、止めるときに調べる
    $script:PollStartTime = $null
    try { $script:PollStartTime = $script:PollProc.StartTime } catch { }
    $script:PollTask = $script:PollProc.StandardOutput.ReadToEndAsync()
    [void]$script:PollProc.StandardError.ReadToEndAsync()
    $script:PollStarted = Get-Date
}

function Open-Session {
    <# セッションを開く。VS Code の外のターミナルで動いていれば、そのウィンドウを前面に出す。Orca の区画で動いていれば、Orca の
       ウィンドウを前面に出し、Orca の CLI でそのタブに切り替える（D-124。Start-OrcaTabSwitch）。VS Code の中のセッションと、
       ウィンドウが分からないセッションは、作業フォルダを VS Code で開く。VS Code が見つからなければ、VS Code のウィンドウも
       そのまま前面に出し、ウィンドウが分からなければ既読にするだけ #>
    param($Entry)
    $window = $null
    try { $window = Find-SessionWindow -Entry $Entry -CodeProcessName $script:CodeProcessName } catch { }
    if ($window -and (-not $window.IsCode -or -not $script:CodeCmd)) {
        try { [void][AndonSessionWindow]::Show([long]$window.Handle) } catch { }
        if ($window.OrcaPath) {
            try { Start-OrcaTabSwitch -OrcaPath $window.OrcaPath -Cwd $Entry.Cwd -Agent (Get-SessionAgent $Entry) } catch { Stop-OrcaTabSwitch }
        }
        $Entry.Unread = $false
        return
    }
    if (-not $script:CodeCmd) {
        $Entry.Unread = $false
        return
    }
    $target = Find-VSCodeTarget -Cwd $Entry.Cwd
    if (-not $target) { return }
    Start-VSCode -Target $target -CodeExe $script:CodeExe -CodeCmd $script:CodeCmd
    $Entry.Unread = $false
}

# Orca のタブの切り替え（D-124、D-131）。andon の画面を止めないよう、Orca の CLI は裏で動かし、$script:OrcaTimer で受け取る
$script:OrcaSwitch = $null       # 動かしている CLI（Proc、Task、Started、Cwd、Agent、Cli、Phase）
$script:OrcaTimeoutSec = 5       # CLI がこれより長くかかったら、止めてやめる

function Stop-OrcaTabSwitch {
    <# 動かしている Orca の CLI を止める（時間切れのときと、前のクリックの分が残っているうちに次をクリックしたとき）。
       CLI（起動用の orca.exe）が起動した子のプロセスも止める #>
    $s = $script:OrcaSwitch
    $script:OrcaSwitch = $null
    if (-not $s) { return }
    try { if (-not $s.Proc.HasExited) { Stop-ProcessTree -Id $s.Proc.Id -StartTime $s.StartTime } } catch { }
    try { $s.Proc.Dispose() } catch { }
}

function New-OrcaSwitchState {
    <# 動かし始めた Orca の CLI（$script:OrcaSwitch に置くもの） #>
    param($Proc, $Task, [datetime]$Started, [string]$Cwd, [string]$Agent, [string]$Cli, [string]$Phase)
    $startTime = $null
    try { $startTime = $Proc.StartTime } catch { }
    return [pscustomobject]@{
        Proc = $Proc; StartTime = $startTime; Task = $Task; Started = $Started
        Cwd = $Cwd; Agent = $Agent; Cli = $Cli; Phase = $Phase
    }
}

function Start-OrcaTabSwitch {
    <# Orca の CLI で、ターミナルの一覧（orca terminal list --json）を裏で取り始める。受け取ったら（Update-OrcaTabSwitch）、
       セッションのタブが 1 つに決まれば、orca terminal switch で切り替える。CLI が見つからなければ何もしない（ウィンドウを
       前面に出すだけ） #>
    param([string]$OrcaPath, [string]$Cwd, [string]$Agent)
    Stop-OrcaTabSwitch
    $cli = Get-OrcaCliPath -OrcaPath $OrcaPath
    if (-not $cli -or -not $Cwd) { return }
    $p = [Diagnostics.Process]::Start((New-OrcaCliStartInfo -Cli $cli -Arguments @('terminal', 'list', '--json') -Capture))
    if (-not $p) { return }
    $script:OrcaSwitch = New-OrcaSwitchState -Proc $p -Task $p.StandardOutput.ReadToEndAsync() -Started (Get-Date) `
        -Cwd $Cwd -Agent $Agent -Cli $cli -Phase 'list'
    $script:OrcaTimer.Start()
}

function Update-OrcaTabSwitch {
    <# $script:OrcaTimer から呼ぶ。一覧を受け取ったらタブを選んで切り替え、切り替えの CLI が終わるのを待つ。
       $script:OrcaTimeoutSec を過ぎたら止める。失敗したら、何もしない（ウィンドウはもう前面に出してある） #>
    param([datetime]$Now)
    $s = $script:OrcaSwitch
    if (-not $s) { $script:OrcaTimer.Stop(); return }
    if ($s.Phase -eq 'list') {
        if (-not $s.Task.IsCompleted) {
            if (($Now - $s.Started).TotalSeconds -gt $script:OrcaTimeoutSec) { Stop-OrcaTabSwitch }
            return
        }
        $handle = $null
        try { $handle = Select-OrcaTerminal -Terminals (ConvertFrom-OrcaTerminalList $s.Task.Result) -Cwd $s.Cwd -Agent $s.Agent }
        catch { $handle = $null }
        # 出力を読み終えたので、CLI はもう終わるところ。少し待ってから片付ける（終わっていなければ、子のプロセスごと止める）
        try { [void]$s.Proc.WaitForExit(1000) } catch { }
        Stop-OrcaTabSwitch
        if (-not $handle) { $script:OrcaTimer.Stop(); return }
        $p = [Diagnostics.Process]::Start((New-OrcaCliStartInfo -Cli $s.Cli -Arguments @('terminal', 'switch', '--terminal', $handle, '--json')))
        if (-not $p) { $script:OrcaTimer.Stop(); return }
        $script:OrcaSwitch = New-OrcaSwitchState -Proc $p -Task $null -Started $Now -Cwd $s.Cwd -Agent $s.Agent -Cli $s.Cli -Phase 'switch'
        return
    }
    if ($s.Proc.HasExited -or ($Now - $s.Started).TotalSeconds -gt $script:OrcaTimeoutSec) {
        Stop-OrcaTabSwitch
        $script:OrcaTimer.Stop()
    }
}

# Codex のセッション（D-109〜D-115）
$script:CodexSignature = $null        # 記録のフォルダの、ファイル名と更新時刻（Get-SessionSignature）
$script:NextCodexCheck = Get-Date     # 変化がなくても読み直す時刻（Codex のプロセスが終わったセッションを消すため）

function Update-Codex {
    <# Codex の記録のフォルダが変わったか、-FallbackSec たったら読み直す。timer から呼ぶ。
       戻り値は、読み直したか（Changed）と、新しく待ち・完了になったセッションがあるか（Alert） #>
    param([datetime]$Now)
    $r = [pscustomobject]@{ Changed = $false; Alert = $false }
    if (-not $script:CodexStateDir) { return $r }
    $sig = Get-SessionSignature -Path $script:CodexStateDir
    if ($sig -eq $script:CodexSignature -and $Now -lt $script:NextCodexCheck) { return $r }
    $sessions = Read-CodexSessions -Dir $script:CodexStateDir -Now $Now -IsAlive {
        param($HostPid, $HostStart)
        Test-CodexHostAlive -HostPid $HostPid -HostStart $HostStart
    }
    # 読むあいだに消した記録があれば、署名は次の回に変わり、もう一度読む（害はない）
    $script:CodexSignature = $sig
    $script:NextCodexCheck = $Now.AddSeconds($FallbackSec)
    $r.Alert = Update-CodexState -Sessions $sessions -Now $Now
    $r.Changed = $true
    return $r
}

function Get-CodexHooksPath { return Join-Path (Get-AndonCodexHome) 'hooks.json' }

function Set-CodexHooksEnabled {
    <# トレイのメニューの「Codex の状態を出す」。~/.codex/hooks.json に andon の hook を足す（$Enabled）か、消す（D-110）。
       足したら、hook を信頼することと、VS Code を起動し直すことを案内する。消したら、hook が書いた記録と、一覧の Codex の
       セッションも消す。hooks.json を読めないときなどは、例外 #>
    param([bool]$Enabled)
    # 外すと、andon の hook の後ろにあるほかの hook（ほかのアプリのもの）が前に詰まり、Codex で信頼し直しになる（D-116）。
    # そのときは、外す前に確かめる
    $shifted = @()
    if (-not $Enabled) {
        $shifted = @(Get-AndonCodexHooksShifted (Read-AndonCodexHooksFile -Path (Get-CodexHooksPath)))
        if ($shifted.Count -gt 0) {
            $ask = "Codex の hooks で、andon の hook の後ろに、ほかの hook があります（$($shifted -join '、')）。`n`n" +
            "andon の hook を外すと、Codex は、それらの hook を信頼し直すまで動かしません（Codex は、hook の信頼を、並びの位置で覚えているため）。" +
            "外したあと、ターミナルで codex を起動し、/hooks を開いて、確認待ちになった hook を信頼し直してください。`n`n外しますか？"
            $answer = [System.Windows.Forms.MessageBox]::Show($ask, 'andon', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
    }
    Set-AndonCodexHooks -Enabled $Enabled -Path (Get-CodexHooksPath) -Command (Get-AndonCodexHookCommand -ScriptPath $script:CodexHookScript)
    if ($Enabled) {
        $text = "Codex の hooks（$(Get-CodexHooksPath)）に、andon の hook を足しました。`n`n" +
        "Codex のセッションを一覧に出すには、次のことを行ってください。`n" +
        "1. ターミナルで codex を起動し、/hooks を開いて、andon の hook（andon-codex-hook.ps1 を動かすもの）を信頼します。`n" +
        "2. VS Code の Codex 拡張機能で使うときは、VS Code を起動し直します。`n`n" +
        'ターミナルの codex のセッションは、最初のプロンプトを送ったときに一覧に出ます。'
        [void][System.Windows.Forms.MessageBox]::Show($text, 'andon', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($script:CodexStateDir -and [IO.Directory]::Exists($script:CodexStateDir)) {
        foreach ($f in [IO.Directory]::GetFiles($script:CodexStateDir, '*.json')) { try { [IO.File]::Delete($f) } catch { } }
    }
    if (Clear-CodexState) { Update-ListView }
    if ($shifted.Count -gt 0) {
        $done = "andon の hook を外しました。`n`nターミナルで codex を起動し、/hooks を開いて、確認待ちになった hook（$($shifted -join '、')）を信頼し直してください。"
        [void][System.Windows.Forms.MessageBox]::Show($done, 'andon', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

function Invoke-Alert {
    <# 時刻 $Now に新しく待ち・完了になったセッションを、点滅と通知で知らせる。andon が前面にあれば知らせない。
       Claude と Codex が同じ回に知らせたときは、後の通知が前の通知を置き換え、両方のセッションを載せる #>
    param([datetime]$Now)
    if ($form.ContainsFocus) { return }
    if ($form.Visible) { Start-Flash -Now $Now }
    $notice = Get-AlertNotice -Entries @($script:State.Values) -Now $Now
    if ($notice) {
        # 通知をクリックしたら、このセッションを開く。覚えるのは最新の 1 件分でよい。
        # Windows は同じアイコンの通知を新しいもので置き換え、通知センターにも最新の 1 件しか残さないため
        $script:NoticeKey = $notice.Key
        $script:NoticeUpdate = $false
        $tray.ShowBalloonTip(10000, $notice.Title, $notice.Text, [System.Windows.Forms.ToolTipIcon]::None)
    }
}

$script:CodeProcessName = 'Code'
if ($script:CodeExe) { $script:CodeProcessName = [IO.Path]::GetFileNameWithoutExtension($script:CodeExe) }
$script:FlashKeys = @{}   # 点滅のきっかけになったセッション -> そのウィンドウの見分け方（Get-FlashMark）

function Get-ForegroundCodeTitle {
    <# 前面のウィンドウが VS Code なら、その題名。そうでなければ $null #>
    $hwnd = [AndonWindow]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    try {
        $p = Get-Process -Id ([AndonWindow]::GetProcessId($hwnd)) -ErrorAction Stop
        $name = $p.ProcessName
        $p.Dispose()
    }
    catch { return $null }
    if ($name -ine $script:CodeProcessName) { return $null }
    return [AndonWindow]::GetTitle($hwnd)
}

function Start-Flash {
    <# 時刻 $Now に新しく待ち・完了になったセッションのために、andon のウィンドウを点滅させる。
       そのセッションのウィンドウ（VS Code のウィンドウか、VS Code の外のターミナルのウィンドウ）がすでに前面にあれば、点滅させない #>
    param([datetime]$Now)
    try {
        $hits = @($script:State.Values | Where-Object { $_.AlertAt -eq $Now -and (Get-Rank $_) -le 1 })
        $keys = @{}
        if ($hits.Count -gt 0) {
            # ターミナルのウィンドウは、プロセスとウィンドウを 1 回だけ調べて探す。調べられなければ、VS Code の題名で見分ける
            $procs = $null
            $wins = $null
            $apps = $null
            try {
                $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name -ErrorAction Stop)
                $wins = @(Get-ConsoleWindowList)
            }
            catch { $procs = $null }
            # Orca のウィンドウを調べられなくても、ほかのターミナルのセッションは見分ける（Orca のセッションだけ VS Code の題名で見分ける）
            try { $apps = @(Get-OrcaWindowList) } catch { $apps = @() }
            foreach ($e in $hits) {
                $window = $null
                if ($null -ne $procs) {
                    $window = Find-SessionWindow -Entry $e -CodeProcessName $script:CodeProcessName -Processes $procs -Windows $wins -AppWindows $apps
                }
                $keys[$e.Key] = Get-FlashMark -Entry $e -SessionWindow $window
            }
        }
        $keys = Get-PendingFlashKeys -FlashKeys $keys -State $script:State -ForegroundTitle (Get-ForegroundCodeTitle) `
            -ForegroundWindow ([AndonWindow]::GetForegroundWindow().ToInt64())
        if ($keys.Count -eq 0) { return }
        foreach ($k in $keys.Keys) { $script:FlashKeys[$k] = $keys[$k] }
    }
    catch { }   # 調べられなくても点滅はさせる（止めるのは、andon を前面に出したときだけになる）
    [AndonNative]::Flash($form.Handle)
}

function Update-Flash {
    <# 点滅のきっかけになったセッションが、どれも点滅を続ける理由をなくしたら、点滅を止める。
       そのセッションのウィンドウを前面に出した、待ちでも完了でもなくなった、終わった、のいずれか #>
    if ($script:FlashKeys.Count -eq 0) { return }
    if ($form.ContainsFocus) { $script:FlashKeys = @{}; return }   # andon を前面に出すと、Windows が点滅を止める
    try {
        $script:FlashKeys = Get-PendingFlashKeys -FlashKeys $script:FlashKeys -State $script:State -ForegroundTitle (Get-ForegroundCodeTitle) `
            -ForegroundWindow ([AndonWindow]::GetForegroundWindow().ToInt64())
        if ($script:FlashKeys.Count -eq 0) { [AndonWindow]::StopFlash($form.Handle) }
    }
    catch { $script:FlashKeys = @{} }   # 調べられなければ、andon を前面に出すまで点滅を続ける（これまでと同じ）
}

[void][AndonNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'andon'
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9)
$form.TopMost = $true
$form.StartPosition = 'Manual'
$g = $form.CreateGraphics()
$scale = $g.DpiX / 96
$g.Dispose()
$form.ClientSize = New-Object System.Drawing.Size([int](640 * $scale), [int](230 * $scale))
# 覚えた位置と大きさがあれば戻す。なければ主画面の右下。画面の外になっていれば、一番近い画面に収める
$script:SettingsKey = Get-AndonSettingsKey
$script:Settings = Read-AndonSettings -Key $script:SettingsKey
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { -not $_.Primary } | ForEach-Object {
        $area = $_.WorkingArea
        [pscustomobject]@{ Left = $area.Left; Top = $area.Top; Width = $area.Width; Height = $area.Height }
    })
$placement = Get-WindowPlacement -Saved $script:Settings -Screens $screens -DefaultWidth $form.Width -DefaultHeight $form.Height
$form.Bounds = New-Object System.Drawing.Rectangle($placement.Left, $placement.Top, $placement.Width, $placement.Height)
$boldFont = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
# タスクバーには出さず、通知領域（タスクトレイ）のアイコンで状態を示す
$form.ShowInTaskbar = $false

function New-StateIcon {
    <# 状態を示す丸いアイコン。起動時に状態ごとに 1 つ作り、状態が変わったら差し替える #>
    param([System.Drawing.Color]$Color)
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $margin = [Math]::Max(1, [int]($size / 16))
    $d = $size - 2 * $margin - 1
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 0, 0, 0), [float][Math]::Max(1, $size / 16))
    $g.FillEllipse($brush, $margin, $margin, $d, $d)
    $g.DrawEllipse($pen, $margin, $margin, $d, $d)
    $pen.Dispose(); $brush.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}
$script:Icons = @{
    waiting = New-StateIcon ([System.Drawing.Color]::FromArgb(220, 40, 40))
    done    = New-StateIcon ([System.Drawing.Color]::FromArgb(240, 180, 0))
    busy    = New-StateIcon ([System.Drawing.Color]::FromArgb(40, 200, 60))
    none    = New-StateIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))
}
$form.Icon = $script:Icons['none']
# アプリの目印は積層灯、トレイは状態の色。画像がなくてもこれまでのアイコンで動く。
$script:AppIcon = $null
try {
    $script:AppIcon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'andon.ico'), [System.Windows.Forms.SystemInformation]::SmallIconSize)
    $form.Icon = $script:AppIcon
}
catch { }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:Icons['none']
$tray.Text = 'andon'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
# どの PC にどの版が入っているか分かるよう、版を出す
$miVersion = $trayMenu.Items.Add("andon $script:AndonVersion")
$miVersion.Enabled = $false
# 新しい版が見つかったときだけ出す
$miUpdate = $trayMenu.Items.Add('アップデート')
$miUpdate.Visible = $false
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miShow = $trayMenu.Items.Add('表示')
$miTrayRead = $trayMenu.Items.Add('すべて既読')
# 設定の組。「ログオン時に起動」は、インストールした andon だけで出す（clone から動かしているときは出さない）
$sepSettings = New-Object System.Windows.Forms.ToolStripSeparator
[void]$trayMenu.Items.Add($sepSettings)
$miLogon = New-Object System.Windows.Forms.ToolStripMenuItem('ログオン時に起動')
[void]$trayMenu.Items.Add($miLogon)
# Codex の hooks に andon の hook を入れ外しする（D-110）。hook のスクリプトがなければ出さない。Codex を使っていなければ灰色
$miCodex = New-Object System.Windows.Forms.ToolStripMenuItem('Codex の状態を出す')
[void]$trayMenu.Items.Add($miCodex)
$miTheme = New-Object System.Windows.Forms.ToolStripMenuItem('テーマ')
$miThemeItems = @()
foreach ($choice in @(@{ Text = 'ライト'; Name = 'Light' }, @{ Text = 'ダーク'; Name = 'Dark' }, @{ Text = 'Windows に合わせる'; Name = 'System' })) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($choice.Text)
    $mi.Tag = $choice.Name   # クリックでどれを選んだかを Tag で見分ける
    [void]$miTheme.DropDownItems.Add($mi)
    $miThemeItems += $mi
}
[void]$trayMenu.Items.Add($miTheme)
$miVertical = New-Object System.Windows.Forms.ToolStripMenuItem('縦表示')
[void]$trayMenu.Items.Add($miVertical)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $trayMenu.Items.Add('終了')
$script:LogonLayout = Get-LogonStartupLayout
$script:ScriptDir = $PSScriptRoot   # イベントの中では $PSScriptRoot に頼らない
$tray.ContextMenuStrip = $trayMenu
$script:Exiting = $false
$script:NoticeKey = $null
$script:NoticeUpdate = $false   # 最後に出した通知が、新しい版の知らせか（クリックで、アップデートするかを尋ねる）

$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.MultiSelect = $false
$lv.HideSelection = $true
$lv.Activation = 'OneClick'
[void]$lv.Columns.Add('状態', [int](80 * $scale))
[void]$lv.Columns.Add('経過', [int](70 * $scale))
[void]$lv.Columns.Add('セッション', [int](170 * $scale))
[void]$lv.Columns.Add('フォルダ', [int](300 * $scale))

# 縦表示の一覧（D-78、D-79）。見出しのない 1 列の一覧で、行の高さを 3 段分に広げ、行を自分で描く（Show-VerticalItem）。
# 横の一覧とは別に作り、表示する方を入れ替える（広げた行の高さは、一覧を作り直さないと戻せないため）
$script:Vertical = $script:Settings.Vertical -eq $true
$lvV = New-Object System.Windows.Forms.ListView
$lvV.Dock = 'Fill'
$lvV.View = 'Details'
$lvV.HeaderStyle = 'None'
$lvV.FullRowSelect = $true
$lvV.MultiSelect = $false
$lvV.HideSelection = $true
$lvV.Activation = 'OneClick'
$lvV.OwnerDraw = $true
# マウスを乗せた行などを描き直すとき、地の色で消してから描くので、ちらつく。画面の外で描いてから一度に出す（二重バッファ）。
# ListView は DoubleBuffered を LVS_EX_DOUBLEBUFFER として一覧に渡すが、外からは設定できないので、リフレクションで立てる。
# 立てられなくても、少しちらつくだけなので続ける
try { $lvV.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance, NonPublic').SetValue($lvV, $true, $null) }
catch { }
[void]$lvV.Columns.Add('', [int](300 * $scale))   # 幅は、一覧の幅に合わせ直す（Update-VerticalColumn）
$script:VerticalLine = [Math]::Max([System.Windows.Forms.TextRenderer]::MeasureText('漢Ag', $form.Font).Height,
    [System.Windows.Forms.TextRenderer]::MeasureText('漢Ag', $boldFont).Height)
$script:VerticalPadding = [int](4 * $scale)
$script:VerticalGap = [int](8 * $scale)   # 上の段の、状態と経過の間
$script:VerticalHot = -1                  # マウスを乗せている行の番号。なければ -1
# 行の高さは、小さい画像の一覧の、画像の高さまで広がる。画像は描かない（画像の高さは 256 まで）
$verticalRowImages = New-Object System.Windows.Forms.ImageList
$verticalRowImages.ImageSize = New-Object System.Drawing.Size(1, [Math]::Min(256, (Get-VerticalRowHeight -LineHeight $script:VerticalLine -Padding $script:VerticalPadding)))
$lvV.SmallImageList = $verticalRowImages
$lv.Visible = -not $script:Vertical
$lvV.Visible = $script:Vertical

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Top'
$panel.AutoSize = $true
$panel.WrapContents = $false
$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = '常に手前'
$chkTop.Checked = $true
# 覚えた「常に手前」を戻す。切り替えたときの処理（保存）は、あとで付けるので、ここでは保存しない
if ($null -ne $script:Settings.TopMost) {
    $chkTop.Checked = $script:Settings.TopMost
    $form.TopMost = $script:Settings.TopMost
}
$chkTop.AutoSize = $true
$chkTop.Margin = New-Object System.Windows.Forms.Padding(6, 6, 6, 3)
$btnRead = New-Object System.Windows.Forms.Button
$btnRead.Text = 'すべて既読'
$btnRead.AutoSize = $true
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Margin = New-Object System.Windows.Forms.Padding(6, 8, 3, 3)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$panel.Controls.AddRange(@($chkTop, $btnRead, $lblStatus))

# Fill を先、Top を後に追加する（後に追加したものから先に配置される）。横と縦の一覧は、表示している方だけが場所を取る
$form.Controls.Add($lv)
$form.Controls.Add($lvV)
$form.Controls.Add($panel)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('開く')
$miRead = $menu.Items.Add('既読にする')
$lv.ContextMenuStrip = $menu
$lvV.ContextMenuStrip = $menu

# ---------------------------------------------------------------------------
# テーマの塗り分け。ライトは Windows の既定の見た目のまま（これまでと同じ）。ダークは色の組（Get-ThemePalette）で塗る
# ---------------------------------------------------------------------------

$script:PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:ThemeChoice = 'System'
if ($script:Settings.Theme) { $script:ThemeChoice = $script:Settings.Theme }
$script:Palette = Get-ThemePalette -Theme 'Light'   # Update-AndonTheme で決め直す
$script:ThemeApplied = $false
$script:DarkMenuRenderer = $null
$script:DarkMenuFailed = $false
$script:NextThemeCheck = Get-Date

function ConvertTo-ThemeColor {
    param([int[]]$Rgb)
    return [System.Drawing.Color]::FromArgb($Rgb[0], $Rgb[1], $Rgb[2])
}

function Set-ThemeColors {
    <# 背景と字の色を塗る。$null なら Windows の既定に戻す #>
    param($Control, [int[]]$Back, [int[]]$Fore)
    if ($Back) { $Control.BackColor = ConvertTo-ThemeColor $Back } else { $Control.ResetBackColor() }
    if ($Fore) { $Control.ForeColor = ConvertTo-ThemeColor $Fore } else { $Control.ResetForeColor() }
}

function Set-ThemeButton {
    <# ボタンを塗る。ダークでは平らなボタンにする（Windows の標準のボタンは、背景の色を変えても明るく描かれる） #>
    param($Button, $Palette)
    if ($Palette.Button) {
        $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $Button.BackColor = ConvertTo-ThemeColor $Palette.Button
        $Button.ForeColor = ConvertTo-ThemeColor $Palette.Text
        $Button.FlatAppearance.BorderColor = ConvertTo-ThemeColor $Palette.ButtonBorder
        $Button.FlatAppearance.MouseOverBackColor = ConvertTo-ThemeColor $Palette.ButtonHover
        $Button.FlatAppearance.MouseDownBackColor = ConvertTo-ThemeColor $Palette.ButtonBorder
    }
    else {
        $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        $Button.ResetBackColor()
        $Button.ResetForeColor()
        $Button.UseVisualStyleBackColor = $true
    }
}

function Get-DarkMenuRenderer {
    <# ダークのメニューを描くもの。初めて使うときに組み立てる。組み立てられなければ $null（メニューは明るいまま） #>
    if ($script:DarkMenuRenderer) { return $script:DarkMenuRenderer }
    if ($script:DarkMenuFailed) { return $null }
    try {
        if (-not ('AndonMenuRenderer' -as [type])) {
            # PowerShell 7（.NET）では、Windows Forms の型が別のアセンブリに分かれているので、それも参照に加える
            $refs = @([System.Windows.Forms.Form].Assembly.Location, [System.Drawing.Color].Assembly.Location, [System.Drawing.Graphics].Assembly.Location,
                [System.ComponentModel.Component].Assembly.Location)
            foreach ($n in 'System.Windows.Forms.Primitives', 'System.Drawing.Primitives', 'System.ComponentModel.Primitives', 'System.Runtime', 'netstandard', 'System.Private.Windows.Core') {
                $a = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $n } | Select-Object -First 1
                if ($a -and $a.Location) { $refs += $a.Location }
            }
            Add-Type -ReferencedAssemblies @($refs | Sort-Object -Unique) -ErrorAction Stop -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
public class AndonMenuColors : ProfessionalColorTable {
    private readonly Color back, selected, border;
    public AndonMenuColors(Color back, Color selected, Color border) { this.back = back; this.selected = selected; this.border = border; UseSystemColors = false; }
    public override Color ToolStripDropDownBackground { get { return back; } }
    public override Color ImageMarginGradientBegin { get { return back; } }
    public override Color ImageMarginGradientMiddle { get { return back; } }
    public override Color ImageMarginGradientEnd { get { return back; } }
    public override Color MenuBorder { get { return border; } }
    public override Color MenuItemBorder { get { return selected; } }
    public override Color MenuItemSelected { get { return selected; } }
    public override Color MenuItemSelectedGradientBegin { get { return selected; } }
    public override Color MenuItemSelectedGradientEnd { get { return selected; } }
    public override Color MenuItemPressedGradientBegin { get { return selected; } }
    public override Color MenuItemPressedGradientMiddle { get { return selected; } }
    public override Color MenuItemPressedGradientEnd { get { return selected; } }
    public override Color SeparatorDark { get { return border; } }
    public override Color SeparatorLight { get { return border; } }
    public override Color CheckBackground { get { return back; } }
    public override Color CheckSelectedBackground { get { return selected; } }
    public override Color CheckPressedBackground { get { return selected; } }
}
public class AndonMenuRenderer : ToolStripProfessionalRenderer {
    private readonly Color text, disabled;
    public AndonMenuRenderer(AndonMenuColors colors, Color text, Color disabled) : base(colors) { this.text = text; this.disabled = disabled; RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? text : disabled; base.OnRenderItemText(e); }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) { e.ArrowColor = text; base.OnRenderArrow(e); }
    // 既定のチェックの印は黒い画像なので、暗い背景では見えない。明るい線で描く
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Rectangle r = e.ImageRectangle;
        float w = r.Width, h = r.Height;
        PointF[] points = { new PointF(r.Left + w * 0.2f, r.Top + h * 0.52f), new PointF(r.Left + w * 0.42f, r.Top + h * 0.74f), new PointF(r.Left + w * 0.8f, r.Top + h * 0.28f) };
        SmoothingMode saved = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen pen = new Pen(text, Math.Max(1.5f, w / 8f))) { e.Graphics.DrawLines(pen, points); }
        e.Graphics.SmoothingMode = saved;
    }
}
'@
        }
        $p = Get-ThemePalette -Theme 'Dark'
        $colors = New-Object AndonMenuColors((ConvertTo-ThemeColor $p.Menu), (ConvertTo-ThemeColor $p.MenuSelected), (ConvertTo-ThemeColor $p.MenuBorder))
        $script:DarkMenuRenderer = New-Object AndonMenuRenderer($colors, (ConvertTo-ThemeColor $p.MenuText), (ConvertTo-ThemeColor $p.MenuDisabled))
    }
    catch { $script:DarkMenuFailed = $true; return $null }
    return $script:DarkMenuRenderer
}

function Set-DialogTheme {
    <# アップデートを尋ねる画面などを、今の色の組で塗る（ライトなら何もしない） #>
    param($Dialog, [object[]]$Buttons)
    $p = $script:Palette
    if ($p.Name -ne 'Dark') { return }
    try {
        Set-ThemeColors -Control $Dialog -Back $p.Back -Fore $p.Text
        foreach ($b in $Buttons) { Set-ThemeButton -Button $b -Palette $p }
        [AndonThemeNative]::SetDarkTitleBar($Dialog.Handle, $true)
    }
    catch { }   # 塗れなくても、尋ねる画面は使える
}

function Update-AndonTheme {
    <# 選んだテーマと Windows のアプリ モードから色の組を決め、変わったときだけ塗り直す。-Force なら必ず塗り直す #>
    param([switch]$Force)
    $name = Resolve-AndonTheme -Choice $script:ThemeChoice -SystemTheme (Get-SystemAppsTheme -Key $script:PersonalizeKey)
    if (-not $Force -and $script:ThemeApplied -and $script:Palette.Name -eq $name) { return }
    $p = Get-ThemePalette -Theme $name
    $script:Palette = $p
    $script:ThemeApplied = $true
    $dark = $name -eq 'Dark'
    Set-ThemeColors -Control $form -Back $p.Back -Fore $p.Text
    Set-ThemeColors -Control $panel -Back $p.Back -Fore $p.Text
    Set-ThemeColors -Control $chkTop -Back $p.Back -Fore $p.Text
    Set-ThemeButton -Button $btnRead -Palette $p
    $lblStatus.ForeColor = ConvertTo-ThemeColor $p.SubText
    Set-ThemeColors -Control $lv -Back $p.List -Fore $p.ListText
    Set-ThemeColors -Control $lvV -Back $p.List -Fore $p.ListText
    # ダークでは見出しを自分で描く（ライトは Windows の描き方のまま）。縦の一覧は、テーマによらず行を自分で描く
    $lv.OwnerDraw = $dark
    try {
        # スクロールバーと、見出しの右の余白を暗くする。$null で既定の見た目に戻す
        $listTheme = $null
        $headerTheme = $null
        if ($dark) { $listTheme = 'DarkMode_Explorer'; $headerTheme = 'DarkMode_ItemsView' }
        [AndonThemeNative]::SetTheme($lv.Handle, $listTheme)
        [AndonThemeNative]::SetTheme($lvV.Handle, $listTheme)
        $header = [AndonThemeNative]::GetListViewHeader($lv.Handle)
        if ($header -ne [IntPtr]::Zero) { [AndonThemeNative]::SetTheme($header, $headerTheme) }
        [AndonThemeNative]::SetDarkTitleBar($form.Handle, $dark)
    }
    catch { }   # 古い Windows で効かなくても、色は塗れている
    $renderer = $null
    if ($dark) { $renderer = Get-DarkMenuRenderer }
    foreach ($m in @($trayMenu, $menu, $miTheme.DropDown)) {
        if ($renderer) { $m.Renderer = $renderer }
        else { $m.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::ManagerRenderMode }
    }
    Update-ListView
    $lv.Invalidate()
    $lvV.Invalidate()
}

# ダークのときだけ、見出しを自分で描く。行は Windows の描き方のまま（行の色は Update-ListView で付ける）
$lv.Add_DrawColumnHeader({
        param($source, $e)
        $p = $script:Palette
        if ($p.Name -ne 'Dark') { $e.DrawDefault = $true; return }
        $back = New-Object System.Drawing.SolidBrush((ConvertTo-ThemeColor $p.Header))
        $line = New-Object System.Drawing.Pen((ConvertTo-ThemeColor $p.HeaderLine))
        try {
            $b = $e.Bounds
            $e.Graphics.FillRectangle($back, $b)
            $e.Graphics.DrawLine($line, $b.Right - 1, $b.Top + 3, $b.Right - 1, $b.Bottom - 4)
            $e.Graphics.DrawLine($line, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
            $pad = [int](6 * $scale)
            $rect = New-Object System.Drawing.Rectangle(($b.Left + $pad), $b.Top, [Math]::Max(0, $b.Width - $pad - 2), $b.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
            [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $lv.Font, $rect, (ConvertTo-ThemeColor $p.HeaderText), $flags)
        }
        finally { $back.Dispose(); $line.Dispose() }
    })
$lv.Add_DrawItem({ param($source, $e) $e.DrawDefault = $true })
$lv.Add_DrawSubItem({ param($source, $e) $e.DrawDefault = $true })

function Show-VerticalItem {
    <# 縦表示の 1 件を 3 段で描く（D-78、D-79）。上の段に状態と経過（待ちと完了は太字）。中の段にセッション名（入りきらなければ末尾を
       「…」で省略）、下の段にフォルダ（入りきらなければ途中を「…」で省略して最後のフォルダ名を残す。D-75）。中と下の段は太字にしない。
       行の下に区切りの線を引く。選んだ行は、一覧にフォーカスがあるときだけ Windows の強調色にする（横の一覧と同じ）。
       マウスを乗せた行は、色の組の Hover にする（D-77） #>
    param($DrawArgs)
    $item = $DrawArgs.Item
    $g = $DrawArgs.Graphics
    $b = $DrawArgs.Bounds
    $p = $script:Palette
    # 列は一覧の幅に合わせているが、合わせ直す前に描くこともあるので、右端まで塗る
    $rect = New-Object System.Drawing.Rectangle($b.Left, $b.Top, [Math]::Max($b.Width, $lvV.ClientSize.Width - $b.Left), $b.Height)
    $back = $item.BackColor
    $fore = $item.ForeColor
    if ($item.Selected -and $lvV.Focused) {
        $back = [System.Drawing.SystemColors]::Highlight
        $fore = [System.Drawing.SystemColors]::HighlightText
    }
    elseif ($DrawArgs.ItemIndex -eq $script:VerticalHot) {
        $rank = 3
        $entry = $script:State[[string]$item.Tag]
        if ($entry) { $rank = Get-Rank $entry }
        if ($p.Rows[$rank].Hover) { $back = ConvertTo-ThemeColor $p.Rows[$rank].Hover }
    }
    $brush = New-Object System.Drawing.SolidBrush($back)
    $pen = New-Object System.Drawing.Pen((ConvertTo-ThemeColor $p.RowLine))
    try {
        $g.FillRectangle($brush, $rect)
        $g.DrawLine($pen, $rect.Left, $rect.Bottom - 1, $rect.Right, $rect.Bottom - 1)
        $flags = [System.Windows.Forms.TextFormatFlags]'SingleLine, NoPrefix, VerticalCenter'
        $elapsed = ''
        $name = ''
        $folder = ''
        if ($item.SubItems.Count -gt 1) { $elapsed = $item.SubItems[1].Text }
        if ($item.SubItems.Count -gt 2) { $name = $item.SubItems[2].Text }
        if ($item.SubItems.Count -gt 3) { $folder = $item.SubItems[3].Text }
        $elapsedWidth = 0
        if ($elapsed) {
            $elapsedWidth = [System.Windows.Forms.TextRenderer]::MeasureText($g, $elapsed, $item.Font, (New-Object System.Drawing.Size([int]::MaxValue, [int]::MaxValue)), $flags).Width
        }
        $layout = Get-VerticalItemLayout -Left $rect.Left -Top $rect.Top -Width $rect.Width -LineHeight $script:VerticalLine `
            -Padding $script:VerticalPadding -ElapsedWidth $elapsedWidth -Gap $script:VerticalGap
        $toRect = { param($r) New-Object System.Drawing.Rectangle($r.Left, $r.Top, $r.Width, $r.Height) }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $item.Text, $item.Font, (& $toRect $layout.Status), $fore,
            ($flags -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        if ($elapsed) {
            [System.Windows.Forms.TextRenderer]::DrawText($g, $elapsed, $item.Font, (& $toRect $layout.Elapsed), $fore,
                ($flags -bor [System.Windows.Forms.TextFormatFlags]::Right))
        }
        if ($name) {
            [System.Windows.Forms.TextRenderer]::DrawText($g, $name, $lvV.Font, (& $toRect $layout.Name), $fore,
                ($flags -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        }
        if ($folder) {
            [System.Windows.Forms.TextRenderer]::DrawText($g, $folder, $lvV.Font, (& $toRect $layout.Folder), $fore,
                ($flags -bor [System.Windows.Forms.TextFormatFlags]::PathEllipsis))
        }
    }
    finally {
        $brush.Dispose()
        $pen.Dispose()
    }
}

function Set-VerticalHot {
    <# マウスを乗せている縦の一覧の行を $Index（なければ -1）に変え、前の行と新しい行を描き直す #>
    param([int]$Index)
    if ($Index -eq $script:VerticalHot) { return }
    $old = $script:VerticalHot
    $script:VerticalHot = $Index
    foreach ($i in @($old, $Index)) {
        if ($i -lt 0 -or $i -ge $lvV.Items.Count) { continue }
        $r = $lvV.GetItemRect($i)
        $lvV.Invalidate((New-Object System.Drawing.Rectangle(0, $r.Top, $lvV.ClientSize.Width, $r.Height)))
    }
}

function Update-VerticalColumn {
    <# 縦の一覧の列を、一覧の幅（スクロールバーを除く）に合わせる。広いと、横のスクロールバーが出る #>
    $w = $lvV.ClientSize.Width
    if ($w -gt 0 -and $lvV.Columns[0].Width -ne $w) { $lvV.Columns[0].Width = $w }
}

# 縦の一覧は、行を全部 Show-VerticalItem で描く。列（SubItem）は Windows に描かせない（DrawDefault を立てない）
$lvV.Add_DrawItem({
        param($source, $e)
        try { Show-VerticalItem -DrawArgs $e }
        catch { }   # 描けなくても、andon は動き続ける
    })
$lvV.Add_DrawSubItem({ param($source, $e) })
$lvV.Add_MouseMove({
        param($source, $mouse)
        $hit = $lvV.GetItemAt($mouse.X, $mouse.Y)
        $index = -1
        if ($hit) { $index = $hit.Index }
        Set-VerticalHot -Index $index
    })
$lvV.Add_MouseLeave({ Set-VerticalHot -Index -1 })
# 選んだ行は、フォーカスがあるときだけ強調色で描くので、フォーカスが変わったら描き直す
$lvV.Add_GotFocus({ $lvV.Invalidate() })
$lvV.Add_LostFocus({ $lvV.Invalidate() })
# 縦のスクロールバーが出たり消えたり、ウィンドウの大きさを変えたりしたら、列を一覧の幅に合わせる。
# 一覧が大きさを変えている途中で列の幅を変えると、一覧が横のスクロールバーを消さないので、変え終えてから合わせる
$lvV.Add_ClientSizeChanged({
        if ($lvV.IsHandleCreated) { [void]$lvV.BeginInvoke([Action] { Update-VerticalColumn }) }
        else { Update-VerticalColumn }
    })
# ウィンドウの幅を縮めるときは、一覧が縮む前に列を縮める（フォームは、子の大きさを変える前に Layout を出す）。
# 一覧が先に縮むと、合わせ直すまでの間、列の方が広くて横のスクロールバーが一瞬出る。縦のスクロールバーの有無は、今のままと見なす
$form.Add_Layout({
        if (-not $lvV.Visible -or -not $lvV.IsHandleCreated) { return }
        $target = $form.ClientSize.Width - ($lvV.Width - $lvV.ClientSize.Width)
        if ($target -gt 0 -and $target -lt $lvV.Columns[0].Width) { $lvV.Columns[0].Width = $target }
    })

function Get-ActiveList {
    <# 表示している一覧（縦表示なら縦の一覧） #>
    if ($script:Vertical) { return $lvV }
    return $lv
}

function Get-SelectedEntry {
    $list = Get-ActiveList
    if ($list.SelectedItems.Count -eq 0) { return $null }
    return $script:State[[string]$list.SelectedItems[0].Tag]
}

function Update-ListView {
    $now = Get-Date
    $entries = @($script:State.Values | Where-Object { Test-SessionVisible $_ } | Sort-Object `
            @{ Expression = { Get-Rank $_ } }, `
            @{ Expression = { if ($_.Since) { $_.Since } else { [datetime]::MinValue } } })
    $list = Get-ActiveList
    $selectedKey = $null
    if ($list.SelectedItems.Count -gt 0) { $selectedKey = $list.SelectedItems[0].Tag }

    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($e in $entries) {
        $elapsed = ''
        if ($e.Since) { $elapsed = Format-Elapsed ($now - $e.Since) }
        $item = New-Object System.Windows.Forms.ListViewItem((Get-StatusLabel $e))
        [void]$item.SubItems.Add($elapsed)
        # 縦の中の段は、名前がなければフォルダの名前にする（Show-VerticalItem が描く）
        $name = $e.Name
        if ($script:Vertical) { $name = Get-VerticalName -Name $e.Name -Cwd $e.Cwd }
        [void]$item.SubItems.Add($name)
        [void]$item.SubItems.Add($e.Cwd)
        $item.Tag = $e.Key
        # 行の色はテーマの色の組（Get-ThemePalette）から。実行中は見てほしい行ではないので、太字にしない
        $style = $script:Palette.Rows[(Get-Rank $e)]
        if ($style.Back) { $item.BackColor = ConvertTo-ThemeColor $style.Back }
        if ($style.Fore) { $item.ForeColor = ConvertTo-ThemeColor $style.Fore }
        if ($style.Bold) { $item.Font = $boldFont }
        [void]$list.Items.Add($item)
        if ($e.Key -eq $selectedKey) { $item.Selected = $true }
    }
    $list.EndUpdate()
    if ($script:Vertical) { Update-VerticalColumn }

    $pending = @($entries | Where-Object { (Get-Rank $_) -le 1 }).Count
    if ($pending -gt 0) { $form.Text = "andon - 待ち $pending 件" } else { $form.Text = 'andon' }

    # 変わったときだけ差し替える（毎回差し替えると、トレイのアイコンがちらつく）
    $icon = $script:Icons[(Get-AlertLevel $entries)]
    if (-not [object]::ReferenceEquals($tray.Icon, $icon)) {
        $tray.Icon = $icon
        if (-not $script:AppIcon) { $form.Icon = $icon }
    }
    if ($tray.Text -ne $form.Text) { $tray.Text = $form.Text }
}

function Save-WindowSettings {
    <# ウィンドウの位置と大きさ、「常に手前」を保存する。最小化・最大化しているときは、位置と大きさを保存しない
       （最小化したウィンドウの位置は画面の外の値になる）。保存できなくても andon は動き続ける #>
    try {
        $values = [ordered]@{ TopMost = [int]$chkTop.Checked }
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
            $b = $form.Bounds
            $values['Left'] = $b.Left
            $values['Top'] = $b.Top
            $values['Width'] = $b.Width
            $values['Height'] = $b.Height
        }
        Write-AndonSettings -Key $script:SettingsKey -Values $values
    }
    catch { }
}

function Show-AndonWindow {
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $form.Activate()
}

function Switch-AndonWindow {
    if ($form.Visible) { $form.Hide() } else { Show-AndonWindow }
}

function Set-AllRead {
    foreach ($e in $script:State.Values) { $e.Unread = $false }
    Update-ListView
}

function Update-ListLayout {
    <# 縦表示か横表示かに合わせて、表示する一覧を入れ替え、中身を入れ直す。ウィンドウの位置と大きさは変えない（D-76） #>
    $script:VerticalHot = -1
    $hide = $lvV
    if ($script:Vertical) { $hide = $lv }
    $hide.Visible = $false
    $hide.Items.Clear()
    (Get-ActiveList).Visible = $true
    Update-ListView
}

# 新しい版の確認と、アップデートの zip の取得。claude agents --json と同じく、timer で終わったかだけを見て、待たない
$script:UpdateEnabled = Test-UpdateCheckEnabled -ScriptDir $PSScriptRoot -Disabled $NoUpdateCheck.IsPresent
$script:NextUpdateCheck = (Get-Date).AddSeconds(30)   # ログオンの直後は、ネットワークがまだつながっていないことがある
$script:CheckClient = $null
$script:CheckTask = $null
$script:Update = $null           # 見つけた新しい版（Get-UpdateInfo）
$script:NotifiedUpdate = $null   # 通知した版。起動ごとに、同じ版は 1 回だけ知らせる
$script:DownloadClient = $null
$script:DownloadTask = $null
$script:DownloadInfo = $null

function New-UpdateClient {
    <# GitHub に問い合わせる HttpClient。30 秒で諦める。User-Agent は GitHub の API が求める #>
    param([switch]$Api)
    if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http }
    # 古い Windows 10 の Windows PowerShell 5.1 は、TLS 1.2 を使わないことがある。OS に任せているとき（SystemDefault）は変えない
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    if ($protocol -ne 0 -and -not ($protocol -band [Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.MaxResponseContentBufferSize = 16MB
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("andon/$script:AndonVersion")
    if ($Api) {
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
    }
    return $client
}

function Show-UpdateAvailable {
    <# 新しい版をトレイのメニューに出し、その版をまだ知らせていなければ通知する #>
    param($Info)
    $script:Update = $Info
    if (-not $script:DownloadTask) {
        $miUpdate.Text = "アップデート（v$($Info.Version)）"
        $miUpdate.Enabled = $true
        $miUpdate.Visible = $true
    }
    if ($script:NotifiedUpdate -ne $Info.Version) {
        $script:NotifiedUpdate = $Info.Version
        $script:NoticeKey = $null
        $script:NoticeUpdate = $true
        $tray.ShowBalloonTip(10000, 'andon の新しいバージョンがあります',
            ('クリックすると、v{0} にアップデートするかを選べます。あとでアップデートするときは、トレイのメニューの「アップデート（v{0}）」を選びます。' -f $Info.Version),
            [System.Windows.Forms.ToolTipIcon]::None)
    }
}

function Confirm-AndonUpdate {
    <# 新しい版にアップデートするかを尋ねる。「アップデートする」なら $true。Enter で「アップデートする」、Esc で「しない」 #>
    param($Info)
    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = 'andon のアップデート'
        $dlg.Font = $form.Font
        $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.ShowInTaskbar = $true   # andon のウィンドウを隠していても、見失わないように
        $dlg.TopMost = $true
        $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $dlg.AutoSize = $true
        $dlg.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $dlg.Padding = New-Object System.Windows.Forms.Padding([int](12 * $scale))
        if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.AutoSize = $true
        $layout.ColumnCount = 1
        $text = New-Object System.Windows.Forms.Label
        $text.AutoSize = $true
        $text.MaximumSize = New-Object System.Drawing.Size([int](420 * $scale), 0)
        $text.Text = Get-UpdatePrompt -Version $Info.Version -CurrentVersion $script:AndonVersion
        $text.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, [int](12 * $scale))
        $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttons.AutoSize = $true
        $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
        $buttons.Dock = [System.Windows.Forms.DockStyle]::Fill
        $buttons.Margin = New-Object System.Windows.Forms.Padding(0)
        $no = New-Object System.Windows.Forms.Button
        $no.Text = 'しない'
        $no.AutoSize = $true
        $no.DialogResult = [System.Windows.Forms.DialogResult]::No
        $yes = New-Object System.Windows.Forms.Button
        $yes.Text = 'アップデートする'
        $yes.AutoSize = $true
        $yes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $buttons.Controls.AddRange(@($no, $yes))   # 右から並ぶので、「アップデートする」が左、「しない」が右
        $layout.Controls.Add($text)
        $layout.Controls.Add($buttons)
        $dlg.Controls.Add($layout)
        $dlg.AcceptButton = $yes
        $dlg.CancelButton = $no
        Set-DialogTheme -Dialog $dlg -Buttons @($yes, $no)
        $dlg.Add_Shown({ param($source) $source.Activate() })   # 通知から開いたときも、前面に出して操作できるように
        return ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    finally { $dlg.Dispose() }
}

$script:Confirming = $false
function Request-AndonUpdate {
    <# 通知のクリックとトレイの「アップデート」。アップデートするかを尋ね、「アップデートする」なら zip を落とし始める。
       尋ねている間は、もう 1 つの画面を出さない（トレイのメニューは、画面を出している間も開ける） #>
    if (-not $script:Update -or $script:DownloadTask -or $script:Confirming) { return }
    $script:Confirming = $true
    try {
        if (Confirm-AndonUpdate -Info $script:Update) { Start-AndonUpdate }
    }
    finally { $script:Confirming = $false }
}

function Start-AndonUpdate {
    <# トレイの「アップデート」。新しい版の zip を落とし始める。続きは Complete-AndonUpdate #>
    if (-not $script:Update -or $script:DownloadTask) { return }
    $info = $script:Update
    $miUpdate.Enabled = $false
    $miUpdate.Text = "アップデート（v$($info.Version)）を準備しています…"
    try {
        $script:DownloadInfo = $info
        $script:DownloadClient = New-UpdateClient
        $script:DownloadTask = $script:DownloadClient.GetByteArrayAsync($info.ZipUrl)
    }
    catch {
        if ($script:DownloadClient) { $script:DownloadClient.Dispose(); $script:DownloadClient = $null }
        $script:DownloadTask = $null
        Show-UpdateFailure -Info $info -Message $_.Exception.Message
    }
}

function Show-UpdateFailure {
    param($Info, [string]$Message)
    $miUpdate.Text = "アップデート（v$($Info.Version)）"
    $miUpdate.Enabled = $true
    $script:NoticeKey = $null
    $script:NoticeUpdate = $false
    $tray.ShowBalloonTip(10000, 'andon をアップデートできませんでした', $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Complete-AndonUpdate {
    <# 落とした zip を確かめて展開し、新しい版の install.ps1 を見えるコンソールで起動して、andon は終わる。
       install.ps1 は、andon が終わる（mutex が消える）のを待ってからファイルを置き換え、andon を起動し直す #>
    $task = $script:DownloadTask
    $info = $script:DownloadInfo
    $script:DownloadTask = $null
    try {
        if ($task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $reason = 'zip を落とせませんでした'
            if ($task.Exception) { $reason += ': ' + $task.Exception.GetBaseException().Message }
            throw $reason
        }
        $work = New-UpdateWorkDir -Version $info.Version
        $installer = Expand-UpdatePackage -Bytes $task.Result -Sha256 $info.Sha256 -WorkDir $work
        $command = Get-UpdateCommand -InstallScript $installer
        # Start-Process は新しいコンソールを開く（andon のコンソールは --headless で見えない）。
        # 7 のモジュールのパスを 5.1 に引き継がない（install.ps1 の Start-Andon と同じ理由）
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = $null
            Start-Process -FilePath $command.FilePath -ArgumentList $command.Arguments -WorkingDirectory $env:USERPROFILE
        }
        finally { $env:PSModulePath = $saved }
    }
    catch {
        Show-UpdateFailure -Info $info -Message $_.Exception.Message
        return
    }
    finally {
        if ($script:DownloadClient) { $script:DownloadClient.Dispose(); $script:DownloadClient = $null }
    }
    $script:Exiting = $true
    $form.Close()
}

function Update-UpdateCheck {
    <# timer から呼ぶ。アップデートの zip を落とし終えていれば続きを行い、新しい版の確認を始めるか、終わったかを見る。
       確認できなければ 1 時間後に、確認できれば 1 日後にもう一度確かめる。確認の失敗は知らせない #>
    param([datetime]$Now)
    if ($script:DownloadTask -and $script:DownloadTask.IsCompleted) { Complete-AndonUpdate; return }
    if ($script:CheckTask) {
        if (-not $script:CheckTask.IsCompleted) { return }   # 30 秒で HttpClient が諦める
        $task = $script:CheckTask
        $script:CheckTask = $null
        try {
            if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $info = Get-UpdateInfo -Release (ConvertFrom-Json -InputObject $task.Result) -CurrentVersion $script:AndonVersion
                $script:NextUpdateCheck = $Now.AddDays(1)
                if ($info) { Show-UpdateAvailable -Info $info }
            }
        }
        finally {
            $script:CheckClient.Dispose()
            $script:CheckClient = $null
        }
        return
    }
    if ($Now -lt $script:NextUpdateCheck) { return }
    # 始められなかったときに、tick のたびに試さないよう、先に次の時刻を決める
    $script:NextUpdateCheck = $Now.AddHours(1)
    $client = New-UpdateClient -Api
    try { $script:CheckTask = $client.GetStringAsync("https://api.github.com/repos/$script:AndonRepository/releases/latest") }
    catch { $client.Dispose(); throw }
    $script:CheckClient = $client
}

# 行をクリックしたら（Activation = OneClick）、そのセッションを開く。横と縦の一覧で同じ
$onItemActivate = {
    $e = Get-SelectedEntry
    if ($e) { Open-Session -Entry $e; Update-ListView }
}
$lv.Add_ItemActivate($onItemActivate)
$lvV.Add_ItemActivate($onItemActivate)
$miOpen.Add_Click({
        $e = Get-SelectedEntry
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
$miRead.Add_Click({
        $e = Get-SelectedEntry
        if ($e) { $e.Unread = $false; Update-ListView }
    })
$btnRead.Add_Click({ Set-AllRead })
$chkTop.Add_CheckedChanged({
        $form.TopMost = $chkTop.Checked
        Save-WindowSettings
    })
# 動かし終えたとき、大きさを変え終えたときに保存する（終了するときだけだと、プロセスを止められたときに覚えたものがなくなる）
$form.Add_ResizeEnd({ Save-WindowSettings })

$tray.Add_MouseClick({
        param($source, $mouse)
        if ($mouse.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-AndonWindow }
    })
$tray.Add_BalloonTipClicked({
        if ($script:NoticeUpdate) {
            # 新しい版の知らせは、トレイの「アップデート」と同じく、アップデートするかを尋ねる
            Request-AndonUpdate
            return
        }
        $e = $script:State[[string]$script:NoticeKey]
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
$miUpdate.Add_Click({ Request-AndonUpdate })
$miShow.Add_Click({ Show-AndonWindow })
$miTrayRead.Add_Click({ Set-AllRead })
# メニューを開くたびに読み直す。タスク マネージャーで無効にしたり、ショートカットを手で消したりしても、次に開いたときに表す
$trayMenu.Add_Opening({
        $available = $false
        $checked = $false
        try {
            $l = $script:LogonLayout
            $available = Test-LogonStartupAvailable -ScriptDir $script:ScriptDir -InstallDir $l.InstallDir -StartMenu $l.StartMenu
            if ($available) { $checked = Get-LogonStartup -Startup $l.Startup -ApprovedKey $l.ApprovedKey }
        }
        catch { $available = $false }   # 調べられなければ出さない
        $miLogon.Visible = $available
        $miLogon.Checked = $checked
        # Codex の hooks は、hooks.json に andon の hook があるかを、そのまま設定として使う（手で消しても、次に開いたときに表す）
        $miCodex.Visible = $script:CodexHookLoaded
        if ($script:CodexHookLoaded) {
            $codexUsed = $false
            $codexOn = $false
            try {
                $codexUsed = Test-Path -LiteralPath (Get-AndonCodexHome) -PathType Container
                if ($codexUsed) { $codexOn = Test-AndonCodexHooks (Read-AndonCodexHooksFile -Path (Get-CodexHooksPath)) }
            }
            catch { $codexUsed = $false }
            $miCodex.Enabled = $codexUsed
            $miCodex.Checked = $codexOn
        }
        foreach ($mi in $miThemeItems) { $mi.Checked = ([string]$mi.Tag -eq $script:ThemeChoice) }
        $miVertical.Checked = $script:Vertical
    })
# テーマを選んだら、覚えて塗り直す
foreach ($mi in $miThemeItems) {
    $mi.Add_Click({
            param($source)
            $script:ThemeChoice = [string]$source.Tag
            try { Write-AndonSettings -Key $script:SettingsKey -Values ([ordered]@{ Theme = [array]::IndexOf($script:ThemeChoices, $script:ThemeChoice) }) }
            catch { }   # 覚えられなくても、今の andon の色は変える
            Update-AndonTheme
        })
}
# 縦表示を切り替えたら、覚えて一覧を入れ替える
$miVertical.Add_Click({
        $script:Vertical = -not $script:Vertical
        try { Write-AndonSettings -Key $script:SettingsKey -Values ([ordered]@{ Vertical = [int]$script:Vertical }) }
        catch { }   # 覚えられなくても、今の andon の表示は変える
        Update-ListLayout
    })
$miLogon.Add_Click({
        $l = $script:LogonLayout
        $enable = -not $miLogon.Checked
        try { Set-LogonStartup -Enabled $enable -StartMenu $l.StartMenu -Startup $l.Startup -ApprovedKey $l.ApprovedKey }
        catch {
            $what = 'ログオン時に起動しないようにできませんでした'
            if ($enable) { $what = 'ログオン時に起動するようにできませんでした' }
            $script:NoticeKey = $null   # この通知のクリックでは、何も開かない
            $script:NoticeUpdate = $false
            $tray.ShowBalloonTip(10000, $what, $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    })
$miCodex.Add_Click({
        $enable = -not $miCodex.Checked
        try { Set-CodexHooksEnabled -Enabled $enable }
        catch {
            $what = 'Codex の hooks から andon の hook を消せませんでした'
            if ($enable) { $what = 'Codex の hooks に andon の hook を足せませんでした' }
            $script:NoticeKey = $null   # この通知のクリックでは、何も開かない
            $script:NoticeUpdate = $false
            $tray.ShowBalloonTip(10000, $what, $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    })
$miExit.Add_Click({
        $script:Exiting = $true
        $form.Close()
    })
# 最小化したらトレイに隠す（タスクバーに出していないので、最小化したウィンドウが画面の隅に残ってしまう）
$form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide() }
    })
# 隠したら、縦の一覧でマウスを乗せている行を忘れる（隠すときは、MouseLeave が来ないことがある）
$form.Add_VisibleChanged({ if (-not $form.Visible) { $script:VerticalHot = -1 } })
# × や Alt+F4（SC_CLOSE）では終わらずにトレイに隠れる。終了はトレイのメニューから。
# ログオフや、ほかのプログラムが WM_CLOSE で閉じる（taskkill など）ときは UserClosing にならないので、そのまま終わる
$form.Add_FormClosing({
        param($source, $closing)
        if ($closing.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:Exiting) {
            $closing.Cancel = $true
            $form.Hide()
            return
        }
        Save-WindowSettings   # 終わる前に保存する
    })

$script:PollTask = $null
$script:PollProc = $null
$script:PollStartTime = $null
$script:LastSignature = $null
$script:NextPoll = Get-Date
$script:NextRender = Get-Date

# Orca の CLI を待つ timer（Start-OrcaTabSwitch で動かし、終わったら止める）。タブがすぐ切り替わるよう、状態を見る timer より短くする
$script:OrcaTimer = New-Object System.Windows.Forms.Timer
$script:OrcaTimer.Interval = 100
$script:OrcaTimer.Add_Tick({
        try { Update-OrcaTabSwitch -Now (Get-Date) }
        catch {
            Stop-OrcaTabSwitch
            $script:OrcaTimer.Stop()
        }
    })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $ScanMs
$timer.Add_Tick({
        # install.ps1 の合図。トレイの「終了」と同じく終わる
        if ($script:ExitEvent -and $script:ExitEvent.WaitOne(0)) {
            $script:Exiting = $true
            $form.Close()
            return
        }
        # 下の claude agents --json の処理は途中で return するので、その前に行う。失敗しても状態の表示は続ける
        if ($script:UpdateEnabled) {
            try { Update-UpdateCheck -Now (Get-Date) } catch { }
            if ($script:Exiting) { return }   # 新しい版の install.ps1 を起動して、終わるところ
        }
        # 「Windows に合わせる」なら、Windows のアプリ モードが変わったかを 2 秒ごとに見る。失敗しても状態の表示は続ける
        if ($script:ThemeChoice -eq 'System' -and (Get-Date) -ge $script:NextThemeCheck) {
            $script:NextThemeCheck = (Get-Date).AddSeconds(2)
            try { Update-AndonTheme } catch { }
        }
        try {
            $now = Get-Date
            Update-Flash
            # Codex のセッション。下の claude agents --json の処理は途中で return するので、その前に行う。
            # 失敗しても、Claude のセッションの表示は続ける（次の回に読み直す）
            try {
                $codex = Update-Codex -Now $now
                if ($codex.Changed) {
                    Update-ListView
                    $script:NextRender = $now.AddSeconds(5)
                }
                if ($codex.Alert) { Invoke-Alert -Now $now }
            }
            catch { $script:CodexSignature = $null }
            if ($script:PollTask) {
                if (-not $script:PollTask.IsCompleted) {
                    if (($now - $script:PollStarted).TotalSeconds -gt 30) {
                        try { Stop-ProcessTree -Id $script:PollProc.Id -StartTime $script:PollStartTime } catch { }
                        $script:PollProc.Dispose()
                        $script:PollProc = $null
                        $script:PollTask = $null
                        $script:NextPoll = $now.AddSeconds(5)
                        $lblStatus.Text = 'claude agents --json が応答しません'
                    }
                    return
                }
                $json = $script:PollTask.Result
                $script:PollTask = $null
                $script:PollProc.Dispose()
                $script:PollProc = $null
                $alert = Update-SessionState -Sessions (ConvertFrom-SessionJson $json) -Now $now
                foreach ($e in $script:State.Values) {
                    # 起動引数は変わらないので、新しいセッションだけ 1 回見る。取れなければ普通のセッションとして扱う
                    if ($null -eq $e.Sdk) { $e.Sdk = Test-SdkCommandLine (Get-ProcessCommandLine -Id $e.Key) }
                }
                Update-ListView
                $script:NextRender = $now.AddSeconds(5)
                $lblStatus.Text = '更新 ' + $now.ToString('HH:mm:ss')
                if ($alert) { Invoke-Alert -Now $now }
                $script:NextPoll = $now.AddSeconds($FallbackSec)
                return
            }

            $sig = Get-SessionSignature -Path $script:SessionsDir
            if ($sig -ne $script:LastSignature -or $now -ge $script:NextPoll) {
                $script:LastSignature = $sig
                Start-Poll
                return
            }
            if ($now -ge $script:NextRender) {
                Update-ListView   # 経過時間の表示だけ更新する
                $script:NextRender = $now.AddSeconds(5)
            }
        }
        catch {
            $script:PollTask = $null
            if ($script:PollProc) {
                try { $script:PollProc.Dispose() } catch { }
                $script:PollProc = $null
            }
            $script:NextPoll = (Get-Date).AddSeconds(5)
            $lblStatus.Text = 'エラー: ' + $_.Exception.Message
        }
    })

$form.Add_FormClosed({
        $timer.Stop()
        $script:OrcaTimer.Stop()
        try { Stop-OrcaTabSwitch } catch { }
        # 消さずに終わると、マウスを重ねるまでトレイにアイコンが残る
        $tray.Visible = $false
        $tray.Dispose()
        if ($script:AppIcon) { $script:AppIcon.Dispose() }
        if ($script:PollProc -and -not $script:PollProc.HasExited) { try { Stop-ProcessTree -Id $script:PollProc.Id -StartTime $script:PollStartTime } catch { } }
        foreach ($client in @($script:CheckClient, $script:DownloadClient)) { if ($client) { try { $client.Dispose() } catch { } } }
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
        if ($script:ExitEvent) { $script:ExitEvent.Dispose() }
    })

# 覚えたテーマで塗る。塗れなくても、既定の見た目で動く
try { Update-AndonTheme -Force } catch { }
$tray.Visible = $true
$timer.Start()
# ShowDialog はウィンドウを隠すと終わってしまうので、トレイに隠せるよう Application.Run で動かす
[System.Windows.Forms.Application]::Run($form)
