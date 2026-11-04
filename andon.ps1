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
    - 新しい待ちが出たとき、このウィンドウが前面になければタスクバーを点滅させる。
    - 行をクリックすると、cwd を含む *.code-workspace（なければフォルダ）を `code` で開く。
      既に開いているウィンドウがあれば、そのウィンドウが前面に出る。ターミナルのタブまでは選ばない。

.PARAMETER FallbackSec
    更新時刻に変化がなくても `claude agents --json` を呼ぶ間隔（秒）。

.EXAMPLE
    powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File .\andon.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 600)]
    [int]$FallbackSec = 30
)

# ---------------------------------------------------------------------------
# 状態の管理（GUI に依存しない部分。ドットソースして単体で確かめられる）
# ---------------------------------------------------------------------------

$script:State = @{}        # pid -> エントリ
$script:TargetCache = @{}  # cwd -> VS Code で開く対象

function Get-JsonValue {
    param($Object, [string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertFrom-SessionJson {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'claude agents --json の出力が空です' }
    $start = $Json.IndexOf('[')
    $end = $Json.LastIndexOf(']')
    if ($start -lt 0 -or $end -lt $start) { throw 'claude agents --json の出力が JSON 配列ではありません' }
    $parsed = ConvertFrom-Json -InputObject $Json.Substring($start, $end - $start + 1)
    # Windows PowerShell 5.1 は配列を 1 つのオブジェクトとして返すので、ここで展開する
    return , @(foreach ($x in $parsed) { $x })
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
                Name = ''; Cwd = ''; Kind = ''; WaitingFor = ''
            }
            $script:State[$key] = $entry
            if ($entry.Unread) { $alert = $true }
        }
        elseif ($entry.Status -ne $status) {
            $prev = $entry.Status
            $entry.Status = $status
            $entry.Since = $Now
            if ($status -eq 'waiting') { $entry.Unread = $true; $alert = $true }
            elseif ($status -eq 'idle' -and $prev -eq 'busy') { $entry.Unread = $true; $alert = $true }
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

function Get-WorkspaceFolders {
    <# *.code-workspace の folders[].path を絶対パスで返す。JSONC でも読めるよう正規表現で拾う #>
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $text) { return @() }
    $result = @()
    foreach ($m in [regex]::Matches($text, '"path"\s*:\s*"((?:[^"\\]|\\.)*)"')) {
        $p = $m.Groups[1].Value -replace '\\\\', '\'
        try { $result += [IO.Path]::GetFullPath([IO.Path]::Combine($dir, $p)) } catch { }
    }
    return $result
}

function Resolve-VSCodeTarget {
    param([string]$Cwd)
    # Claude が作る worktree（<repo>\.claude\worktrees\<name>）は元の repository として扱う
    $base = $Cwd -replace '\\\.claude\\worktrees\\.*$', ''

    # 1) cwd から repository の root まで遡って *.code-workspace を探す
    $dir = $base
    $repoRoot = $null
    for ($i = 0; $i -lt 4 -and $dir; $i++) {
        $ws = Get-ChildItem -LiteralPath $dir -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($ws) { return $ws.FullName }
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $repoRoot = $dir; break }
        $dir = Split-Path -Parent $dir
    }

    # 2) 隣の repository の *.code-workspace が、folders に cwd を含んでいればそれを使う（multi-root）
    if (-not $repoRoot) { $repoRoot = $base }
    $parent = Split-Path -Parent $repoRoot
    if ($parent) {
        $candidates = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue })
        foreach ($ws in $candidates) {
            foreach ($folder in (Get-WorkspaceFolders -Path $ws.FullName)) {
                if (Test-PathUnder -Path $base -Root $folder) { return $ws.FullName }
            }
        }
    }

    # 3) 見つからなければフォルダを開く（そのフォルダのウィンドウが無ければ新しいウィンドウになる）
    return $base
}

function Find-VSCodeTarget {
    param([string]$Cwd)
    if (-not $Cwd) { return $null }
    if (-not $script:TargetCache.ContainsKey($Cwd)) {
        $script:TargetCache[$Cwd] = Resolve-VSCodeTarget -Cwd $Cwd
    }
    return $script:TargetCache[$Cwd]
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
$script:SessionsDir = Join-Path (Get-ClaudeConfigDir) 'sessions'

if (-not ('AndonNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AndonNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    // FLASHW_ALL | FLASHW_TIMERNOFG: ウィンドウが前面に来るまでタスクバーを点滅させる
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
    Start-Process -FilePath $script:CodeCmd -ArgumentList ('"{0}"' -f $target) -WindowStyle Hidden
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
    $entries = @($script:State.Values | Sort-Object `
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
$btnRead.Add_Click({
        foreach ($e in $script:State.Values) { $e.Unread = $false }
        Update-ListView
    })
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })

$script:PollTask = $null
$script:PollProc = $null
$script:LastSignature = $null
$script:NextPoll = Get-Date
$script:NextRender = Get-Date

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
        try {
            $now = Get-Date
            if ($script:PollTask) {
                if (-not $script:PollTask.IsCompleted) {
                    if (($now - $script:PollStarted).TotalSeconds -gt 30) {
                        try { $script:PollProc.Kill() } catch { }
                        $script:PollTask = $null
                        $lblStatus.Text = 'claude agents --json が応答しません'
                    }
                    return
                }
                $json = $script:PollTask.Result
                $script:PollTask = $null
                $script:PollProc.Dispose()
                $script:PollProc = $null
                $alert = Update-SessionState -Sessions (ConvertFrom-SessionJson $json) -Now $now
                Update-ListView
                $script:NextRender = $now.AddSeconds(5)
                $lblStatus.Text = '更新 ' + $now.ToString('HH:mm:ss')
                if ($alert -and -not $form.ContainsFocus) { [AndonNative]::Flash($form.Handle) }
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
            $script:NextPoll = (Get-Date).AddSeconds(5)
            $lblStatus.Text = 'エラー: ' + $_.Exception.Message
        }
    })

$form.Add_FormClosed({
        $timer.Stop()
        if ($script:PollProc -and -not $script:PollProc.HasExited) { try { $script:PollProc.Kill() } catch { } }
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
    })

$timer.Start()
[void]$form.ShowDialog()
