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
      通知をクリックすると、そのセッションを開く。送り元は、プロセスのアプリ ID を andon にして「andon」と表示させる。
    - 行をクリックすると、cwd を含む *.code-workspace（なければ repository の root）を VS Code で開く。
      既に開いているウィンドウがあれば、そのウィンドウが前面に出る。ターミナルのタブまでは選ばない。

.PARAMETER FallbackSec
    更新時刻に変化がなくても `claude agents --json` を呼ぶ間隔（秒）。

.PARAMETER ScanMs
    sessions/*.json の名前と更新時刻を見る間隔（ミリ秒）。長くすると、状態の変化に気付くのが遅れる。
    経過時間の表示は 5 秒ごとに更新するので、それより長くはできない。

.EXAMPLE
    Start-Process conhost.exe '--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\andon.ps1'
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 600)]
    [int]$FallbackSec = 30,

    [ValidateRange(200, 5000)]
    [int]$ScanMs = 1000
)

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

        $entry = $script:State[$key]
        if (-not $entry) {
            # 起動時点で idle のものは、いつ終わったか分からないので既読として扱う
            $entry = [pscustomobject]@{
                Key = $key; Status = $status; Since = $null; Unread = ($status -eq 'waiting')
                Name = ''; Cwd = ''; Kind = ''; WaitingFor = ''; AlertAt = $null
                Sdk = $null   # 拡張機能のパネルなど、ターミナルではなく SDK から動かしているか。$null は未判定
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

function Stop-ProcessTree {
    <# プロセスと、その子孫のプロセスを止める。claude が .cmd の場合、cmd.exe だけを止めると node が残るため #>
    param([int]$Id)
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -Id ([int]$child.ProcessId)
    }
    try { (Get-Process -Id $Id -ErrorAction Stop).Kill() } catch { }
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
# AndonNative とは別の型にする。同じセッションで前の版の andon を動かしていると、前の版の AndonNative が残っていて、
# 定義し直せないため
try {
    if (-not ('AndonAppId' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class AndonAppId {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
    }
    [void][AndonAppId]::SetCurrentProcessExplicitAppUserModelID('andon')
}
catch { }

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

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:Icons['none']
$tray.Text = 'andon'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('表示')
$miTrayRead = $trayMenu.Items.Add('すべて既読')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $trayMenu.Items.Add('終了')
$tray.ContextMenuStrip = $trayMenu
$script:Exiting = $false
$script:NoticeKey = $null

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
    if (-not [object]::ReferenceEquals($tray.Icon, $icon)) { $tray.Icon = $icon; $form.Icon = $icon }
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
        $e = $script:State[[string]$script:NoticeKey]
        if ($e) { Open-Session -Entry $e; Update-ListView }
    })
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
        try {
            $now = Get-Date
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
                    if ($form.Visible) { [AndonNative]::Flash($form.Handle) }
                    $notice = Get-AlertNotice -Entries @($script:State.Values) -Now $now
                    if ($notice) {
                        $script:NoticeKey = $notice.Key   # 通知をクリックしたら、このセッションを開く
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
        if ($script:PollProc -and -not $script:PollProc.HasExited) { try { Stop-ProcessTree -Id $script:PollProc.Id } catch { } }
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
    })

$tray.Visible = $true
$timer.Start()
# ShowDialog はウィンドウを隠すと終わってしまうので、トレイに隠せるよう Application.Run で動かす
[System.Windows.Forms.Application]::Run($form)
