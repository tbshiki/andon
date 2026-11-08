#Requires -Version 5.1
<#
.SYNOPSIS
    Codex（OpenAI の Codex CLI）の hook から呼ばれ、セッションの状態を andon の記録のフォルダに書く。

.DESCRIPTION
    andon は、Codex のセッションの状態を、Codex の hooks で受け取る（D-109）。Codex は、イベントのたびに、~/.codex/hooks.json に
    書いたコマンドを動かし、イベントの中身を JSON で標準入力に渡す。このスクリプトは、そのうち次のものだけを、
    %LOCALAPPDATA%\andon\codex\<セッションの ID>.json に書く。andon は、そのフォルダを見て一覧に出す。

    - セッションの ID、状態（実行中・許可待ち・完了・待機）、作業フォルダ、イベントの時刻
    - セッションを動かしている Codex のプロセス（PID、起動時刻、VS Code の拡張機能か）。セッションの最初のイベントのときだけ調べる

    プロンプト、コマンド、返事の中身は書かない。標準出力には何も出さない（SessionStart などの出力は、Codex がモデルに渡すため）。
    hooks.json には async: true で登録するので、Codex はこのスクリプトの終わりを待たず、このスクリプトは許可などの判断に関われない。

    andon.ps1 と install.ps1 は、hooks.json に andon の hook を足す・消す関数を、このファイルからドットソースして使う。

.EXAMPLE
    '{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"C:\\work"}' | powershell.exe -NoProfile -File .\andon-codex-hook.ps1
#>

# ---------------------------------------------------------------------------
# 場所と、hooks.json に書くもの
# ---------------------------------------------------------------------------

# andon が使うイベント（D-111、D-115）。PreToolUse と PostToolUse は使わない
$script:AndonCodexHookEvents = @('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'Stop', 'Interrupt', 'SessionEnd')
# andon の hook は、コマンドにこの名前を含むもので見分ける
$script:AndonCodexHookName = 'andon-codex-hook.ps1'

function Get-AndonCodexHome {
    <# Codex の設定のフォルダ。CODEX_HOME があればそこ、なければ ~/.codex #>
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return Join-Path $env:USERPROFILE '.codex'
}

function Get-AndonCodexStateDir {
    <# hook が書き、andon が読む記録のフォルダ。andon のインストール先の外に置く（アップデートで消えないように） #>
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    return Join-Path $LocalAppData 'andon\codex'
}

function Get-AndonCodexHookCommand {
    <# hooks.json に書くコマンド。Codex は、hook のコマンドを PowerShell で動かす（2026-11-07 に確かめた）。
       パスは単一引用符で囲む（$ などを展開させない。単一引用符は 2 つ重ねる）。実行ポリシーに左右されないよう、
       Windows PowerShell 5.1 を -ExecutionPolicy Bypass で起動する #>
    param([string]$ScriptPath)
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '{0}'" -f $ScriptPath.Replace("'", "''")
}

function Test-AndonCodexHandler {
    <# hooks.json の 1 つの handler が、andon の hook か #>
    param($Handler)
    if ($null -eq $Handler) { return $false }
    $p = $Handler.PSObject.Properties['command']
    if (-not $p) { return $false }
    return ([string]$p.Value).IndexOf($script:AndonCodexHookName, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function ConvertFrom-AndonCodexHooksJson {
    <# hooks.json の中身を読む。空なら、空の hooks を返す。JSON として読めなければ例外（触らずに知らせるため） #>
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return [pscustomobject]@{ hooks = [pscustomobject]@{} } }
    $root = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    if ($null -eq $root -or $root -is [array] -or $root -is [string] -or $root -is [ValueType]) { throw 'hooks.json の形が、オブジェクトではありません' }
    if (-not $root.PSObject.Properties['hooks']) { $root | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    elseif ($null -eq $root.hooks -or $root.hooks -is [array] -or $root.hooks -is [string] -or $root.hooks -is [ValueType]) { throw 'hooks.json の hooks が、オブジェクトではありません' }
    return $root
}

function Remove-AndonCodexHandlers {
    <# hooks.json を読んだもの（$Root）から、andon の hook を除く。中身がなくなった組とイベントも除く。
       ほかの hook の組の並びは変えない（Codex は、hook の信頼を、イベントの中の位置と中身で覚えている） #>
    param($Root)
    foreach ($ev in @($Root.hooks.PSObject.Properties)) {
        $groups = @($ev.Value)
        $keep = @()
        $changed = $false
        foreach ($g in $groups) {
            $hp = $null
            if ($null -ne $g) { $hp = $g.PSObject.Properties['hooks'] }
            if (-not $hp) { $keep += , $g; continue }
            $handlers = @($hp.Value)
            $rest = @($handlers | Where-Object { -not (Test-AndonCodexHandler $_) })
            if ($rest.Count -eq $handlers.Count) { $keep += , $g; continue }
            $changed = $true
            if ($rest.Count -eq 0) { continue }
            $g.hooks = $rest
            $keep += , $g
        }
        if (-not $changed) { continue }
        if ($keep.Count -eq 0) { $Root.hooks.PSObject.Properties.Remove($ev.Name) }
        else { $Root.hooks.($ev.Name) = $keep }
    }
}

function ConvertTo-AndonCodexHooksText {
    param($Root)
    return (ConvertTo-Json -InputObject $Root -Depth 32) + "`n"
}

function Add-AndonCodexHooks {
    <# hooks.json の中身（$Json）に、andon の hook を足した中身を返す。andon の hook がもうあれば、入れ直す（パスが変わったときのため）。
       andon の組は、各イベントの最後に足す（ほかの hook の位置を変えない） #>
    param([string]$Json, [string]$Command)
    $root = ConvertFrom-AndonCodexHooksJson $Json
    Remove-AndonCodexHandlers $root
    foreach ($ev in $script:AndonCodexHookEvents) {
        # SessionEnd と Interrupt は、Codex が待つ時間の上限が 3 秒（async なので待たないが、上限を超えた値は書かない）
        $timeout = 30
        if ($ev -eq 'SessionEnd' -or $ev -eq 'Interrupt') { $timeout = 3 }
        $group = [pscustomobject]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = $Command; async = $true; timeout = $timeout }) }
        $p = $root.hooks.PSObject.Properties[$ev]
        if ($p) { $root.hooks.$ev = @(@($p.Value) + $group) }
        else { $root.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($group) }
    }
    return ConvertTo-AndonCodexHooksText $root
}

function Remove-AndonCodexHooks {
    <# hooks.json の中身（$Json）から、andon の hook を除いた中身を返す #>
    param([string]$Json)
    $root = ConvertFrom-AndonCodexHooksJson $Json
    Remove-AndonCodexHandlers $root
    return ConvertTo-AndonCodexHooksText $root
}

function Test-AndonCodexHooks {
    <# hooks.json の中身に、andon の hook があるか。読めなければ $false #>
    param([string]$Json)
    try { $root = ConvertFrom-AndonCodexHooksJson $Json }
    catch { return $false }
    foreach ($ev in $root.hooks.PSObject.Properties) {
        foreach ($g in @($ev.Value)) {
            if ($null -eq $g -or -not $g.PSObject.Properties['hooks']) { continue }
            foreach ($h in @($g.hooks)) { if (Test-AndonCodexHandler $h) { return $true } }
        }
    }
    return $false
}

function Read-AndonCodexHooksFile {
    <# hooks.json の中身。なければ空 #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-AndonCodexHooks {
    <# hooks.json に andon の hook を足す（$Enabled）か、消す。書き換える前に、写し（hooks.json.andon-backup）を作る。
       hooks.json が JSON として読めなければ、触らずに例外にする。変えなくてよければ書かない。消して空になっても、ファイルは残す #>
    param([bool]$Enabled, [string]$Path, [string]$Command)
    $old = Read-AndonCodexHooksFile -Path $Path
    if (-not $Enabled -and -not (Test-AndonCodexHooks $old)) { return }
    if ($Enabled) { $new = Add-AndonCodexHooks -Json $old -Command $Command }
    else { $new = Remove-AndonCodexHooks -Json $old }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::WriteAllText("$Path.andon-backup", $old, $utf8) }
    [IO.File]::WriteAllText($Path, $new, $utf8)
}

# ---------------------------------------------------------------------------
# hook の本体（イベントから、記録に書く状態を決める）
# ---------------------------------------------------------------------------

function ConvertFrom-AndonCodexHookEvent {
    <# hook に渡された JSON を読んだもの（$Payload）から、記録に当てるイベントを決める。当てないものは $null。
       SessionStart は、記録がまだないときだけ待機で作る（最初のプロンプトの UserPromptSubmit とほぼ同時に起き、順が入れ替わるため）。
       Stop は完了。サブエージェントの Stop（agent_id か agent_type があるもの）は、親のセッションの ID で届くので当てない。
       Interrupt は待機（既読）。SessionEnd は記録を消す #>
    param($Payload)
    if ($null -eq $Payload) { return $null }
    $session = [string]$Payload.session_id
    # ファイル名に使うので、英数字と . _ - だけのものに限る
    if ($session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return $null }
    $e = [pscustomobject]@{
        SessionId = $session; Status = ''; WaitingFor = ''; Done = $false; Interrupted = $false; CreateOnly = $false; Remove = $false
        Turn = [string]$Payload.turn_id; Cwd = [string]$Payload.cwd
    }
    switch ([string]$Payload.hook_event_name) {
        'SessionStart' { $e.Status = 'idle'; $e.CreateOnly = $true }
        'UserPromptSubmit' { $e.Status = 'busy' }
        'PermissionRequest' { $e.Status = 'waiting'; $e.WaitingFor = 'permission prompt' }
        'Stop' {
            if ([string]$Payload.agent_id -or [string]$Payload.agent_type) { return $null }
            $e.Status = 'idle'; $e.Done = $true
        }
        'Interrupt' { $e.Status = 'idle'; $e.Interrupted = $true }
        'SessionEnd' { $e.Remove = $true }
        default { return $null }
    }
    return $e
}

function Merge-AndonCodexState {
    <# 今の記録（$Current。なければ $null）に、イベント（$Event）を当てた記録を返す。書かないなら $null。
       $At は、このイベントの時刻（この hook のプロセスの起動時刻。UTC の Ticks）。hook は裏で動くので、届く順が入れ替わりうる。
       記録のほうが新しければ書かない。同じターンで Interrupt のあとに届いた Stop は、完了にしない。
       Codex のプロセス（$HostInfo）は、記録にあればそれを使う #>
    param($Current, $Event, [long]$At, $HostInfo)
    if ($Current) {
        if ([long]$Current.At -gt $At) { return $null }
        if ($Event.CreateOnly) { return $null }
        if ($Event.Done -and $Current.Interrupted -and $Event.Turn -and [string]$Current.Turn -eq $Event.Turn) { return $null }
    }
    $hostPid = 0; $hostStart = [long]0; $hostKind = ''
    if ($Current -and [int]$Current.HostPid -gt 0) {
        $hostPid = [int]$Current.HostPid; $hostStart = [long]$Current.HostStart; $hostKind = [string]$Current.HostKind
    }
    elseif ($HostInfo) { $hostPid = [int]$HostInfo.Pid; $hostStart = [long]$HostInfo.Start; $hostKind = [string]$HostInfo.Kind }
    $cwd = $Event.Cwd
    if (-not $cwd -and $Current) { $cwd = [string]$Current.Cwd }
    $turn = $Event.Turn
    if (-not $turn -and $Current) { $turn = [string]$Current.Turn }
    return [pscustomobject][ordered]@{
        SessionId = $Event.SessionId; Status = $Event.Status; WaitingFor = $Event.WaitingFor; Done = $Event.Done
        Interrupted = $Event.Interrupted; Turn = $turn; Cwd = $cwd; At = $At
        HostPid = $hostPid; HostStart = $hostStart; HostKind = $hostKind
    }
}

function Find-AndonCodexHost {
    <# $Processes（ProcessId、ParentProcessId、CreationDate、Name、CommandLine を持つもの。Win32_Process の一覧）から、
       $Id のプロセスの先祖のうち、最初の codex.exe を探す。親は、子より前に起動したものだけたどる（PID の使い回しのため）。
       Kind は、VS Code の拡張機能の app-server（親が VS Code）なら vscode、共有のデーモンなら daemon、それ以外は terminal。
       見つからなければ $null #>
    param([object[]]$Processes, [int]$Id)
    $byId = @{}
    foreach ($p in $Processes) { if ($null -ne $p) { $byId[[int]$p.ProcessId] = $p } }
    $cur = $byId[$Id]
    for ($i = 0; $cur -and $i -lt 16; $i++) {
        if ([string]$cur.Name -ieq 'codex.exe') {
            $cmd = [string]$cur.CommandLine
            $kind = 'terminal'
            if ($cmd -match '(^|\s)app-server(\s|$)') {
                if ($cmd -match '--managed-daemon') { $kind = 'daemon' }
                else {
                    $parent = $byId[[int]$cur.ParentProcessId]
                    if ($parent -and $parent.CreationDate -le $cur.CreationDate -and [string]$parent.Name -match '^Code( - Insiders)?\.exe$') { $kind = 'vscode' }
                }
            }
            return [pscustomobject]@{ Pid = [int]$cur.ProcessId; Start = ([datetime]$cur.CreationDate).ToUniversalTime().Ticks; Kind = $kind }
        }
        $parent = $byId[[int]$cur.ParentProcessId]
        if (-not $parent -or [int]$parent.ProcessId -eq [int]$cur.ProcessId -or $parent.CreationDate -gt $cur.CreationDate) { break }
        $cur = $parent
    }
    return $null
}

function Read-AndonCodexState {
    <# 記録のファイルを読む。なければ、読めなければ $null #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop) }
    catch { return $null }
}

function Write-AndonCodexState {
    <# 記録を書く。別の hook と同時に書いても壊れないよう、一時ファイルに書いてから置き換える #>
    param([string]$Path, $State)
    $tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $State -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Invoke-AndonCodexHook {
    <# hook の本体。$Payload を当て、$StateDir の記録を書く（または消す）。$GetProcesses は、Codex のプロセスを探すときに
       プロセスの一覧を返す scriptblock（テストで差し替える）。$At はイベントの時刻（UTC の Ticks） #>
    param($Payload, [string]$StateDir, [long]$At, [scriptblock]$GetProcesses, [int]$SelfId = $PID)
    $e = ConvertFrom-AndonCodexHookEvent $Payload
    if (-not $e) { return }
    $path = Join-Path $StateDir ($e.SessionId + '.json')
    if ($e.Remove) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $current = Read-AndonCodexState -Path $path
    $hostInfo = $null
    if (-not ($current -and [int]$current.HostPid -gt 0)) {
        try { $hostInfo = Find-AndonCodexHost -Processes @(& $GetProcesses) -Id $SelfId } catch { $hostInfo = $null }
    }
    $state = Merge-AndonCodexState -Current $current -Event $e -At $At -HostInfo $hostInfo
    if ($state) { Write-AndonCodexState -Path $path -State $state }
}

# ドットソースされたときは関数の定義だけで止める（andon.ps1、install.ps1、テスト）
if ($MyInvocation.InvocationName -eq '.') { return }

# Codex から呼ばれたとき。失敗しても、Codex には何も返さない（標準出力に出さず、終了コードは 0）
try {
    # イベントの時刻は、このプロセスの起動時刻にする（PowerShell の起動にかかる時間の揺れを入れない）
    $at = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    # 標準入力は UTF-8 で読む（[Console]::In は、コンソールのコードページで読んでしまう）
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    $payload = ConvertFrom-Json -InputObject ($reader.ReadToEnd()) -ErrorAction Stop
    Invoke-AndonCodexHook -Payload $payload -StateDir (Get-AndonCodexStateDir) -At $at -GetProcesses {
        Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name, CommandLine -ErrorAction Stop
    }
}
catch { }
exit 0
