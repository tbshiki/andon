#Requires -Version 5.1
<#
.SYNOPSIS
    andon.ps1 と install.ps1 の、GUI と実際のインストール先に依存しない部分を確かめる。Pester などの依存はない。
    失敗があれば終了コード 1 を返す。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Andon.ps1

.EXAMPLE
    pwsh -NoProfile -File .\tests\Test-Andon.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'andon.ps1')
. (Join-Path $root 'install.ps1')

$script:Count = 0
$script:Failures = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:Count++
    if ($Actual -ceq $Expected) {
        Write-Host "[OK] $Message"
    }
    else {
        Write-Host "[FAIL] $Message`n       expected: $Expected`n       actual:   $Actual" -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-PathEqual {
    param([string]$Actual, [string]$Expected, [string]$Message)
    $script:Count++
    if ($Actual -ieq $Expected) {
        Write-Host "[OK] $Message"
    }
    else {
        Write-Host "[FAIL] $Message`n       expected: $Expected`n       actual:   $Actual" -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-True {
    param($Condition, [string]$Message)
    Assert-Equal ([bool]$Condition) $true $Message
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Message)
    $script:Count++
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if ($threw) {
        Write-Host "[OK] $Message"
    }
    else {
        Write-Host "[FAIL] $Message（例外が出なかった）" -ForegroundColor Red
        $script:Failures++
    }
}

function New-Session {
    param([int]$Id, [string]$Status, [string]$WaitingFor)
    $o = [ordered]@{ pid = $Id; cwd = "C:\work\s$Id"; kind = 'interactive'; name = "s$Id"; status = $Status }
    if ($WaitingFor) { $o.waitingFor = $WaitingFor }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------------------
Write-Host '== エンコーディング（Windows PowerShell 5.1 は BOM なし UTF-8 を読み違える）'
foreach ($f in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$rel は UTF-8 BOM 付き"
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Assert-True (-not [regex]::IsMatch($text, "(?<!`r)`n")) "$rel の改行は CRLF"
}

# ---------------------------------------------------------------------------
Write-Host '== ConvertFrom-SessionJson'
$list = ConvertFrom-SessionJson '[{"pid":1,"status":"idle"}]'
Assert-Equal $list.Count 1 '要素が 1 つの配列でも 1 件として返す'
Assert-Equal $list[0].pid 1 '要素の値を読める'
Assert-Equal (ConvertFrom-SessionJson '[{"pid":1},{"pid":2}]').Count 2 '2 件の配列'
Assert-Equal (ConvertFrom-SessionJson '[]').Count 0 '空の配列'
Assert-Equal (ConvertFrom-SessionJson "notice`n[{`"pid`":3}]").Count 1 '配列の前に余計な行があっても読める'
Assert-Equal (ConvertFrom-SessionJson "[notice] update available`n[{`"pid`":4}]")[0].pid 4 '[ で始まる通知の行が前にあっても読める'
Assert-Equal (ConvertFrom-SessionJson "[{`"pid`":5}]`n[done]")[0].pid 5 '] で終わる行が後ろにあっても読める'
Assert-Equal (ConvertFrom-SessionJson "[`r`n  {`r`n    `"pid`": 6,`r`n    `"tags`": [1, 2]`r`n  }`r`n]`r`n")[0].pid 6 '複数行に整形された JSON'
Assert-Throws { ConvertFrom-SessionJson '' } '空の出力は例外にする（直前の状態を消さない）'
Assert-Throws { ConvertFrom-SessionJson 'error' } 'JSON 配列でない出力は例外にする'

# ---------------------------------------------------------------------------
Write-Host '== Update-SessionState'
$script:State = @{}
$t0 = [datetime]'2026-01-01T00:00:00'

$alert = Update-SessionState -Sessions @((New-Session 1 'busy'), (New-Session 2 'idle'), (New-Session 3 'waiting' 'permission prompt')) -Now $t0
Assert-Equal $alert $true '起動時に waiting があれば通知する'
Assert-Equal $script:State['2'].Unread $false '起動時に idle のものは既読として扱う'
Assert-Equal $script:State['3'].Unread $true '起動時に waiting のものは未読'
Assert-Equal (Get-StatusLabel $script:State['3']) '許可待ち' 'permission prompt は許可待ち'
Assert-Equal (Get-StatusLabel $script:State['2']) '待機' '既読の idle は待機'
Assert-Equal (Get-StatusLabel $script:State['1']) '実行中' 'busy は実行中'

$alert = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 2 'idle'), (New-Session 3 'busy')) -Now $t0.AddSeconds(5)
Assert-Equal $alert $true 'busy から idle に変わったら通知する'
Assert-Equal (Get-StatusLabel $script:State['1']) '完了' 'busy から idle に変わったものは完了'
Assert-Equal $script:State['1'].Since $t0.AddSeconds(5) '変わった時刻を記録する'
Assert-Equal $script:State['3'].Unread $false 'busy に戻ったら既読になる'

$alert = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 2 'idle'), (New-Session 3 'busy')) -Now $t0.AddSeconds(10)
Assert-Equal $alert $false '変化がなければ通知しない'
Assert-Equal $script:State['1'].Unread $true '確認するまで完了のまま'

$alert = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 3 'waiting' 'input needed')) -Now $t0.AddSeconds(15)
Assert-Equal $alert $true 'busy から waiting に変わったら通知する'
Assert-Equal (Get-StatusLabel $script:State['3']) '質問待ち' 'input needed は質問待ち'
Assert-Equal $script:State.ContainsKey('2') $false '終了したセッションは一覧から外す'

$null = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 3 'idle')) -Now $t0.AddSeconds(20)
Assert-Equal $script:State['3'].Unread $false 'waiting から idle（手元で拒否）は未読にしない'

$null = Update-SessionState -Sessions @([pscustomobject]@{ id = 'bg1'; kind = 'background'; state = 'done' }) -Now $t0.AddSeconds(25)
Assert-Equal $script:State.Count 0 'プロセスのない background セッションは扱わない'

# PID の使い回し: startedAt が変わったら、同じ PID でも別のセッションとして扱う
$script:State = @{}
$old = New-Session 8 'busy'; $old | Add-Member startedAt 1000
$null = Update-SessionState -Sessions @($old) -Now $t0
$script:State['8'].Sdk = $true
$old.status = 'idle'
$null = Update-SessionState -Sessions @($old) -Now $t0.AddSeconds(5)
Assert-Equal $script:State['8'].Unread $true '使い回しの前: busy から idle で完了'
$reused = New-Session 8 'idle'; $reused | Add-Member startedAt 2000
$alert = Update-SessionState -Sessions @($reused) -Now $t0.AddSeconds(10)
Assert-Equal $script:State['8'].Unread $false 'PID を使い回した新しいセッションは、前の完了を引き継がない'
Assert-Equal $script:State['8'].Sdk $null 'PID を使い回した新しいセッションは、拡張機能のパネルかを判定し直す'
Assert-Equal $script:State['8'].Since $null 'PID を使い回した新しいセッションは、前の経過時間を引き継がない'
Assert-Equal $alert $false 'PID を使い回した新しいセッションが idle なら通知しない'
$same = New-Session 8 'busy'; $same | Add-Member startedAt 2000
$null = Update-SessionState -Sessions @($same) -Now $t0.AddSeconds(15)
Assert-Equal $script:State['8'].Since $t0.AddSeconds(15) 'startedAt が同じなら同じセッションとして状態の変化を記録する'
$noStart = New-Session 8 'idle'
$null = Update-SessionState -Sessions @($noStart) -Now $t0.AddSeconds(20)
Assert-Equal $script:State['8'].Unread $true 'startedAt がなければ PID だけで見分ける（busy から idle で完了）'

Assert-Equal (Get-Rank ([pscustomobject]@{ Status = 'waiting'; Unread = $false })) 0 '並び順: 待ちが先頭'
Assert-Equal (Get-Rank ([pscustomobject]@{ Status = 'idle'; Unread = $true })) 1 '並び順: 完了が次'
Assert-Equal (Get-Rank ([pscustomobject]@{ Status = 'busy'; Unread = $false })) 2 '並び順: 実行中'
Assert-Equal (Get-Rank ([pscustomobject]@{ Status = 'idle'; Unread = $false })) 3 '並び順: 待機が最後'
Assert-Equal (Get-StatusLabel ([pscustomobject]@{ Status = 'waiting'; WaitingFor = 'sandbox request' })) '待ち（sandbox request）' '未知の waitingFor はそのまま表示する'

# ---------------------------------------------------------------------------
Write-Host '== Get-AlertLevel / Get-AlertNotice'
$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 1 'busy'), (New-Session 2 'idle')) -Now $t0
Assert-Equal $script:State['1'].AlertAt $null '通知していないものは AlertAt が空'
Assert-Equal (Get-AlertLevel @($script:State.Values)) 'none' '待ちも完了もなければ none'
Assert-Equal (Get-AlertLevel @()) 'none' 'セッションがなければ none'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t0) $null '新しい待ちも完了もなければ通知しない'

$t1 = $t0.AddSeconds(5)
$null = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 2 'idle')) -Now $t1
Assert-Equal $script:State['1'].AlertAt $t1 '完了した時刻を記録する'
Assert-Equal (Get-AlertLevel @($script:State.Values)) 'done' '完了だけなら done'
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t1
Assert-Equal $notice.Title 'Claude Code が完了しました' '完了だけのときの題'
Assert-Equal $notice.Text '完了: s1' '本文は状態とセッション名'
Assert-Equal $notice.Key '1' '通知のクリックで開くセッション'

$t2 = $t0.AddSeconds(10)
$null = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 2 'busy'), (New-Session 3 'waiting' 'permission prompt')) -Now $t2
Assert-Equal (Get-AlertLevel @($script:State.Values)) 'waiting' '待ちがあれば、完了があっても waiting'
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t2
Assert-Equal $notice.Title 'Claude Code が待っています' '待ちがあるときの題'
Assert-Equal $notice.Text '許可待ち: s3' '前の回に通知したもの（s1 の完了）は含めない'

$t3 = $t0.AddSeconds(15)
$null = Update-SessionState -Sessions @((New-Session 1 'idle'), (New-Session 2 'idle'), (New-Session 3 'waiting' 'permission prompt'),
    (New-Session 4 'waiting' 'input needed'), (New-Session 5 'waiting'), (New-Session 6 'waiting')) -Now $t3
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t3
Assert-Equal $notice.Text "質問待ち: s4`n待ち: s5`n待ち: s6`nほか 1 件" '待ちを先に 3 件まで並べ、残りは件数にする'
Assert-Equal $notice.Key '4' '先頭の待ちを開く'
$script:State['2'].Unread = $false
Assert-Equal (Get-AlertNotice -Entries @($script:State['2']) -Now $t3) $null '既読にした完了は通知しない'

$noName = [pscustomobject]@{ Key = '9'; Status = 'waiting'; Unread = $true; Name = ''; Cwd = 'C:\work\proj'; WaitingFor = ''; AlertAt = $t3 }
Assert-Equal (Get-AlertNotice -Entries @($noName) -Now $t3).Text '待ち: proj' 'セッション名がなければフォルダ名'
$noName.Name = 'x' * 300
Assert-Equal (Get-AlertNotice -Entries @($noName) -Now $t3).Text.Length 250 '長い本文は通知に収まるよう切り詰める'

# ---------------------------------------------------------------------------
Write-Host '== 点滅を止める（Get-VSCodeRootName / Test-VSCodeWindowTitle / Get-PendingFlashKeys）'
Assert-Equal (Get-VSCodeRootName 'C:\work\proj\proj.code-workspace') 'proj' 'workspace はファイル名から拡張子を除いたもの'
Assert-Equal (Get-VSCodeRootName 'C:\work\proj') 'proj' 'フォルダはフォルダ名'
Assert-Equal (Get-VSCodeRootName 'C:\work\proj\') 'proj' '末尾の区切りを無視する'
Assert-Equal (Get-VSCodeRootName '') $null '開くものがなければ $null'

Assert-True (Test-VSCodeWindowTitle 'andon.ps1 - proj - Visual Studio Code' 'proj') '既定の題名（ファイル - フォルダ - アプリ）'
Assert-True (Test-VSCodeWindowTitle 'proj - Visual Studio Code' 'proj') 'エディタを開いていない題名'
Assert-True (Test-VSCodeWindowTitle 'andon.ps1 - proj (Workspace) - Visual Studio Code' 'proj') 'workspace の題名'
Assert-True (Test-VSCodeWindowTitle 'andon.ps1 - proj (ワークスペース) - Visual Studio Code' 'proj') '日本語の workspace の題名'
Assert-True (Test-VSCodeWindowTitle '● andon.ps1 - PROJ - Visual Studio Code' 'proj') '保存していない印と大文字小文字を無視する'
Assert-True (Test-VSCodeWindowTitle 'a.ps1 - proj - Work - Visual Studio Code' 'proj') 'プロファイル名が入った題名'
Assert-Equal (Test-VSCodeWindowTitle 'proj - other - Visual Studio Code' 'proj') $false '先頭（開いているファイル名）は見ない'
Assert-Equal (Test-VSCodeWindowTitle 'a.ps1 - project2 - Visual Studio Code' 'proj') $false '名前の前半が同じだけの別のフォルダは数えない'
Assert-Equal (Test-VSCodeWindowTitle '' 'proj') $false '前面が VS Code でなければ（題名が空なら）数えない'
Assert-Equal (Test-VSCodeWindowTitle 'proj - Visual Studio Code' $null) $false '名前が分からなければ数えない'

$flashState = @{
    '1' = [pscustomobject]@{ Key = '1'; Status = 'waiting'; Unread = $true }
    '2' = [pscustomobject]@{ Key = '2'; Status = 'idle'; Unread = $true }
    '3' = [pscustomobject]@{ Key = '3'; Status = 'busy'; Unread = $false }
}
$flashKeys = @{ '1' = 'p1'; '2' = 'p2'; '3' = 'p3'; '4' = 'p4' }
$kept = Get-PendingFlashKeys -FlashKeys $flashKeys -State $flashState -ForegroundTitle $null
Assert-Equal ((@($kept.Keys) | Sort-Object) -join ',') '1,2' '待ちと完了は残し、実行中に戻ったものと終わったものは外す'
$kept = Get-PendingFlashKeys -FlashKeys $flashKeys -State $flashState -ForegroundTitle 'a.ps1 - p1 - Visual Studio Code'
Assert-Equal ((@($kept.Keys) | Sort-Object) -join ',') '2' '前面の VS Code のウィンドウで開いているものは外す'
Assert-Equal $kept['2'] 'p2' '残したものは名前を保つ'
$flashState['2'].Unread = $false
$kept = Get-PendingFlashKeys -FlashKeys $kept -State $flashState -ForegroundTitle $null
Assert-Equal $kept.Count 0 '既読にした完了も外す（残りがなければ点滅を止める）'

# ---------------------------------------------------------------------------
Write-Host '== 拡張機能のパネルのセッション（Test-SdkCommandLine / Test-SessionVisible / Get-ProcessCommandLine）'
$panel = 'C:\ext\anthropic.claude-code-2.1.0-win32-x64\resources\native-binary\claude.exe --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio'
Assert-True (Test-SdkCommandLine $panel) '拡張機能のパネルの起動引数は SDK'
Assert-True (Test-SdkCommandLine 'claude.exe --input-format=stream-json') '= で区切った形も SDK'
Assert-Equal (Test-SdkCommandLine '"C:\tools\claude.exe"') $false 'ターミナルの claude は SDK ではない'
Assert-Equal (Test-SdkCommandLine 'claude.exe --input-format text') $false '--input-format が stream-json でなければ SDK ではない'
Assert-Equal (Test-SdkCommandLine '') $false '起動引数が取れなければ SDK ではない（一覧に出す）'

$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 7 'idle')) -Now $t0
Assert-Equal $script:State['7'].Sdk $null '新しいセッションは未判定'

Assert-Equal (Test-SessionVisible ([pscustomobject]@{ Status = 'idle'; Unread = $false; Sdk = $true })) $false 'SDK の待機中は出さない'
Assert-True (Test-SessionVisible ([pscustomobject]@{ Status = 'busy'; Unread = $false; Sdk = $true })) 'SDK でも実行中は出す'
Assert-True (Test-SessionVisible ([pscustomobject]@{ Status = 'waiting'; Unread = $true; Sdk = $true })) 'SDK でも待ちは出す'
Assert-True (Test-SessionVisible ([pscustomobject]@{ Status = 'idle'; Unread = $true; Sdk = $true })) 'SDK でも完了は出す'
Assert-True (Test-SessionVisible ([pscustomobject]@{ Status = 'idle'; Unread = $false; Sdk = $false })) 'ターミナルの待機中は出す'
Assert-True (Test-SessionVisible ([pscustomobject]@{ Status = 'idle'; Unread = $false; Sdk = $null })) '未判定の待機中は出す'

# PowerShell のコメント（#）の後ろに置いて、起動引数にだけ現れるようにする
$psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', '-NoProfile -Command "Start-Sleep -Seconds 30 # --input-format stream-json"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$sdkProc = [Diagnostics.Process]::Start($psi)
try {
    $line = Get-ProcessCommandLine -Id $sdkProc.Id
    Assert-True ($line -match 'Start-Sleep') 'プロセスの起動引数を取れる'
    Assert-True (Test-SdkCommandLine $line) '起動引数から SDK のセッションと判定できる'
}
finally {
    try { $sdkProc.Kill() } catch { }
    $sdkProc.Dispose()
}
Assert-Equal (Get-ProcessCommandLine -Id 2147483646) $null '存在しないプロセスは $null'

# ---------------------------------------------------------------------------
Write-Host '== Test-DedicatedProcess'
$ps51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-True (Test-DedicatedProcess -Arguments @($ps51, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', 'C:\work\andon\andon.ps1') -ScriptName 'andon.ps1') 'README の起動方法（-File で andon.ps1）は andon 専用'
Assert-True (Test-DedicatedProcess -Arguments @('pwsh', '.\andon.ps1', '-ScanMs', '500') -ScriptName 'andon.ps1') 'pwsh に相対パスで渡したものも andon 専用'
Assert-True (Test-DedicatedProcess -Arguments @($ps51, '-Command', "& 'C:\work\andon\andon.ps1'") -ScriptName 'andon.ps1') '-Command で呼んだものも andon 専用'
Assert-True (Test-DedicatedProcess -Arguments @($ps51, '-File', 'C:\work\andon\ANDON.PS1') -ScriptName 'andon.ps1') '大文字小文字を区別しない'
Assert-Equal (Test-DedicatedProcess -Arguments @($ps51) -ScriptName 'andon.ps1') $false '対話で使っているシェル（起動引数に andon.ps1 がない）は andon 専用ではない'
Assert-Equal (Test-DedicatedProcess -Arguments @('C:\Program Files\PowerShell\7\pwsh.dll', '-NoLogo') -ScriptName 'andon.ps1') $false 'pwsh の対話のシェルも andon 専用ではない'
Assert-Equal (Test-DedicatedProcess -Arguments @($ps51, '-File', 'C:\work\not-andon.ps1') -ScriptName 'andon.ps1') $false '名前の一部が同じだけの別のスクリプトは数えない'
Assert-Equal (Test-DedicatedProcess -Arguments @($ps51, '-File', 'C:\work\andon\andon.ps1') -ScriptName '') $false 'スクリプトの名前が分からなければ andon 専用と見なさない'

# ---------------------------------------------------------------------------
Write-Host '== Register-AppUserModelId'
# 本物の登録先（HKCU\Software\Classes\AppUserModelId）は使わず、テスト用のキーに書いて消す
$regRoot = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
try {
    Assert-True (Register-AppUserModelId -Id 'example.andon' -DisplayName 'andon' -Root $regRoot) '表示名を登録できたら $true'
    Assert-Equal (Get-ItemProperty -LiteralPath (Join-Path $regRoot 'example.andon')).DisplayName 'andon' '表示名を書く'
    Assert-True (Register-AppUserModelId -Id 'example.andon' -DisplayName 'andon 2' -Root $regRoot) '登録済みでも書き直せる'
    Assert-Equal (Get-ItemProperty -LiteralPath (Join-Path $regRoot 'example.andon')).DisplayName 'andon 2' '書き直した表示名'
}
finally {
    if (Test-Path -LiteralPath $regRoot) { Remove-Item -LiteralPath $regRoot -Recurse -Force }
}
Assert-Equal (Test-Path -LiteralPath $regRoot) $false 'テスト用のキーを消した'
Assert-Equal (Register-AppUserModelId -Id 'example.andon' -DisplayName 'andon' -Root 'NoSuchDrive:\x') $false '書けなければ $false（ID を andon に戻す）'

# ---------------------------------------------------------------------------
Write-Host '== 版'
Assert-True ($script:AndonVersion -match '^\d+\.\d+\.\d+$') '版は MAJOR.MINOR.PATCH'
Assert-Equal (Get-AndonVersion -Path (Join-Path $root 'andon.ps1')) $script:AndonVersion 'install.ps1 は andon.ps1 から版を読める'
Assert-Equal (Get-AndonVersion -Path (Join-Path $root 'no-such-file.ps1')) $null '読めなければ $null'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: 実行ポリシー'
Assert-True (Test-ExecutionPolicyAllowed -MachinePolicy 'Undefined' -UserPolicy 'Undefined') 'グループ ポリシーがなければ起動できる（-ExecutionPolicy Bypass が効く）'
Assert-True (Test-ExecutionPolicyAllowed -MachinePolicy 'RemoteSigned' -UserPolicy 'Undefined') 'RemoteSigned なら、印を外したファイルは動く'
Assert-Equal (Test-ExecutionPolicyAllowed -MachinePolicy 'AllSigned' -UserPolicy 'Undefined') $false 'AllSigned では署名のない andon は動かない'
Assert-Equal (Test-ExecutionPolicyAllowed -MachinePolicy 'Undefined' -UserPolicy 'Restricted') $false 'ユーザーのポリシーの Restricted でも動かない'
Assert-True (Test-ExecutionPolicyAllowed -MachinePolicy 'Bypass' -UserPolicy 'AllSigned') 'コンピューターのポリシーがユーザーのポリシーより優先する'
Assert-True (Test-ExecutionPolicyAllowed -MachinePolicy '' -UserPolicy '') '調べられなければ起動できるものとして進める'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: 起動のしかた'
$launch = Get-AndonLaunch -InstallDir 'C:\Apps\andon' -SystemRoot 'C:\Windows'
Assert-Equal $launch.FilePath 'C:\Windows\System32\conhost.exe' 'conhost.exe でウィンドウなしに起動する'
Assert-Equal $launch.Arguments '--headless "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "C:\Apps\andon\andon.ps1"' 'Windows PowerShell 5.1 の -File に andon.ps1 を渡す'
$launchArgs = @([regex]::Matches($launch.Arguments, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
Assert-True (Test-DedicatedProcess -Arguments $launchArgs[1..($launchArgs.Count - 1)] -ScriptName 'andon.ps1') 'この起動のしかたは andon 専用と判定される（アプリ ID を付ける）'
Assert-True (Test-AndonCommandLine -CommandLine ($launchArgs[1..($launchArgs.Count - 1)] -join ' ')) 'この起動のしかたは、古い版を止めるときにも andon と判定される'
Assert-True ((Get-AndonLaunch -InstallDir 'C:\Apps\andon' -ExtraArguments '-ScanMs 500' -SystemRoot 'C:\Windows').Arguments.EndsWith('andon.ps1" -ScanMs 500')) 'andon.ps1 の後ろに引数を付けられる'

Assert-Equal (Get-ExtraArguments -Arguments $launch.Arguments) '' '引数を付けていなければ空'
Assert-Equal (Get-ExtraArguments -Arguments ($launch.Arguments + ' -ScanMs 500 -FallbackSec 60')) '-ScanMs 500 -FallbackSec 60' 'andon.ps1 の後ろの引数を引き継ぐ'
Assert-Equal (Get-ExtraArguments -Arguments '--headless powershell.exe -File C:\work\andon\andon.ps1 -ScanMs 500') '-ScanMs 500' '引用符のないパスでも引き継ぐ'
Assert-Equal (Get-ExtraArguments -Arguments $null) '' 'ショートカットがなければ空'

Assert-True (Test-AndonCommandLine -CommandLine 'powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\andon\andon.ps1') 'README の起動方法（相対パス）は andon'
Assert-True (Test-AndonCommandLine -CommandLine 'pwsh -File andon.ps1 -ScanMs 500') 'フォルダのない andon.ps1 も andon'
Assert-True (Test-AndonCommandLine -CommandLine '"C:\Program Files\PowerShell\7\pwsh.exe" -file "C:\My Apps\andon\ANDON.PS1"') '空白を含むパスと大文字小文字'
Assert-Equal (Test-AndonCommandLine -CommandLine 'powershell.exe -File C:\work\andon\tests\Test-Andon.ps1') $false 'テストのスクリプトは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine 'pwsh -Command "Get-Content .\andon.ps1"') $false 'andon.ps1 を読むだけのコマンドは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine 'powershell.exe -File C:\work\other.ps1 C:\work\andon\andon.ps1') $false 'andon.ps1 を引数に渡しただけのものは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine '') $false '起動引数が取れなければ andon ではない'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: スタートアップ'
Assert-Equal (Get-StartupAction -NoStartup $false -IsUpdate $false -Exists $false) 'create' '初めて入れるときは作る'
Assert-Equal (Get-StartupAction -NoStartup $false -IsUpdate $true -Exists $true) 'create' '更新のときに、あれば書き直す'
Assert-Equal (Get-StartupAction -NoStartup $false -IsUpdate $true -Exists $false) 'none' '更新のときに、なければ（消した人のために）作らない'
Assert-Equal (Get-StartupAction -NoStartup $true -IsUpdate $false -Exists $false) 'none' '-NoStartup なら作らない'
Assert-Equal (Get-StartupAction -NoStartup $true -IsUpdate $true -Exists $true) 'remove' '-NoStartup なら、あれば消す'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: 動いている andon を終わらせる'
# 本物の andon（Local\andon）には触れないよう、テスト用の名前を使う
$suffix = [guid]::NewGuid().ToString('N')
$mutexName = "Local\andon-test-$suffix"
$eventName = "Local\andon-test-exit-$suffix"
Assert-Equal (Test-AndonRunning -MutexName $mutexName) $false '動いていなければ $false'
Assert-Equal (Send-AndonExit -EventName $eventName) $false '合図を受ける andon がなければ $false'
Assert-True (Wait-AndonExit -MutexName $mutexName -TimeoutSec 1) '動いていなければ、待たずに $true'
# andon の代わりに、別のスレッドで合図を待ち、mutex を持つ。合図を受けたら mutex を放す
$fake = [powershell]::Create()
[void]$fake.AddScript({
        param($MutexName, $EventName)
        $exit = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)
        $mutex = New-Object System.Threading.Mutex($true, $MutexName)
        try { [void]$exit.WaitOne(10000) }
        finally { $mutex.ReleaseMutex(); $mutex.Dispose(); $exit.Dispose() }
    }).AddArgument($mutexName).AddArgument($eventName)
$fakeRun = $fake.BeginInvoke()
try {
    $deadline = (Get-Date).AddSeconds(5)
    while (-not (Test-AndonRunning -MutexName $mutexName) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-AndonRunning -MutexName $mutexName) '動いていれば $true'
    Assert-Equal (Wait-AndonExit -MutexName $mutexName -TimeoutSec 1) $false '合図を送らなければ、時間内に終わらない'
    Assert-True (Send-AndonExit -EventName $eventName) '合図を送れる'
    Assert-True (Wait-AndonExit -MutexName $mutexName -TimeoutSec 5) '合図を受けた andon が終わるのを待てる'
}
finally {
    [void]$fake.EndInvoke($fakeRun)
    $fake.Dispose()
}
Assert-Equal (Test-AndonRunning -MutexName $mutexName) $false '調べるために開いた mutex を残さない（残すと、次の andon が二重起動と判断する）'
$andonText = Get-Content -LiteralPath (Join-Path $root 'andon.ps1') -Raw -Encoding UTF8
Assert-True ($andonText.Contains("'Local\andon'")) 'andon.ps1 は、install.ps1 が見る mutex（Local\andon）を使う'
Assert-True ($andonText.Contains("'Local\andon-exit'")) 'andon.ps1 は、install.ps1 が送る合図（Local\andon-exit）を受ける'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: レジストリ'
# 本物のキーは使わず、テスト用のキーに作って消す
$regBase = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
try {
    $classes = Join-Path $regBase 'AppUserModelId'
    $notifications = Join-Path $regBase 'Notifications'
    foreach ($k in @((Join-Path $classes 'tbshiki.andon'), (Join-Path $notifications 'tbshiki.andon'), (Join-Path $notifications 'andon'), (Join-Path $notifications 'example.other'))) {
        New-Item -Path $k -Force | Out-Null
    }
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications).Count 3 'アプリ ID の表示名と、2 つの ID の通知の設定を消す'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $notifications 'example.other')) $true 'ほかのアプリの通知の設定は消さない'
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications).Count 0 'なければ何もしない'
}
finally {
    if (Test-Path -LiteralPath $regBase) { Remove-Item -LiteralPath $regBase -Recurse -Force }
}

# ---------------------------------------------------------------------------
$installTmp = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('andon-install-' + [guid]::NewGuid().ToString('N'))))
try {
    Write-Host '== install.ps1: ファイルを置く'
    $src = Join-Path $installTmp 'src'
    $dst = Join-Path $installTmp 'dst'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    foreach ($n in @('andon.ps1', 'install.ps1', 'LICENSE', 'notes.txt')) { Set-Content -LiteralPath (Join-Path $src $n) -Value "v1 $n" -Encoding UTF8 }
    # ブラウザで落としてエクスプローラーで展開したときと同じく、ダウンロードした印を付ける
    Set-Content -LiteralPath (Join-Path $src 'andon.ps1') -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    Assert-Equal @(Copy-AndonFiles -SourceDir $src -InstallDir $dst).Count 3 '配るファイルを 3 つ置く'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $dst 'notes.txt')) $false '配るファイルでないものは置かない'
    Assert-Equal @(Get-Item -LiteralPath (Join-Path $dst 'andon.ps1') -Stream * | Where-Object { $_.Stream -eq 'Zone.Identifier' }).Count 0 'ダウンロードした印を外す'
    Set-Content -LiteralPath (Join-Path $src 'andon.ps1') -Value 'v2' -Encoding UTF8
    [void](Copy-AndonFiles -SourceDir $src -InstallDir $dst)
    Assert-Equal (Get-Content -LiteralPath (Join-Path $dst 'andon.ps1') -Raw -Encoding UTF8).Trim() 'v2' 'もう一度入れると新しいファイルに置き換える'
    Assert-Equal @(Get-ChildItem -LiteralPath $dst -Filter '*.new').Count 0 '一時ファイルを残さない'
    Assert-Equal @(Copy-AndonFiles -SourceDir $dst -InstallDir $dst).Count 3 '入れた場所の install.ps1 から実行しても失敗しない'
    Remove-Item -LiteralPath (Join-Path $src 'andon.ps1')
    Assert-Throws { Copy-AndonFiles -SourceDir $src -InstallDir $dst } 'andon.ps1 がなければ例外にする'

    Write-Host '== install.ps1: ショートカット'
    $lnk = Join-Path $installTmp 'links\andon.lnk'
    $dstLaunch = Get-AndonLaunch -InstallDir $dst
    New-AndonShortcut -Path $lnk -Launch $dstLaunch
    Assert-Equal (Get-ShortcutArguments -Path $lnk) $dstLaunch.Arguments 'ショートカットに起動の引数を書く'
    $wsh = New-Object -ComObject WScript.Shell
    try { Assert-PathEqual $wsh.CreateShortcut($lnk).TargetPath $dstLaunch.FilePath 'ショートカットのリンク先は conhost.exe' }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
    Assert-True (Test-AndonShortcut -Path $lnk) 'andon を起動するショートカットと判定する'
    Assert-True (Remove-AndonShortcut -Path $lnk) 'andon を起動するショートカットを消す'
    Assert-Equal (Test-Path -LiteralPath $lnk) $false '消した'
    Assert-Equal (Remove-AndonShortcut -Path $lnk) $false 'ないショートカットは消さない'
    Assert-Equal (Get-ShortcutArguments -Path $lnk) $null 'ないショートカットの引数は $null'
    $other = Join-Path $installTmp 'links\other.lnk'
    New-AndonShortcut -Path $other -Launch ([pscustomobject]@{
            FilePath = $dstLaunch.FilePath; Arguments = '-File C:\work\Test-Andon.ps1'; WorkingDirectory = $installTmp; PowerShell = $dstLaunch.PowerShell
        })
    Assert-Equal (Remove-AndonShortcut -Path $other) $false '別のスクリプトを起動するショートカットは消さない'
}
finally {
    if (Test-Path -LiteralPath $installTmp) { Remove-Item -LiteralPath $installTmp -Recurse -Force }
}

# ---------------------------------------------------------------------------
Write-Host '== Format-Elapsed'
Assert-Equal (Format-Elapsed ([TimeSpan]::FromSeconds(42))) '42秒' '1 分未満'
Assert-Equal (Format-Elapsed ([TimeSpan]::FromSeconds(125))) '2分' '1 時間未満'
Assert-Equal (Format-Elapsed ([TimeSpan]::FromSeconds(3725))) '1時間2分' '1 時間以上'

# ---------------------------------------------------------------------------
Write-Host '== Test-PathUnder'
Assert-Equal (Test-PathUnder -Path 'C:\a\app' -Root 'C:\a\app') $true '同じパス'
Assert-Equal (Test-PathUnder -Path 'C:\a\app\src' -Root 'C:\a\app') $true '配下のパス'
Assert-Equal (Test-PathUnder -Path 'C:\A\App' -Root 'c:\a\app\') $true '大文字小文字と末尾の区切りを無視する'
Assert-Equal (Test-PathUnder -Path 'C:\a\app-extra' -Root 'C:\a\app') $false '名前が前方一致するだけの別フォルダは含めない'

# ---------------------------------------------------------------------------
$tmp = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('andon-test-' + [guid]::NewGuid().ToString('N'))))
try {
    Write-Host '== Get-SessionSignature'
    $sessions = Join-Path $tmp 'sessions'
    New-Item -ItemType Directory -Path $sessions -Force | Out-Null
    $jsonFile = Join-Path $sessions '100.json'
    [IO.File]::WriteAllText($jsonFile, '{}')
    [IO.File]::WriteAllText((Join-Path $sessions '100.0123abcd.key'), 'x')
    $sig1 = Get-SessionSignature -Path $sessions
    Assert-True ($sig1 -like '100.json:*') '*.json の名前と更新時刻を使う'
    Assert-True ($sig1 -notmatch '\.key') '*.key は対象にしない'
    [IO.File]::SetLastWriteTimeUtc($jsonFile, [datetime]::UtcNow.AddMinutes(1))
    Assert-True ((Get-SessionSignature -Path $sessions) -ne $sig1) '更新時刻が変わると署名も変わる'
    Assert-Equal (Get-SessionSignature -Path (Join-Path $tmp 'missing')) '' 'ディレクトリがなければ空'

    Write-Host '== Resolve-VSCodeTarget'
    $ws = Join-Path $tmp 'ws'
    foreach ($d in 'repo-a\.git', 'repo-a\sub\deep', 'repo-a\.claude\worktrees\feature', 'repo-b\.git', 'repo-b\src',
        'repo-b2\.git', 'repo-c\.git', 'repo-c\sub', 'repo-c\a\b\c\d\e', 'repo d\.git', 'repo-f\.git', 'repo-g\.git') {
        New-Item -ItemType Directory -Path (Join-Path $ws $d) -Force | Out-Null
    }
    $absF = (Join-Path $ws 'repo-f') -replace '\\', '/'
    $wsA = Join-Path $ws 'repo-a\repo-a.code-workspace'
    $wsText = @"
{
	// multi-root（JSONC: コメントと末尾のカンマ）
	"folders": [
		{ "path": "." },
		{ "path": "../repo-b" },
		// { "path": "../repo-c" },
		/* { "path": "../repo-c" }, */
		{ "path": "$absF" },
		{ "path": "..\\repo-g" }, // 末尾のカンマの後のコメント
		/* { "path": "../repo-c" } */
	],
	"settings": {
		"example.url": "https://example.invalid/*keep*/",
		"example.nested": { "path": "../repo-c" },
	}
}
"@
    [IO.File]::WriteAllText($wsA, $wsText)
    Assert-Equal @(Get-WorkspaceFolders -Path $wsA).Count 4 'コメントと settings の中の path は folders として数えない'
    Assert-Equal (ConvertFrom-Jsonc $wsText).settings.'example.url' 'https://example.invalid/*keep*/' '文字列の中の // や /* */ は消さない'
    $wsBroken = Join-Path $tmp 'broken.code-workspace'
    [IO.File]::WriteAllText($wsBroken, '{ "folders": [ { "path": ')
    Assert-Equal @(Get-WorkspaceFolders -Path $wsBroken).Count 0 '読めない workspace は空として扱う'
    $wsD = Join-Path $ws 'repo d\d.code-workspace'
    [IO.File]::WriteAllText($wsD, '{ "folders": [ { "path": "." } ] }')

    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-a')) $wsA 'フォルダ直下の workspace'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-a\sub\deep')) $wsA 'サブフォルダから遡って見つける'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-a\.claude\worktrees\feature')) $wsA 'Claude の worktree は元の repository として扱う'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-b')) $wsA '隣の workspace の folders（相対パス）に含まれる'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-b\src')) $wsA 'folders に含まれるフォルダの配下'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-f')) $wsA 'folders の絶対パス（/ 区切り）'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-g')) $wsA 'folders のエスケープされた \'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-b2')) (Join-Path $ws 'repo-b2') '前方一致するだけの別フォルダは、そのフォルダを開く'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-c')) (Join-Path $ws 'repo-c') 'workspace がなければフォルダを開く（コメントの中の folders は使わない）'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo d')) $wsD '空白を含むパス'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-c\sub')) (Join-Path $ws 'repo-c') 'workspace がなければ、サブフォルダではなく repository の root を開く'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-c\a\b\c\d\e')) (Join-Path $ws 'repo-c') '深い階層からも repository の root まで遡る'

    # 親フォルダの workspace、最も近いフォルダの優先、repository より広いフォルダの除外
    $ws2 = Join-Path $tmp 'ws2'
    foreach ($d in 'repo-p\.git', 'repo-q\.git', 'repo-q\src', 'repo-r\.git', 'tool\.git', 'aaa\.git') {
        New-Item -ItemType Directory -Path (Join-Path $ws2 $d) -Force | Out-Null
    }
    $wsAll = Join-Path $ws2 'all.code-workspace'
    [IO.File]::WriteAllText($wsAll, '{ "folders": [ { "path": "repo-p" }, { "path": "repo-q" } ] }')
    $wsTool = Join-Path $ws2 'tool\q.code-workspace'
    [IO.File]::WriteAllText($wsTool, '{ "folders": [ { "path": "." }, { "path": "../repo-q/src" } ] }')
    [IO.File]::WriteAllText((Join-Path $ws2 'aaa\broad.code-workspace'), '{ "folders": [ { "path": ".." } ] }')

    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws2 'repo-p')) $wsAll '親フォルダにある multi-root の workspace'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws2 'repo-q')) $wsAll 'repository を挙げている workspace'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws2 'repo-q\src')) $wsTool '作業フォルダに最も近いフォルダを挙げている workspace を優先する'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws2 'repo-r')) (Join-Path $ws2 'repo-r') '親フォルダ全体（..）を挙げているだけの workspace は使わない'

    # git の外では、上の階層にある workspace（ダウンロードした物など）を使わない
    $outside = Join-Path $tmp 'dl\proj'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'dl\downloaded.code-workspace'), '{ "folders": [ { "path": "." } ] }')
    $tmpInRepo = $false
    for ($d = $tmp; $d; $d = Split-Path -Parent $d) {
        if (Test-Path -LiteralPath (Join-Path $d '.git')) { $tmpInRepo = $true; break }
    }
    if ($tmpInRepo) {
        Write-Host '[SKIP] 一時フォルダが git の repository の中にあるので、git の外の場合を確かめられない'
    }
    else {
        Assert-PathEqual (Resolve-VSCodeTarget -Cwd $outside) $outside 'git の外では上の階層の workspace を使わない'
    }

    Write-Host '== Find-CodeExe'
    $vsc = Join-Path $tmp 'vsc'
    New-Item -ItemType Directory -Path (Join-Path $vsc 'bin') -Force | Out-Null
    $fakeCmd = Join-Path $vsc 'bin\code.cmd'
    [IO.File]::WriteAllText($fakeCmd, '@echo off')
    Assert-Equal (Find-CodeExe -CodeCmd $fakeCmd) $null 'Code.exe がなければ $null（code.cmd を使う）'
    [IO.File]::WriteAllText((Join-Path $vsc 'Code.exe'), '')
    Assert-PathEqual (Find-CodeExe -CodeCmd $fakeCmd) (Join-Path $vsc 'Code.exe') 'bin\code.cmd の隣の Code.exe'

    Write-Host '== ConvertTo-ArgumentString'
    Assert-Equal (ConvertTo-ArgumentString 'C:\a b') '"C:\a b"' '空白を含むパスを引用する'
    Assert-Equal (ConvertTo-ArgumentString 'C:\') '"C:\\"' '閉じる " の直前の \ を重ねる'
    # 実際にプロセスへ渡し、受け取った引数が元のパスと一致するか（cmd.exe を通さないので %VAR% も展開されない）
    $dump = Join-Path $tmp 'dump-args.ps1'
    $dumpOut = Join-Path $tmp 'args.txt'
    [IO.File]::WriteAllText($dump, '[IO.File]::WriteAllLines($args[0], [string[]]$args[1..($args.Count - 1)], (New-Object Text.UTF8Encoding($true)))', (New-Object Text.UTF8Encoding($true)))
    $values = @('C:\', 'C:\a b\', 'C:\x\v%USERNAME%v', 'C:\x\a&b', 'C:\x\日本語 フォルダ', '\\server\share\')
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + ((@($dump, $dumpOut) + $values | ForEach-Object { ConvertTo-ArgumentString $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    $p.Dispose()
    $got = @([IO.File]::ReadAllLines($dumpOut))
    Assert-Equal $got.Count $values.Count '引数の数が変わらない'
    for ($i = 0; $i -lt $values.Count; $i++) {
        Assert-Equal $got[$i] $values[$i] "引数がそのまま渡る: $($values[$i])"
    }

    Write-Host '== Stop-ProcessTree'
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe', '/c powershell.exe -NoProfile -Command Start-Sleep -Seconds 60'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $parentProc = [Diagnostics.Process]::Start($psi)
    $child = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $child -and (Get-Date) -lt $deadline) {
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parentProc.Id) AND Name='powershell.exe'" | Select-Object -First 1
        if (-not $child) { Start-Sleep -Milliseconds 200 }
    }
    Assert-True $child '子プロセスが起動した'
    Stop-ProcessTree -Id $parentProc.Id
    Assert-True ($parentProc.WaitForExit(5000)) '親プロセスを止める'
    if ($child) {
        $childGone = $false
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $childGone -and (Get-Date) -lt $deadline) {
            $childGone = -not (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue)
            if (-not $childGone) { Start-Sleep -Milliseconds 200 }
        }
        Assert-True $childGone '子孫のプロセスも止める'
    }
    $parentProc.Dispose()
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

# ---------------------------------------------------------------------------
Write-Host '== .claude/hooks/auto-allow-git-tracked-edit.ps1'
$inWorkTree = $false
try {
    $null = & git -C $root rev-parse --is-inside-work-tree 2>$null
    $inWorkTree = ($LASTEXITCODE -eq 0)
}
catch { }
if (-not $inWorkTree) {
    Write-Host '[SKIP] git の作業ツリーではないので確かめられない'
}
else {
    $hook = Join-Path $root '.claude\hooks\auto-allow-git-tracked-edit.ps1'
    $hookTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-hook-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $hookTmp -Force | Out-Null
    $savedProjectDir = $env:CLAUDE_PROJECT_DIR
    function Invoke-EditHook {
        <# Claude Code と同じく、UTF-8（BOM なし）の JSON を標準入力で渡して、hook の出力を返す #>
        param([string]$Path)
        # Windows PowerShell 5.1 の Process.StandardInput は先頭に BOM を書くので、ファイルから渡す
        $in = Join-Path $hookTmp 'in.json'
        $out = Join-Path $hookTmp 'out.txt'
        $json = '{"tool_name":"Edit","tool_input":{"file_path":' + (ConvertTo-Json $Path) + '}}'
        [IO.File]::WriteAllText($in, $json, (New-Object Text.UTF8Encoding($false)))
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $hook) `
            -RedirectStandardInput $in -RedirectStandardOutput $out -NoNewWindow -Wait
        return ([IO.File]::ReadAllText($out)).Trim()
    }
    try {
        $env:CLAUDE_PROJECT_DIR = $root
        Assert-True ((Invoke-EditHook (Join-Path $root 'andon.ps1')) -match '"permissionDecision":"allow"') '追跡済みのファイルは自動許可する'
        Assert-Equal (Invoke-EditHook (Join-Path $root '.claude\settings.json')) '' '.claude の下は追跡済みでも自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $root '.claude\hooks\auto-allow-git-tracked-edit.ps1')) '' 'hook 自身を自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $root '.github\workflows\test.yml')) '' '.github の下は追跡済みでも自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $root 'AGENTS.md')) '' 'AI への決まりを書いた AGENTS.md は自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $root 'CLAUDE.md')) '' 'AI への決まりを書いた CLAUDE.md は自動許可しない'
        Assert-True ((Invoke-EditHook (Join-Path $root 'README.md')) -match '"permissionDecision":"allow"') 'ほかの追跡済みの文書は自動許可する'
        Assert-Equal (Invoke-EditHook (Join-Path $root '[a]ndon.ps1')) '' 'パスの [ ] をワイルドカードとして扱わない'
        Assert-Equal (Invoke-EditHook (Join-Path $root 'untracked-new-file.ps1')) '' '未追跡のファイルは自動許可しない'
    }
    finally {
        $env:CLAUDE_PROJECT_DIR = $savedProjectDir
        Remove-Item -LiteralPath $hookTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
Write-Host '== .claude/hooks/deny-secret-file-access.ps1'
$denyHook = Join-Path $root '.claude\hooks\deny-secret-file-access.ps1'
$denyTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-hook-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $denyTmp -Force | Out-Null
function Test-CommandDenied {
    <# シェルのコマンドを、Claude Code と同じく UTF-8（BOM なし）の JSON で hook に渡し、止められたかを返す #>
    param([string]$Command)
    $in = Join-Path $denyTmp 'in.json'
    $out = Join-Path $denyTmp 'out.txt'
    $json = '{"tool_name":"PowerShell","tool_input":{"command":' + (ConvertTo-Json $Command) + '}}'
    [IO.File]::WriteAllText($in, $json, (New-Object Text.UTF8Encoding($false)))
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $denyHook) `
        -RedirectStandardInput $in -RedirectStandardOutput $out -NoNewWindow -Wait
    return ([IO.File]::ReadAllText($out)) -match '"permissionDecision":"deny"'
}
try {
    Assert-True (Test-CommandDenied 'Get-Content ~/.claude/sessions/1234.key') 'sessions の *.key を読むコマンドを止める'
    Assert-True (Test-CommandDenied 'cat server.pem') '*.pem を読むコマンドを止める'
    Assert-True (Test-CommandDenied 'cat $name.key') 'bash の $name.key（小文字）はファイル名として止める'
    Assert-True (Test-CommandDenied 'Get-Content .env') '.env を読むコマンドを止める'
    Assert-True (-not (Test-CommandDenied '$script:State.Values | % { $_.Key }')) '$_.Key はプロパティ参照なので止めない'
    Assert-True (-not (Test-CommandDenied "Select-String -Pattern '`$notice.Key' andon.ps1")) '$notice.Key を探すコマンドを止めない'
    Assert-True (-not (Test-CommandDenied '$script:State[''1''].Key')) '[ ] の後ろの .Key を止めない'
    Assert-True (-not (Test-CommandDenied '(Get-AlertNotice -Entries $e -Now $t).Key')) '( ) の後ろの .Key を止めない'
    Assert-True (-not (Test-CommandDenied '$_.Value.Key')) 'プロパティを続けた後ろの .Key を止めない'
    Assert-True (-not (Test-CommandDenied 'cat .env.example')) '.env.example は止めない'
    Assert-True (Test-CommandDenied 'cat secrets.json') 'secrets.json を読むコマンドを止める'
    Assert-True (Test-CommandDenied 'Get-Content config/secrets.yaml') 'フォルダの中の secrets.yaml を読むコマンドを止める'
    Assert-True (-not (Test-CommandDenied 'echo ${{ secrets.GITHUB_TOKEN }}')) 'GitHub Actions の式の secrets.* は止めない'
    Assert-True (Test-CommandDenied 'echo ${{ secrets.GITHUB_TOKEN }}; cat secrets.json') '式の外に secrets.json があれば止める'
}
finally {
    Remove-Item -LiteralPath $denyTmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
$passed = $script:Count - $script:Failures
Write-Host ''
Write-Host "$passed / $($script:Count) passed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
