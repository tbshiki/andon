#Requires -Version 5.1
<#
.SYNOPSIS
    andon を、このユーザーの場所（%LOCALAPPDATA%\Programs\andon）に入れる。新しい版でもう一度実行すると更新になる。

.DESCRIPTION
    このスクリプトと同じフォルダにある andon.ps1 を入れる。ネットワークからは何も落とさない。
    管理者の権限は要らない。ユーザーや PC の実行ポリシーは変えない（ショートカットは、andon のプロセスだけを Bypass で起動する）。

    1. 動いている andon を終わらせる（名前付きのイベント Local\andon-exit で合図し、mutex Local\andon が消えるのを待つ）
    2. andon.ps1・install.ps1・andon.ico・LICENSE を置き、ダウンロードした印（Mark of the Web）を外す
    3. スタートメニューと、スタートアップ（ログオン時に起動）に andon のショートカットを作る
    4. andon を起動する

.PARAMETER Uninstall
    andon を終わらせ、ショートカット、andon と Windows が作ったレジストリのキー、入れたファイルを消す。

.PARAMETER NoStartup
    ログオン時に起動するショートカットを作らない（あれば消す）。
    更新のときにこれを付けなければ、前の状態（スタートアップのショートカットがあるかないか）を引き継ぐ。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\andon\install.ps1" -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStartup
)

# ---------------------------------------------------------------------------
# 実際の場所に依存しない部分（ドットソースして単体で確かめられる）
# ---------------------------------------------------------------------------

function Get-AndonPayload {
    <# 配るファイル。andon.ps1 は必須、ほかはあれば置く #>
    return @('andon.ps1', 'install.ps1', 'andon.ico', 'LICENSE')
}

function Get-AndonLayout {
    <# 入れる場所と、ショートカットの場所 #>
    return [pscustomobject]@{
        InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\andon'
        StartMenu  = Join-Path ([Environment]::GetFolderPath('Programs')) 'andon.lnk'
        Startup    = Join-Path ([Environment]::GetFolderPath('Startup')) 'andon.lnk'
    }
}

function Get-AndonVersion {
    <# andon.ps1 に書いてある版（$script:AndonVersion）。読めなければ $null #>
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $text) { return $null }
    $m = [regex]::Match($text, '(?m)^\$script:AndonVersion\s*=\s*''(\d+\.\d+\.\d+)''')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-ExecutionPolicyAllowed {
    <# グループ ポリシーで決めた実行ポリシーのもとで、署名のない andon を起動できるか。
       グループ ポリシーがなければ、ショートカットの -ExecutionPolicy Bypass が効く。グループ ポリシーはそれより強い。
       RemoteSigned は、ダウンロードした印を外したファイルなら動く。AllSigned と Restricted は署名がないと動かない。
       コンピューターのポリシー（MachinePolicy）が、ユーザーのポリシー（UserPolicy）より優先する #>
    param([string]$MachinePolicy, [string]$UserPolicy)
    $effective = $MachinePolicy
    if (-not $effective -or $effective -eq 'Undefined') { $effective = $UserPolicy }
    return -not ($effective -eq 'AllSigned' -or $effective -eq 'Restricted')
}

function Get-ExtraArguments {
    <# ショートカットの引数のうち、andon.ps1 の後ろに付けたもの（-ScanMs 500 など）。更新しても引き継ぐ #>
    param([string]$Arguments)
    if (-not $Arguments) { return '' }
    $m = [regex]::Match($Arguments, '(?i)[\\/]andon\.ps1"?\s+(\S.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Get-AndonLaunch {
    <# andon を起動するコマンド。ショートカットにも、入れたあとの起動にも使う。
       - Windows PowerShell 5.1 に固定する。どの Windows にもあり、Windows はトレイのアイコンの表示の設定を
         実行ファイルごとに覚えるので、5.1 と 7 を切り替えると、アイコンを出し直すことになるため
       - conhost.exe --headless で、PowerShell のコンソールをウィンドウなしで動かす
       - -File で andon.ps1 を渡す。andon は、自分のためだけのプロセスと判定してアプリ ID を付ける（Test-DedicatedProcess） #>
    param([string]$InstallDir, [string]$ExtraArguments, [string]$SystemRoot = $env:SystemRoot)
    $ps = Join-Path $SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '--headless "{0}" -NoProfile -STA -ExecutionPolicy Bypass -File "{1}"' -f $ps, (Join-Path $InstallDir 'andon.ps1')
    if ($ExtraArguments) { $arguments += ' ' + $ExtraArguments }
    return [pscustomobject]@{
        FilePath         = Join-Path $SystemRoot 'System32\conhost.exe'
        Arguments        = $arguments
        WorkingDirectory = $InstallDir
        PowerShell       = $ps
    }
}

function Test-AndonCommandLine {
    <# プロセスの起動引数が、andon.ps1 を -File で動かしているものか。合図を受けられない古い版の andon を止めるときに、
       止める相手を選ぶのに使う。andon.ps1 を引数に渡しただけのもの、andon.ps1 を読むだけのコマンドは数えない #>
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }
    return [regex]::IsMatch($CommandLine, '(?i)(?:^|\s)-f(?:ile)?\s+(?:"(?:[^"]*[\\/])?andon\.ps1"|(?:[^\s"]*[\\/])?andon\.ps1)(?=\s|$)')
}

function Test-AndonRunning {
    <# andon が動いているか（二重起動を防ぐ mutex があるか）。開いた mutex はすぐ閉じる。
       閉じずにいると mutex が残り、次に起動した andon が二重起動と判断して終わってしまう #>
    param([string]$MutexName = 'Local\andon')
    $m = $null
    try { return [System.Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m) }
    catch [System.UnauthorizedAccessException] { return $true }   # あるが開けない
    finally { if ($m) { $m.Dispose() } }
}

function Send-AndonExit {
    <# 動いている andon に、終わるよう合図する。合図を受ける andon がなければ $false #>
    param([string]$EventName = 'Local\andon-exit')
    $e = $null
    try {
        if (-not [System.Threading.EventWaitHandle]::TryOpenExisting($EventName, [ref]$e)) { return $false }
        return $e.Set()
    }
    catch { return $false }
    finally { if ($e) { $e.Dispose() } }
}

function Wait-AndonExit {
    <# andon が終わる（mutex が消える）のを待つ。時間内に終われば $true #>
    param([string]$MutexName = 'Local\andon', [int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (Test-AndonRunning -MutexName $MutexName) {
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 200
    }
    return $true
}

function Get-StartupAction {
    <# スタートアップのショートカットをどうするか。create（作る・書き直す）、remove（消す）、none（何もしない）。
       更新のときは、前の状態を引き継ぐ。消した人のために、更新のたびに作り直さない #>
    param([bool]$NoStartup, [bool]$IsUpdate, [bool]$Exists)
    if ($NoStartup) {
        if ($Exists) { return 'remove' }
        return 'none'
    }
    if (-not $IsUpdate -or $Exists) { return 'create' }
    return 'none'
}

function Copy-AndonFiles {
    <# 配るファイルを $SourceDir から $InstallDir に置き、ダウンロードした印を外す。置いたファイルのパスを返す。
       同じフォルダ（入れた場所の install.ps1 を実行したとき）なら写さず、印だけ外す #>
    param([string]$SourceDir, [string]$InstallDir)
    $src = [IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
    $dst = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $src 'andon.ps1') -PathType Leaf)) {
        throw "andon.ps1 が見つかりません: $src"
    }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    $placed = @()
    foreach ($name in Get-AndonPayload) {
        $from = Join-Path $src $name
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
        $to = Join-Path $dst $name
        if ($src -ine $dst) {
            # 写す途中で失敗しても置いてあるファイルが壊れないよう、別の名前に写してから置き換える
            $tmp = $to + '.new'
            Copy-Item -LiteralPath $from -Destination $tmp -Force
            Move-Item -LiteralPath $tmp -Destination $to -Force
        }
        Unblock-File -LiteralPath $to
        $placed += $to
    }
    return $placed
}

function New-AndonShortcut {
    <# andon を起動するショートカット（.lnk）を作る。あれば書き直す #>
    param([string]$Path, $Launch)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($Path)
        $lnk.TargetPath = $Launch.FilePath
        $lnk.Arguments = $Launch.Arguments
        $lnk.WorkingDirectory = $Launch.WorkingDirectory
        $iconPath = Join-Path $Launch.WorkingDirectory 'andon.ico'
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $lnk.IconLocation = $iconPath + ',0' }
        else { $lnk.IconLocation = $Launch.PowerShell + ',0' }
        $lnk.Description = 'Claude Code のセッションの待ち・完了を一覧する'
        $lnk.Save()
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Get-ShortcutArguments {
    <# ショートカットの引数。ショートカットがなければ $null #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    try { return [string]$shell.CreateShortcut($Path).Arguments }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Test-AndonShortcut {
    <# andon.ps1 を起動するショートカットか #>
    param([string]$Path)
    $arguments = Get-ShortcutArguments -Path $Path
    return [bool]($arguments -and $arguments -match '(?i)[\\/"\s]andon\.ps1')
}

function Remove-AndonShortcut {
    <# andon.ps1 を起動するショートカットなら消す。消したら $true。同じ名前でも、別のものを起動するショートカットは消さない #>
    param([string]$Path)
    if (-not (Test-AndonShortcut -Path $Path)) { return $false }
    Remove-Item -LiteralPath $Path -Force
    return $true
}

function Remove-AndonRegistry {
    <# andon と Windows が作ったレジストリのキーを消す。消したキーを返す。
       アプリ ID の表示名（andon が起動のたびに書く）と、通知の設定（最初の通知で Windows が作る）。
       表示名を登録できなかったときに andon が使う ID（andon）の通知の設定も消す #>
    param(
        [string]$ClassesRoot = 'HKCU:\Software\Classes\AppUserModelId',
        [string]$NotificationsRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    )
    $removed = @()
    foreach ($key in @((Join-Path $ClassesRoot 'tbshiki.andon'), (Join-Path $NotificationsRoot 'tbshiki.andon'), (Join-Path $NotificationsRoot 'andon'))) {
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
            $removed += $key
        }
    }
    return $removed
}

# ドットソースされたときは関数の定義だけで止める
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------

# 署名のないスクリプトが Constrained Language Mode で動く PC（App Control など）では、andon は Add-Type と
# Windows Forms を使えないので動かない。入れても動かないので、ここで止める
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'この PC では PowerShell が制限された言語モード（Constrained Language Mode）で動くため、andon は動きません。' -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'

function Stop-AndonProcess {
    <# 合図を受けられない古い版の andon を止める。andon.ps1 を -File で動かしている PowerShell だけを選ぶ。
       対話で使っているシェルで直接動かした andon は、起動引数で見分けられないので止めない #>
    $stopped = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $PID) { continue }
        if (-not (Test-AndonCommandLine -CommandLine $p.CommandLine)) { continue }
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
    }
    return $stopped
}

function Stop-RunningAndon {
    <# 動いている andon を終わらせる。終わらせられなければ $false #>
    if (-not (Test-AndonRunning)) { return $true }
    Write-Host '動いている andon を終わらせます。'
    if ((Send-AndonExit) -and (Wait-AndonExit -TimeoutSec 10)) { return $true }
    # 合図を受けられない古い版は、プロセスを止める。トレイのアイコンは、マウスを重ねるまで残る
    if ((Stop-AndonProcess) -gt 0) { [void](Wait-AndonExit -TimeoutSec 10) }
    return -not (Test-AndonRunning)
}

function Start-Andon {
    <# andon を起動する。PowerShell 7 から実行したときに、7 のモジュールのパスを Windows PowerShell 5.1 の andon に
       引き継がない（5.1 が 7 のモジュールを読もうとして失敗することがある）。PSModulePath がなければ、5.1 は既定のパスを使う #>
    param($Launch)
    $saved = $env:PSModulePath
    try {
        $env:PSModulePath = $null
        Start-Process -FilePath $Launch.FilePath -ArgumentList $Launch.Arguments -WorkingDirectory $Launch.WorkingDirectory
    }
    finally { $env:PSModulePath = $saved }
}

try {
    $layout = Get-AndonLayout
    $notStopped = 'andon を終わらせられませんでした。トレイのアイコンを右クリックして「終了」を選んでから、もう一度実行してください。'

    if ($Uninstall) {
        if (-not (Stop-RunningAndon)) { Write-Host $notStopped -ForegroundColor Red; exit 1 }
        foreach ($lnk in @($layout.StartMenu, $layout.Startup)) {
            if (Remove-AndonShortcut -Path $lnk) { Write-Host "消しました: $lnk" }
        }
        foreach ($key in @(Remove-AndonRegistry)) { Write-Host "消しました: $key" }
        if (Test-Path -LiteralPath $layout.InstallDir) {
            # 消すフォルダを作業フォルダにしていると、フォルダを消せない
            Set-Location -LiteralPath $env:USERPROFILE
            [Environment]::CurrentDirectory = $env:USERPROFILE
            try {
                Remove-Item -LiteralPath $layout.InstallDir -Recurse -Force
                Write-Host "消しました: $($layout.InstallDir)"
            }
            catch {
                # 起動したシェルなど、ほかのプロセスがそのフォルダを作業フォルダにしていると、中身を消してもフォルダが残る
                Write-Host "注意: フォルダを消しきれませんでした。そのフォルダを開いているシェルやエクスプローラーを閉じてから消してください: $($layout.InstallDir)" -ForegroundColor Yellow
            }
        }
        Write-Host 'andon を消しました。'
        exit 0
    }

    $source = $PSScriptRoot
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'andon.ps1') -PathType Leaf)) {
        Write-Host 'andon.ps1 が見つかりません。install.ps1 は、andon.ps1 と同じフォルダに置いたまま、ファイルとして実行してください。' -ForegroundColor Red
        exit 1
    }
    $version = Get-AndonVersion -Path (Join-Path $source 'andon.ps1')

    # グループ ポリシーの実行ポリシーは、ショートカットの -ExecutionPolicy Bypass より強い
    $machinePolicy = ''
    $userPolicy = ''
    try {
        $machinePolicy = [string](Get-ExecutionPolicy -Scope MachinePolicy)
        $userPolicy = [string](Get-ExecutionPolicy -Scope UserPolicy)
    }
    catch { }   # 調べられなければ、起動できるものとして進める
    if (-not (Test-ExecutionPolicyAllowed -MachinePolicy $machinePolicy -UserPolicy $userPolicy)) {
        Write-Host "グループ ポリシーで実行ポリシーが決められているため（MachinePolicy: $machinePolicy、UserPolicy: $userPolicy）、署名のない andon は起動できません。" -ForegroundColor Red
        exit 1
    }

    # 起動に使うものは、ショートカットを作る前に確かめる
    $launch = Get-AndonLaunch -InstallDir $layout.InstallDir
    foreach ($required in @($launch.FilePath, $launch.PowerShell)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Write-Host "見つかりません: $required" -ForegroundColor Red; exit 1 }
    }
    # なくても入れられる（後から入れればよい）。andon は、起動したときに見つからなければメッセージを出して終わる
    if (-not (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '注意: claude が PATH に見つかりません。andon は claude agents --json でセッションの状態を読みます。' -ForegroundColor Yellow
    }
    $codeCmd = @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')) |
        Where-Object { Test-Path -LiteralPath $_ }
    if (-not (Get-Command code.cmd -CommandType Application -ErrorAction SilentlyContinue) -and -not $codeCmd) {
        Write-Host '注意: VS Code の code.cmd が見つかりません。andon は、これを手がかりに VS Code を探します。' -ForegroundColor Yellow
    }

    # andon.ps1 の後ろに付けた引数（-ScanMs など）は、前のショートカットから引き継ぐ
    $isUpdate = Test-Path -LiteralPath (Join-Path $layout.InstallDir 'andon.ps1') -PathType Leaf
    $previous = Get-ShortcutArguments -Path $layout.StartMenu
    if (-not $previous) { $previous = Get-ShortcutArguments -Path $layout.Startup }
    $launch = Get-AndonLaunch -InstallDir $layout.InstallDir -ExtraArguments (Get-ExtraArguments -Arguments $previous)
    $startupAction = Get-StartupAction -NoStartup $NoStartup.IsPresent -IsUpdate $isUpdate -Exists (Test-AndonShortcut -Path $layout.Startup)

    if (-not (Stop-RunningAndon)) { Write-Host $notStopped -ForegroundColor Red; exit 1 }
    [void](Copy-AndonFiles -SourceDir $source -InstallDir $layout.InstallDir)
    New-AndonShortcut -Path $layout.StartMenu -Launch $launch
    switch ($startupAction) {
        'create' { New-AndonShortcut -Path $layout.Startup -Launch $launch }
        'remove' { [void](Remove-AndonShortcut -Path $layout.Startup) }
    }

    # 手で置いた別のショートカット（clone を起動するものなど）が残っていると、どちらが起動するか決まらない
    $startupDir = Split-Path -Parent $layout.Startup
    foreach ($other in @(Get-ChildItem -LiteralPath $startupDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
        if ($other.FullName -ieq $layout.Startup) { continue }
        if (Test-AndonShortcut -Path $other.FullName) {
            Write-Host "注意: スタートアップに、andon を起動する別のショートカットがあります。要らなければ消してください: $($other.FullName)" -ForegroundColor Yellow
        }
    }

    Start-Andon -Launch $launch

    $name = 'andon'
    if ($version) { $name = "andon $version" }
    Write-Host ('{0} を入れて、起動しました: {1}' -f $name, $layout.InstallDir)
    Write-Host 'トレイから「終了」したあとは、スタートメニューの「andon」で起動できます。'
    if (Test-AndonShortcut -Path $layout.Startup) { Write-Host 'ログオンしたときにも起動します（スタートアップ）。' }
    Write-Host ('消すときは: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall' -f (Join-Path $layout.InstallDir 'install.ps1'))
    exit 0
}
catch {
    Write-Host ('失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
