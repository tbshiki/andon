#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code の対話セッションを一覧し、許可待ち・質問待ち・完了を目立たせる小さなウィンドウ。

.DESCRIPTION
    状態の正本は公式の `claude agents --json`（status: busy / waiting / idle）である。
    Claude Code は状態が変わるたびに `<設定ディレクトリ>/sessions/<pid>.json` を書き換えるので、
    その名前と更新時刻だけを見て、変化があったときに `claude agents --json` を呼ぶ。
    ファイルの中身は読まない。同じ場所にある *.key には触れない。

    - waiting（許可待ち・質問待ち）を赤、busy から idle に変わった未確認のもの（完了）を黄で上に並べる。
    - VS Code の拡張機能のパネルなど、SDK から動かしているセッションは、待機中（確認済み）なら出さない。
      拡張機能は、パネルを閉じても claude を終了させず、待機中のまま残すため。
    - タスクバーには出さず、通知領域（タスクトレイ）のアイコンの色で状態を示す。
      × で閉じるとトレイに隠れる。終了はトレイの右クリックのメニューから行う。
    - 新しい待ちや完了が出たとき、このウィンドウが前面になければ Windows の通知を出す。
      通知をクリックすると、そのセッションを開く。送り元は、プロセスにアプリ ID（tbshiki.andon）を付け、
      その表示名を HKCU に登録して「andon」と表示させる。
      ID はプロセス全体に付くので、andon のためだけに起動した PowerShell で動かしたときだけ付ける。
    - ウィンドウを表示していれば、タイトルバーも点滅させる。点滅は、andon を前面に出したときのほか、
      きっかけになったセッションの VS Code のウィンドウ（題名のフォルダ名や workspace 名で見分ける）を前面に出したときや、
      そのセッションが待ちでも完了でもなくなったときに止める。
    - 行をクリックすると、cwd を含む *.code-workspace（なければ repository の root）を VS Code で開く。
      既に開いているウィンドウがあれば、そのウィンドウが前面に出る。ターミナルのタブまでは選ばない。
    - install.ps1 が更新や削除の前に終わらせられるよう、名前付きのイベント（Local\andon-exit）の合図を受けたら終わる。
    - 起動して少し後と、その後 1 日 1 回、GitHub の Release（releases/latest）に新しい版があるかを確かめる。
      あれば、トレイのメニューに「更新（v<版>）」を出し、起動ごとに 1 回だけ通知する。自動では入れ替えない。
      通知のクリックとトレイの「更新」は、どちらも更新するかを尋ねる画面を出す。「更新する」を選んだときだけ
      zip を落とし、Release が示す sha256 と照らして展開し、新しい版の install.ps1 を見えるコンソールで起動して終わる。-NoUpdateCheck を付けたときと、andon.ps1 の隣に .git があるとき
      （clone で開発しているとき）は確かめない。

.PARAMETER FallbackSec
    更新時刻に変化がなくても `claude agents --json` を呼ぶ間隔（秒）。

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
$script:AndonVersion = '0.1.1'
# 新しい版を確かめる GitHub のリポジトリ
$script:AndonRepository = 'tbshiki/andon'

# ---------------------------------------------------------------------------
# 状態の管理（GUI に依存しない部分。ドットソースして単体で確かめられる）
# ---------------------------------------------------------------------------

$script:State = @{}        # pid -> エントリ

function Get-JsonValue {
    param($Object, [string]$Name)
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

function Update-SessionState {
    <# 一覧を取り込み、新しく「待ち」になったセッションがあれば $true を返す #>
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
            # 起動時点で idle のものは、いつ終わったか分からないので既読として扱う
            $entry = [pscustomobject]@{
                Key = $key; Status = $status; Since = $null; Unread = ($status -eq 'waiting')
                Name = ''; Cwd = ''; Kind = ''; WaitingFor = ''; AlertAt = $null
                Sdk = $null   # 拡張機能のパネルなど、ターミナルではなく SDK から動かしているか。$null は未判定
                StartedAt = $startedAt
            }
            $script:State[$key] = $entry
            if ($entry.Unread) { $entry.AlertAt = $Now; $alert = $true }
        }
        elseif ($entry.Status -ne $status) {
            $prev = $entry.Status
            $entry.Status = $status
            $entry.Since = $Now
            if ($status -eq 'waiting') { $entry.Unread = $true; $entry.AlertAt = $Now; $alert = $true }
            elseif ($status -eq 'idle' -and $prev -eq 'busy') { $entry.Unread = $true; $entry.AlertAt = $Now; $alert = $true }
            else { $entry.Unread = $false }   # busy に戻った = 誰かが応答した。waiting -> idle は手元で拒否した場合
        }
        $entry.Name = [string](Get-JsonValue $s 'name')
        $entry.Cwd = [string](Get-JsonValue $s 'cwd')
        $entry.Kind = [string](Get-JsonValue $s 'kind')
        $entry.WaitingFor = [string](Get-JsonValue $s 'waitingFor')
        if ($null -ne $startedAt) { $entry.StartedAt = $startedAt }
    }
    foreach ($k in @($script:State.Keys)) {
        if (-not $alive.ContainsKey($k)) { $script:State.Remove($k) }
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
    <# トレイのアイコンの色を決める。待ちがあれば waiting、完了があれば done、どちらもなければ none #>
    param([object[]]$Entries)
    $ranks = @(foreach ($e in $Entries) { Get-Rank $e })
    if ($ranks -contains 0) { return 'waiting' }
    if ($ranks -contains 1) { return 'done' }
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
    $heading = 'Claude Code が完了しました'
    if ((Get-Rank $hits[0]) -eq 0) { $heading = 'Claude Code が待っています' }
    return [pscustomobject]@{ Title = $heading; Text = $text; Key = $hits[0].Key }
}

function Get-PendingFlashKeys {
    <# 点滅のきっかけになったセッション（キー -> VS Code の題名に出る名前）のうち、まだ点滅を続ける理由があるもの。
       終わったもの、待ちでも完了でもなくなったもの、前面の VS Code のウィンドウ（題名 $ForegroundTitle）で
       開いているものは外す。$ForegroundTitle は、前面が VS Code でなければ空 #>
    param([hashtable]$FlashKeys, [hashtable]$State, [string]$ForegroundTitle)
    $keep = @{}
    foreach ($k in @($FlashKeys.Keys)) {
        $e = $State[$k]
        if (-not $e -or (Get-Rank $e) -gt 1) { continue }
        if (Test-VSCodeWindowTitle -Title $ForegroundTitle -RootName $FlashKeys[$k]) { continue }
        $keep[$k] = $FlashKeys[$k]
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

function Stop-ProcessTree {
    <# プロセスと、その子孫のプロセスを止める。claude が .cmd の場合、cmd.exe だけを止めると node が残るため #>
    param([int]$Id)
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -Id ([int]$child.ProcessId)
    }
    try { (Get-Process -Id $Id -ErrorAction Stop).Kill() } catch { }
}

# ---------------------------------------------------------------------------
# 更新の確認（GitHub の Release）
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
    <# 更新するかを尋ねる画面の文。通知のクリックとトレイの「更新」の両方で、同じ画面を出す #>
    param([string]$Version, [string]$CurrentVersion)
    return (@(
            "andon v$Version があります（今のバージョンは v$CurrentVersion）。"
            ''
            '更新すると、andon を終わらせて新しいバージョンを入れ、起動し直します。'
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
    <# 更新の zip を展開するフォルダ（<一時フォルダ>\andon-update-<版>-<乱数>）を作る。
       前の更新で残ったフォルダ（andon-update-*）は、消せれば消す #>
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
       - 引数は付けない。どの版の install.ps1 も、引数なしで実行すれば更新になる（ショートカットの引数とスタートアップは引き継ぐ）
       - install.ps1 が失敗したら（終了コードが 0 でなければ）、理由を読めるよう、Enter キーを押すまで閉じない。
         成功したら、結果を読めるよう少し待ってから閉じる
       - パスの引用を誤らないよう、-EncodedCommand で渡す。単一引用符の中では、U+2018 や U+2019 なども ' として扱われるので重ねる #>
    param([string]$InstallScript, [string]$SystemRoot = $env:SystemRoot)
    $quoted = $InstallScript -replace '([''\u2018\u2019\u201A\u201B])', '$1$1'
    $command = @"
`$Host.UI.RawUI.WindowTitle = 'andon の更新'
try { & '$quoted'; `$code = `$LASTEXITCODE } catch { Write-Host (`$_.Exception.Message) -ForegroundColor Red; `$code = 1 }
if (`$null -eq `$code) { `$code = 0 }
if (`$code -ne 0) { [void](Read-Host '更新できませんでした。Enter キーで閉じます') } else { Start-Sleep -Seconds 3 }
exit `$code
"@
    return [pscustomobject]@{
        FilePath  = Join-Path $SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    }
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
if (-not $script:CodeCmd) {
    [void][System.Windows.Forms.MessageBox]::Show('VS Code の code.cmd が見つかりません。', 'andon')
    return
}
$script:CodeExe = Find-CodeExe -CodeCmd $script:CodeCmd
$script:SessionsDir = Join-Path (Get-ClaudeConfigDir) 'sessions'

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
    $script:PollTask = $script:PollProc.StandardOutput.ReadToEndAsync()
    [void]$script:PollProc.StandardError.ReadToEndAsync()
    $script:PollStarted = Get-Date
}

function Open-Session {
    param($Entry)
    $target = Find-VSCodeTarget -Cwd $Entry.Cwd
    if (-not $target) { return }
    Start-VSCode -Target $target -CodeExe $script:CodeExe -CodeCmd $script:CodeCmd
    $Entry.Unread = $false
}

$script:CodeProcessName = 'Code'
if ($script:CodeExe) { $script:CodeProcessName = [IO.Path]::GetFileNameWithoutExtension($script:CodeExe) }
$script:FlashKeys = @{}   # 点滅のきっかけになったセッション -> その VS Code のウィンドウの題名に出る名前

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
       そのセッションの VS Code のウィンドウがすでに前面にあれば、点滅させない #>
    param([datetime]$Now)
    try {
        $keys = @{}
        foreach ($e in $script:State.Values) {
            if ($e.AlertAt -eq $Now -and (Get-Rank $e) -le 1) { $keys[$e.Key] = Get-VSCodeRootName (Find-VSCodeTarget -Cwd $e.Cwd) }
        }
        $keys = Get-PendingFlashKeys -FlashKeys $keys -State $script:State -ForegroundTitle (Get-ForegroundCodeTitle)
        if ($keys.Count -eq 0) { return }
        foreach ($k in $keys.Keys) { $script:FlashKeys[$k] = $keys[$k] }
    }
    catch { }   # 調べられなくても点滅はさせる（止めるのは、andon を前面に出したときだけになる）
    [AndonNative]::Flash($form.Handle)
}

function Update-Flash {
    <# 点滅のきっかけになったセッションが、どれも点滅を続ける理由をなくしたら、点滅を止める。
       そのセッションの VS Code のウィンドウを前面に出した、待ちでも完了でもなくなった、終わった、のいずれか #>
    if ($script:FlashKeys.Count -eq 0) { return }
    if ($form.ContainsFocus) { $script:FlashKeys = @{}; return }   # andon を前面に出すと、Windows が点滅を止める
    try {
        $script:FlashKeys = Get-PendingFlashKeys -FlashKeys $script:FlashKeys -State $script:State -ForegroundTitle (Get-ForegroundCodeTitle)
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
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($workArea.Right - $form.Width - 8), ($workArea.Bottom - $form.Height - 8))
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
$miUpdate = $trayMenu.Items.Add('更新')
$miUpdate.Visible = $false
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miShow = $trayMenu.Items.Add('表示')
$miTrayRead = $trayMenu.Items.Add('すべて既読')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $trayMenu.Items.Add('終了')
$tray.ContextMenuStrip = $trayMenu
$script:Exiting = $false
$script:NoticeKey = $null
$script:NoticeUpdate = $false   # 最後に出した通知が、新しい版の知らせか（クリックで、更新するかを尋ねる）

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

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Top'
$panel.AutoSize = $true
$panel.WrapContents = $false
$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = '常に手前'
$chkTop.Checked = $true
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

# Fill を先、Top を後に追加する（後に追加したものから先に配置される）
$form.Controls.Add($lv)
$form.Controls.Add($panel)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('VS Code で開く')
$miRead = $menu.Items.Add('既読にする')
$lv.ContextMenuStrip = $menu

function Get-SelectedEntry {
    if ($lv.SelectedItems.Count -eq 0) { return $null }
    return $script:State[[string]$lv.SelectedItems[0].Tag]
}

function Update-ListView {
    $now = Get-Date
    $entries = @($script:State.Values | Where-Object { Test-SessionVisible $_ } | Sort-Object `
            @{ Expression = { Get-Rank $_ } }, `
            @{ Expression = { if ($_.Since) { $_.Since } else { [datetime]::MinValue } } })
    $selectedKey = $null
    if ($lv.SelectedItems.Count -gt 0) { $selectedKey = $lv.SelectedItems[0].Tag }

    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($e in $entries) {
        $elapsed = ''
        if ($e.Since) { $elapsed = Format-Elapsed ($now - $e.Since) }
        $item = New-Object System.Windows.Forms.ListViewItem((Get-StatusLabel $e))
        [void]$item.SubItems.Add($elapsed)
        [void]$item.SubItems.Add($e.Name)
        [void]$item.SubItems.Add($e.Cwd)
        $item.Tag = $e.Key
        switch (Get-Rank $e) {
            0 { $item.BackColor = [System.Drawing.Color]::FromArgb(255, 210, 210); $item.Font = $boldFont }
            1 { $item.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 180); $item.Font = $boldFont }
            3 { $item.ForeColor = [System.Drawing.Color]::Gray }
        }
        [void]$lv.Items.Add($item)
        if ($e.Key -eq $selectedKey) { $item.Selected = $true }
    }
    $lv.EndUpdate()

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

# 新しい版の確認と、更新の zip の取得。claude agents --json と同じく、timer で終わったかだけを見て、待たない
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
        $miUpdate.Text = "更新（v$($Info.Version)）"
        $miUpdate.Enabled = $true
        $miUpdate.Visible = $true
    }
    if ($script:NotifiedUpdate -ne $Info.Version) {
        $script:NotifiedUpdate = $Info.Version
        $script:NoticeKey = $null
        $script:NoticeUpdate = $true
        $tray.ShowBalloonTip(10000, 'andon の新しいバージョンがあります',
            ('クリックすると、v{0} に更新するかを選べます。あとで更新するときは、トレイのメニューの「更新（v{0}）」を選びます。' -f $Info.Version),
            [System.Windows.Forms.ToolTipIcon]::None)
    }
}

function Confirm-AndonUpdate {
    <# 新しい版に更新するかを尋ねる。「更新する」なら $true。Enter で「更新する」、Esc で「しない」 #>
    param($Info)
    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = 'andon の更新'
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
        $yes.Text = '更新する'
        $yes.AutoSize = $true
        $yes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $buttons.Controls.AddRange(@($no, $yes))   # 右から並ぶので、「更新する」が左、「しない」が右
        $layout.Controls.Add($text)
        $layout.Controls.Add($buttons)
        $dlg.Controls.Add($layout)
        $dlg.AcceptButton = $yes
        $dlg.CancelButton = $no
        $dlg.Add_Shown({ param($source) $source.Activate() })   # 通知から開いたときも、前面に出して操作できるように
        return ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    finally { $dlg.Dispose() }
}

$script:Confirming = $false
function Request-AndonUpdate {
    <# 通知のクリックとトレイの「更新」。更新するかを尋ね、「更新する」なら zip を落とし始める。
       尋ねている間は、もう 1 つの画面を出さない（トレイのメニューは、画面を出している間も開ける） #>
    if (-not $script:Update -or $script:DownloadTask -or $script:Confirming) { return }
    $script:Confirming = $true
    try {
        if (Confirm-AndonUpdate -Info $script:Update) { Start-AndonUpdate }
    }
    finally { $script:Confirming = $false }
}

function Start-AndonUpdate {
    <# トレイの「更新」。新しい版の zip を落とし始める。続きは Complete-AndonUpdate #>
    if (-not $script:Update -or $script:DownloadTask) { return }
    $info = $script:Update
    $miUpdate.Enabled = $false
    $miUpdate.Text = "更新（v$($info.Version)）を準備しています…"
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
    $miUpdate.Text = "更新（v$($Info.Version)）"
    $miUpdate.Enabled = $true
    $script:NoticeKey = $null
    $script:NoticeUpdate = $false
    $tray.ShowBalloonTip(10000, 'andon を更新できませんでした', $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
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
    <# timer から呼ぶ。更新の zip を落とし終えていれば続きを行い、新しい版の確認を始めるか、終わったかを見る。
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

$lv.Add_ItemActivate({
        $e = Get-SelectedEntry
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
$miOpen.Add_Click({
        $e = Get-SelectedEntry
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
$miRead.Add_Click({
        $e = Get-SelectedEntry
        if ($e) { $e.Unread = $false; Update-ListView }
    })
$btnRead.Add_Click({ Set-AllRead })
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })

$tray.Add_MouseClick({
        param($source, $mouse)
        if ($mouse.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-AndonWindow }
    })
$tray.Add_BalloonTipClicked({
        if ($script:NoticeUpdate) {
            # 新しい版の知らせは、トレイの「更新」と同じく、更新するかを尋ねる
            Request-AndonUpdate
            return
        }
        $e = $script:State[[string]$script:NoticeKey]
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
$miUpdate.Add_Click({ Request-AndonUpdate })
$miShow.Add_Click({ Show-AndonWindow })
$miTrayRead.Add_Click({ Set-AllRead })
$miExit.Add_Click({
        $script:Exiting = $true
        $form.Close()
    })
# 最小化したらトレイに隠す（タスクバーに出していないので、最小化したウィンドウが画面の隅に残ってしまう）
$form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide() }
    })
# × や Alt+F4（SC_CLOSE）では終わらずにトレイに隠れる。終了はトレイのメニューから。
# ログオフや、ほかのプログラムが WM_CLOSE で閉じる（taskkill など）ときは UserClosing にならないので、そのまま終わる
$form.Add_FormClosing({
        param($source, $closing)
        if ($closing.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:Exiting) {
            $closing.Cancel = $true
            $form.Hide()
        }
    })

$script:PollTask = $null
$script:PollProc = $null
$script:LastSignature = $null
$script:NextPoll = Get-Date
$script:NextRender = Get-Date

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
        try {
            $now = Get-Date
            Update-Flash
            if ($script:PollTask) {
                if (-not $script:PollTask.IsCompleted) {
                    if (($now - $script:PollStarted).TotalSeconds -gt 30) {
                        try { Stop-ProcessTree -Id $script:PollProc.Id } catch { }
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
                if ($alert -and -not $form.ContainsFocus) {
                    if ($form.Visible) { Start-Flash -Now $now }
                    $notice = Get-AlertNotice -Entries @($script:State.Values) -Now $now
                    if ($notice) {
                        # 通知をクリックしたら、このセッションを開く。覚えるのは最新の 1 件分でよい。
                        # Windows は同じアイコンの通知を新しいもので置き換え、通知センターにも最新の 1 件しか残さないため
                        $script:NoticeKey = $notice.Key
                        $script:NoticeUpdate = $false
                        $tray.ShowBalloonTip(10000, $notice.Title, $notice.Text, [System.Windows.Forms.ToolTipIcon]::None)
                    }
                }
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
        # 消さずに終わると、マウスを重ねるまでトレイにアイコンが残る
        $tray.Visible = $false
        $tray.Dispose()
        if ($script:AppIcon) { $script:AppIcon.Dispose() }
        if ($script:PollProc -and -not $script:PollProc.HasExited) { try { Stop-ProcessTree -Id $script:PollProc.Id } catch { } }
        foreach ($client in @($script:CheckClient, $script:DownloadClient)) { if ($client) { try { $client.Dispose() } catch { } } }
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
        if ($script:ExitEvent) { $script:ExitEvent.Dispose() }
    })

$tray.Visible = $true
$timer.Start()
# ShowDialog はウィンドウを隠すと終わってしまうので、トレイに隠せるよう Application.Run で動かす
[System.Windows.Forms.Application]::Run($form)
