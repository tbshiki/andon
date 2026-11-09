#Requires -Version 5.1
<#
.SYNOPSIS
    andon を、このユーザーの場所（%LOCALAPPDATA%\Programs\andon）に入れる。新しいバージョンでもう一度実行するとアップデートになる。

.DESCRIPTION
    このスクリプトと同じフォルダにある andon.ps1 を入れる。ネットワークからは何も落とさない。
    管理者の権限は要らない。ユーザーや PC の実行ポリシーは変えない（ショートカットは、andon のプロセスだけを Bypass で起動する）。
    同じフォルダの install.cmd をダブルクリックしても、このスクリプトを実行する。

    1. 動いている andon を終わらせる（名前付きのイベント Local\andon-exit で合図し、mutex Local\andon が消えるのを待つ）
    2. 配るファイル（Get-AndonPayload）を置き、ダウンロードした印（Mark of the Web）を外す
    3. スタートメニューに andon のショートカットを作る。スタートアップ（ログオン時に起動）のショートカットは、
       新しくインストールするときは作らない（andon のトレイのメニューの「ログオン時に起動」で作る）。アップデートのときは、あれば書き直す
    4. Windows の「インストールされているアプリ」に andon を登録する（HKCU の Uninstall\tbshiki.andon）
    5. andon を起動する

.PARAMETER Uninstall
    andon を終わらせ、ショートカット、andon と Windows が作ったレジストリのキー、入れたファイルを消す。

.PARAMETER NoStartup
    ログオン時に起動するショートカットを、あれば消す。
    付けなければ、新しくインストールするときは作らず、アップデートのときは前の状態（スタートアップのショートカットがあるかないか）を引き継ぐ。

.PARAMETER PauseOnError
    失敗したときに、理由を読めるよう、Enter キーを押すまで閉じない。
    「インストールされているアプリ」から消すとき（登録したアンインストールのコマンド）に付ける。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\andon\install.ps1" -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStartup,
    [switch]$PauseOnError
)

# ---------------------------------------------------------------------------
# 実際の場所に依存しない部分（ドットソースして単体で確かめられる）
# ---------------------------------------------------------------------------

function Get-AndonPayload {
    <# 配るファイル。Release の zip に入れるもの。入れるときは、andon.ps1 は必須、ほかはあれば置く。
       名前は、英数字と . _ - だけにする（古い andon は、アップデートの zip を展開する前に、項目の名前をこの形に限って確かめる）
       - install.cmd: ダブルクリックで install.ps1 を実行する入口
       - README.txt: zip を開いた人が読む、入れ方の説明
       - andon-codex-hook.ps1: Codex の hooks から呼ばれ、Codex のセッションの状態を書く。名前を変えない
         （利用者の ~/.codex/hooks.json に、インストール先のこのファイルのパスが書かれ、Codex はそれを信頼している） #>
    return @('andon.ps1', 'install.ps1', 'install.cmd', 'README.txt', 'andon.ico', 'LICENSE', 'andon-codex-hook.ps1')
}

function New-AndonPackage {
    <# 配るファイルを zip（andon-<版>.zip）にまとめ、zip のパスを返す。Release の workflow が使う。
       入れるときと違い、配るファイルが 1 つでも欠けていれば例外にする（欠けた zip を配らない） #>
    param([string]$SourceDir, [string]$OutDir, [string]$Version)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "版の形が MAJOR.MINOR.PATCH ではありません: $Version" }
    $files = foreach ($name in Get-AndonPayload) {
        $path = Join-Path $SourceDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "配るファイルがありません: $name" }
        $path
    }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $zip = Join-Path $OutDir "andon-$Version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    # zip の直下に置く。エクスプローラーの「すべて展開」は、zip の名前のフォルダを作ってそこに展開する
    Compress-Archive -LiteralPath $files -DestinationPath $zip
    return $zip
}

function Remove-AndonCodexData {
    <# アンインストールのとき、Codex の hooks.json から andon の hook を消し（ほかの hook は残す）、andon の hook が書いた
       記録のフォルダ（$DataDir）を消す。hooks.json を扱う関数は andon-codex-hook.ps1（$HookScript）にある。
       $HooksPath を渡さなければ、Codex の設定のフォルダの hooks.json。出すメッセージを返す #>
    param([string]$HookScript, [string]$DataDir, [string]$HooksPath = '')
    $lines = @()
    if (Test-Path -LiteralPath $HookScript -PathType Leaf) {
        $shown = $HooksPath
        if (-not $shown) { $shown = '~\.codex\hooks.json' }
        try {
            . $HookScript
            if (-not $HooksPath) { $HooksPath = Join-Path (Get-AndonCodexHome) 'hooks.json' }
            $shown = $HooksPath
            $current = Read-AndonCodexHooksFile -Path $HooksPath
            if (Test-AndonCodexHooks $current) {
                # andon の hook の後ろにあるほかの hook は前に詰まり、Codex で信頼し直しになる（D-116）。確かめられないので知らせる
                $shifted = @(Get-AndonCodexHooksShifted $current)
                Set-AndonCodexHooks -Enabled $false -Path $HooksPath -Command ''
                $lines += "andon の hook を消しました: $HooksPath"
                if ($shifted.Count -gt 0) {
                    $lines += "注意: andon の hook の後ろにあった hook（$($shifted -join '、')）は、Codex で信頼し直しが要ります。ターミナルで codex を起動し、/hooks を開いて、信頼し直してください。"
                }
            }
        }
        catch {
            $lines += "注意: Codex の hooks から andon の hook を消せませんでした。$shown から、andon-codex-hook.ps1 を動かす hook を手で消してください: $($_.Exception.Message)"
        }
    }
    if ($DataDir -and (Test-Path -LiteralPath $DataDir)) {
        try {
            Remove-Item -LiteralPath $DataDir -Recurse -Force
            $lines += "消しました: $DataDir"
        }
        catch { $lines += "注意: フォルダを消しきれませんでした: $DataDir" }
    }
    return , $lines
}

function Get-AndonLayout {
    <# 入れる場所と、ショートカットの場所と、「インストールされているアプリ」に登録するキー #>
    return [pscustomobject]@{
        InstallDir   = Join-Path $env:LOCALAPPDATA 'Programs\andon'
        StartMenu    = Join-Path ([Environment]::GetFolderPath('Programs')) 'andon.lnk'
        Startup      = Join-Path ([Environment]::GetFolderPath('Startup')) 'andon.lnk'
        UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\tbshiki.andon'
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

function Get-InheritedExtraArguments {
    <# 書き直すショートカットに引き継ぐ、andon.ps1 の後ろの引数。スタートメニューとスタートアップのショートカットは、
       それぞれ自分の引数を引き継ぐ（ログオンで動くスタートアップの方にだけ -NoUpdateCheck などを付けた人の設定を消さない）。
       自分のショートカットがなければ（新しく作るとき）、もう一方のショートカットの引数を使う。
       $Own と $Other は、ショートカットの引数（Get-ShortcutArguments。ショートカットがなければ $null） #>
    param([string]$Own, [string]$Other)
    if ($Own) { return Get-ExtraArguments -Arguments $Own }
    return Get-ExtraArguments -Arguments $Other
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
    <# スタートアップのショートカットをどうするか。create（書き直す）、remove（消す）、none（何もしない）。
       新しく入れるときは作らない（andon のトレイのメニューの「ログオン時に起動」で作る）。
       更新のときは、前の状態を引き継ぐ。あれば、新しい起動のコマンドで書き直す。消した人のために、作り直さない #>
    param([bool]$NoStartup, [bool]$IsUpdate, [bool]$Exists)
    if ($NoStartup) {
        if ($Exists) { return 'remove' }
        return 'none'
    }
    if ($IsUpdate -and $Exists) { return 'create' }
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

function Test-StartupDisabled {
    <# タスク マネージャーの「スタートアップ アプリ」で、andon のショートカット（andon.lnk）を無効にしているか。
       Windows は StartupApproved\StartupFolder に、ショートカットの名前で記録する。確かめた値は、先頭のバイトが
       02 なら有効、03 なら無効。ほかの値も、先頭のバイトの下位のビットで見分ける #>
    param([string]$StartupApprovedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')
    if (-not (Test-Path -LiteralPath $StartupApprovedKey)) { return $false }
    $value = (Get-Item -LiteralPath $StartupApprovedKey).GetValue('andon.lnk')
    return [bool]($value -is [byte[]] -and $value.Length -gt 0 -and ($value[0] -band 1))
}

function Get-AndonUninstallEntry {
    <# 「インストールされているアプリ」に書く値（名前と値の組。[int] は DWORD、ほかは文字列）。
       アンインストールのコマンドは、cmd.exe を通さず、Windows PowerShell 5.1 を絶対パスで直接起動する。
       - cmd.exe は、パスの %VAR% を展開する
       - install.cmd から消すと、実行中の install.cmd を自分で消すことになる
       パスは引用符で囲む。失敗したときは、理由を読めるよう -PauseOnError で Enter キーを待つ #>
    param([string]$InstallDir, [string]$Version, [string]$PowerShell, [long]$SizeBytes = 0, [datetime]$Date = (Get-Date))
    $values = [ordered]@{
        DisplayName     = 'andon'
        Publisher       = 'tbshiki'
        InstallLocation = $InstallDir
        DisplayIcon     = Join-Path $InstallDir 'andon.ico'
        UninstallString = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Uninstall -PauseOnError' -f $PowerShell, (Join-Path $InstallDir 'install.ps1')
        URLInfoAbout    = 'https://github.com/tbshiki/andon'
        InstallDate     = $Date.ToString('yyyyMMdd')
        EstimatedSize   = [int][Math]::Ceiling($SizeBytes / 1024)   # KB
        NoModify        = [int]1
        NoRepair        = [int]1
    }
    if ($Version) { $values['DisplayVersion'] = $Version }
    return $values
}

function Set-AndonUninstallEntry {
    <# 「インストールされているアプリ」に andon を登録する。あれば書き直す（入れるたびに書き、バージョンをそろえる） #>
    param([string]$Key, [System.Collections.IDictionary]$Values)
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    foreach ($name in $Values.Keys) {
        $value = $Values[$name]
        $type = 'String'
        if ($value -is [int]) { $type = 'DWord' }
        New-ItemProperty -LiteralPath $Key -Name $name -PropertyType $type -Value $value -Force | Out-Null
    }
}

function Remove-AndonRegistry {
    <# andon と Windows が作ったレジストリのキーと値を消す。消したものを返す。
       - アプリ ID の表示名（andon が起動のたびに書く）と、通知の設定（最初の通知で Windows が作る）。
         表示名を登録できなかったときに andon が使う ID（andon）の通知の設定も消す
       - 「インストールされているアプリ」への登録（install.ps1 が入れるたびに書く）
       - スタートアップのショートカットの有効・無効（Windows がショートカットの名前 andon.lnk で記録する。
         タスク マネージャーの「スタートアップ アプリ」で切り替えるもの）。残すと、入れ直したときに前の状態を引き継ぐ
       - andon の設定（andon が書く $SettingsRoot\andon。ウィンドウの位置と大きさ、「常に手前」）。
         $SettingsRoot（tbshiki）は、ほかに何もなければ消す #>
    param(
        [string]$ClassesRoot = 'HKCU:\Software\Classes\AppUserModelId',
        [string]$NotificationsRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings',
        [string]$UninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        [string]$StartupApprovedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
        [string]$SettingsRoot = 'HKCU:\Software\tbshiki'
    )
    $removed = @()
    foreach ($key in @((Join-Path $ClassesRoot 'tbshiki.andon'), (Join-Path $NotificationsRoot 'tbshiki.andon'), (Join-Path $NotificationsRoot 'andon'), (Join-Path $UninstallRoot 'tbshiki.andon'), (Join-Path $SettingsRoot 'andon'))) {
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
            $removed += $key
        }
    }
    if (Test-Path -LiteralPath $SettingsRoot) {
        $root = Get-Item -LiteralPath $SettingsRoot
        if ($root.SubKeyCount -eq 0 -and $root.ValueCount -eq 0) {
            Remove-Item -LiteralPath $SettingsRoot -Force
            $removed += $SettingsRoot
        }
    }
    if ((Test-Path -LiteralPath $StartupApprovedKey) -and ((Get-Item -LiteralPath $StartupApprovedKey).GetValueNames() -contains 'andon.lnk')) {
        Remove-ItemProperty -LiteralPath $StartupApprovedKey -Name 'andon.lnk'
        $removed += (Join-Path $StartupApprovedKey 'andon.lnk')
    }
    return $removed
}

# ドットソースされたときは関数の定義だけで止める
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------

function Exit-Install {
    <# 終了コードを返して終わる。-PauseOnError を付けたときは、失敗したら、理由を読めるよう Enter キーを押すまで閉じない #>
    param([int]$Code)
    if ($Code -ne 0 -and $PauseOnError) { [void](Read-Host 'Enter キーで閉じます') }
    exit $Code
}

# 署名のないスクリプトが Constrained Language Mode で動く PC（App Control など）では、andon は Add-Type と
# Windows Forms を使えないので動かない。入れても動かないので、ここで止める
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'この PC では PowerShell が制限された言語モード（Constrained Language Mode）で動くため、andon は動きません。' -ForegroundColor Red
    Exit-Install 1
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
    Write-Host '動いている andon を終了します。'
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
    $notStopped = 'andon を終了できませんでした。トレイのアイコンを右クリックして「終了」を選んでから、もう一度実行してください。'

    if ($Uninstall) {
        if (-not (Stop-RunningAndon)) { Write-Host $notStopped -ForegroundColor Red; Exit-Install 1 }
        foreach ($lnk in @($layout.StartMenu, $layout.Startup)) {
            if (Remove-AndonShortcut -Path $lnk) { Write-Host "消しました: $lnk" }
        }
        foreach ($key in @(Remove-AndonRegistry)) { Write-Host "消しました: $key" }
        # Codex の hooks.json から andon の hook を消し、hook が書いた記録を消す。インストール先を消す前に行う
        foreach ($line in @(Remove-AndonCodexData -HookScript (Join-Path $PSScriptRoot 'andon-codex-hook.ps1') -DataDir (Join-Path $env:LOCALAPPDATA 'andon'))) {
            if ($line.StartsWith('注意:')) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
        }
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
        Exit-Install 0
    }

    # 64 ビットの Windows で 32 ビットの PowerShell から実行すると、System32 が SysWOW64 に読み替えられ、andon を起動する
    # conhost.exe が見えない（32 ビットのプログラムから開いたときなど）。install.cmd は、64 ビットの PowerShell で実行する
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Write-Host ('この PowerShell（{0}）は 32 ビットなので、andon をインストールできません。install.cmd をダブルクリックするか、64 ビットの PowerShell（{1}）で実行してください。' -f $PSHOME, (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) -ForegroundColor Red
        Exit-Install 1
    }

    $source = $PSScriptRoot
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'andon.ps1') -PathType Leaf)) {
        Write-Host 'andon.ps1 が見つかりません。install.ps1 は、andon.ps1 と同じフォルダに置いたまま、ファイルとして実行してください。' -ForegroundColor Red
        Exit-Install 1
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
        Exit-Install 1
    }

    # 起動に使うものは、ショートカットを作る前に確かめる
    $launch = Get-AndonLaunch -InstallDir $layout.InstallDir
    foreach ($required in @($launch.FilePath, $launch.PowerShell)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Write-Host "見つかりません: $required" -ForegroundColor Red; Exit-Install 1 }
    }
    # なくても入れられる（後から入れればよい）。andon は、起動したときに見つからなければメッセージを出して終わる
    if (-not (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '注意: claude が PATH に見つかりません。andon は claude agents --json でセッションの状態を読みます。' -ForegroundColor Yellow
    }
    # VS Code はなくても動く。クリックで VS Code を開けないだけ（VS Code の外のターミナルのウィンドウは前面に出せる）
    $codeCmd = @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')) |
        Where-Object { Test-Path -LiteralPath $_ }
    if (-not (Get-Command code.cmd -CommandType Application -ErrorAction SilentlyContinue) -and -not $codeCmd) {
        Write-Host '注意: VS Code の code.cmd が見つかりません。andon は動きますが、クリックしても VS Code では開けません（cmd や PowerShell のウィンドウは前面に出せます）。' -ForegroundColor Yellow
    }

    # andon.ps1 の後ろに付けた引数（-ScanMs など）は、ショートカットごとに、前のショートカットから引き継ぐ。
    # インストールしたあとの起動には、スタートメニューの方を使う
    $isUpdate = Test-Path -LiteralPath (Join-Path $layout.InstallDir 'andon.ps1') -PathType Leaf
    $menuArguments = Get-ShortcutArguments -Path $layout.StartMenu
    $startupArguments = Get-ShortcutArguments -Path $layout.Startup
    $launch = Get-AndonLaunch -InstallDir $layout.InstallDir -ExtraArguments (Get-InheritedExtraArguments -Own $menuArguments -Other $startupArguments)
    $startupLaunch = Get-AndonLaunch -InstallDir $layout.InstallDir -ExtraArguments (Get-InheritedExtraArguments -Own $startupArguments -Other $menuArguments)
    $startupAction = Get-StartupAction -NoStartup $NoStartup.IsPresent -IsUpdate $isUpdate -Exists (Test-AndonShortcut -Path $layout.Startup)

    if (-not (Stop-RunningAndon)) { Write-Host $notStopped -ForegroundColor Red; Exit-Install 1 }
    $placed = @(Copy-AndonFiles -SourceDir $source -InstallDir $layout.InstallDir)
    New-AndonShortcut -Path $layout.StartMenu -Launch $launch
    switch ($startupAction) {
        'create' { New-AndonShortcut -Path $layout.Startup -Launch $startupLaunch }
        'remove' { [void](Remove-AndonShortcut -Path $layout.Startup) }
    }

    # 「インストールされているアプリ」に登録する。登録できなくても andon は動くので、止めずに知らせる
    try {
        $size = 0
        foreach ($file in $placed) { $size += (Get-Item -LiteralPath $file).Length }
        $entry = Get-AndonUninstallEntry -InstallDir $layout.InstallDir -Version $version -PowerShell $launch.PowerShell -SizeBytes $size
        Set-AndonUninstallEntry -Key $layout.UninstallKey -Values $entry
    }
    catch {
        Write-Host ('注意: 「インストールされているアプリ」に登録できませんでした: ' + $_.Exception.Message) -ForegroundColor Yellow
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
    Write-Host ('{0} をインストールして、起動しました: {1}' -f $name, $layout.InstallDir)
    Write-Host 'トレイから「終了」したあとは、スタートメニューの「andon」で起動できます。'
    if (Test-AndonShortcut -Path $layout.Startup) {
        if (Test-StartupDisabled) { Write-Host 'スタートアップは、タスク マネージャーで無効にしてあるので、ログオンしたときには起動しません。トレイのアイコンを右クリックして「ログオン時に起動」を選ぶと、有効に戻ります。' }
        else { Write-Host 'ログオンしたときにも起動します（スタートアップ）。' }
    }
    else { Write-Host 'ログオンしたときにも起動するには、トレイのアイコンを右クリックして「ログオン時に起動」を選びます。' }
    Write-Host '消すときは、Windows の「設定」→「アプリ」→「インストールされているアプリ」で andon を選びます。'
    Write-Host ('PowerShell から消すときは: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall' -f (Join-Path $layout.InstallDir 'install.ps1'))
    Exit-Install 0
}
catch {
    Write-Host ('失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
    Exit-Install 1
}
