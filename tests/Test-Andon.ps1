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
Assert-Equal (Get-AlertLevel @($script:State.Values)) 'none' '実行中と待機が混ざれば none'
Assert-Equal (Get-AlertLevel @()) 'none' 'セッションがなければ none'
Assert-Equal (Get-AlertLevel @($script:State['1'])) 'busy' '実行中が 1 件だけなら busy'
$busy2 = [pscustomobject]@{ Key = '7'; Status = 'busy'; Unread = $false }
Assert-Equal (Get-AlertLevel @($script:State['1'], $busy2)) 'busy' '全部が実行中なら busy'
$unknown = [pscustomobject]@{ Key = '8'; Status = 'unknown'; Unread = $false }
Assert-Equal (Get-AlertLevel @($script:State['1'], $unknown)) 'none' '実行中と、状態の分からないものが混ざれば none'
Assert-Equal (Get-AlertLevel @($script:State['1'], ([pscustomobject]@{ Key = '9'; Status = 'idle'; Unread = $true }))) 'done' '実行中と完了なら done'
Assert-Equal (Get-AlertLevel @($script:State['1'], ([pscustomobject]@{ Key = '9'; Status = 'waiting'; Unread = $true }))) 'waiting' '実行中と待ちなら waiting'

# トレイのアイコンは GUI の部分（ドットソースの境界より後ろ）で作るので、Get-AlertLevel が返す色ごとに
# $script:Icons にアイコンがあるかを、構文木で確かめる。ないと、その色のときにトレイのアイコンが消える
$andonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'andon.ps1'), [ref]$null, [ref]$null)
$levelAst = $andonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AlertLevel' }, $true)
$levels = @($levelAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true) |
        ForEach-Object { $_.Pipeline.GetPureExpression().Value } | Sort-Object)
Assert-Equal ($levels -join ',') 'busy,done,none,waiting' 'Get-AlertLevel が返す色は 4 つ'
$iconsAst = $andonAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Icons' }, $true)
$iconKeys = @()
if ($iconsAst) {
    $iconKeys = @($iconsAst.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs |
            ForEach-Object { $_.Item1.Value })
}
foreach ($level in $levels) {
    Assert-True ($iconKeys -contains $level) "トレイのアイコン（`$script:Icons）に $level がある"
}
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
Write-Host '== 更新の確認: 版を比べる（Test-NewerVersion）'
Assert-True (Test-NewerVersion -Version '0.1.1' -Current '0.1.0') 'PATCH が上がれば新しい'
Assert-True (Test-NewerVersion -Version '0.2.0' -Current '0.1.9') 'MINOR が上がれば新しい'
Assert-True (Test-NewerVersion -Version '1.0.0' -Current '0.9.9') 'MAJOR が上がれば新しい'
Assert-True (Test-NewerVersion -Version '0.1.10' -Current '0.1.9') '文字ではなく数として比べる'
Assert-Equal (Test-NewerVersion -Version '0.1.0' -Current '0.1.0') $false '同じ版は新しくない'
Assert-Equal (Test-NewerVersion -Version '0.0.9' -Current '0.1.0') $false '古い版は新しくない'
Assert-Equal (Test-NewerVersion -Version 'v0.2.0' -Current '0.1.0') $false 'v の付いた形は扱わない（tag の v を外してから比べる）'
Assert-Equal (Test-NewerVersion -Version '0.2' -Current '0.1.0') $false 'MAJOR.MINOR.PATCH でなければ新しくない'
Assert-Equal (Test-NewerVersion -Version '99999999999.0.0' -Current '0.1.0') $false '版として読めない大きな数は新しくない'

Write-Host '== 更新の確認: Release を読む（Get-UpdateInfo）'
function New-Release {
    <# GitHub の releases/latest の応答と同じ形（使う項目だけ）を ConvertFrom-Json して返す。値は JSON のまま渡す #>
    param([string]$Tag = 'v0.2.0', [string]$Draft = 'false', [string]$Prerelease = 'false', [string]$Immutable = 'true',
        [string]$AssetName, [string]$Url, [string]$Digest = ('"sha256:' + ('AB' * 32) + '"'))
    $version = $Tag.TrimStart('v')
    if (-not $AssetName) { $AssetName = "andon-$version.zip" }
    if (-not $Url) { $Url = "https://github.com/tbshiki/andon/releases/download/$Tag/$AssetName" }
    return ConvertFrom-Json -InputObject @"
{
  "html_url": "https://github.com/tbshiki/andon/releases/tag/$Tag",
  "tag_name": "$Tag",
  "name": "andon $version",
  "draft": $Draft,
  "immutable": $Immutable,
  "prerelease": $Prerelease,
  "assets": [
    { "name": "notes.txt", "digest": "sha256:$('0' * 64)", "browser_download_url": "https://github.com/tbshiki/andon/releases/download/$Tag/notes.txt" },
    { "name": "$AssetName", "state": "uploaded", "size": 133847, "digest": $Digest, "browser_download_url": "$Url" }
  ]
}
"@
}
$info = Get-UpdateInfo -Release (New-Release) -CurrentVersion '0.1.0'
Assert-Equal $info.Version '0.2.0' '新しい版を見つける'
Assert-Equal $info.ZipUrl 'https://github.com/tbshiki/andon/releases/download/v0.2.0/andon-0.2.0.zip' 'zip を落とす場所'
Assert-Equal $info.Sha256 ('ab' * 32) 'digest の sha256（小文字にそろえる）'
Assert-Equal (Get-UpdateInfo -Release (New-Release) -CurrentVersion '0.2.0') $null '入っている版と同じなら $null'
Assert-Equal (Get-UpdateInfo -Release (New-Release) -CurrentVersion '0.3.0') $null '入っている版より古ければ $null'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Immutable 'false') -CurrentVersion '0.1.0') $null 'immutable でない Release は使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Immutable 'null') -CurrentVersion '0.1.0') $null 'immutable か分からない Release は使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Draft 'true') -CurrentVersion '0.1.0') $null '下書きは使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Prerelease 'true') -CurrentVersion '0.1.0') $null 'pre-release は使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Tag 'andon-0.2.0') -CurrentVersion '0.1.0') $null 'tag が v<版> の形でなければ使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Tag 'v0.2') -CurrentVersion '0.1.0') $null 'tag の版が MAJOR.MINOR.PATCH でなければ使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -AssetName 'andon.zip') -CurrentVersion '0.1.0') $null 'andon-<版>.zip がなければ使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Url 'https://github.com/someone/andon/releases/download/v0.2.0/andon-0.2.0.zip') -CurrentVersion '0.1.0') $null 'ほかのリポジトリから落とす zip は使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Url 'http://github.com/tbshiki/andon/releases/download/v0.2.0/andon-0.2.0.zip') -CurrentVersion '0.1.0') $null 'https でなければ使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Digest 'null') -CurrentVersion '0.1.0') $null 'digest がなければ使わない'
Assert-Equal (Get-UpdateInfo -Release (New-Release -Digest ('"sha1:' + ('a' * 40) + '"')) -CurrentVersion '0.1.0') $null 'sha256 でない digest は使わない'
Assert-Equal (Get-UpdateInfo -Release $null -CurrentVersion '0.1.0') $null '応答がなければ $null'

Write-Host '== 更新の確認: 更新するかを尋ねる画面の文（Get-UpdatePrompt）'
$prompt = Get-UpdatePrompt -Version '0.2.0' -CurrentVersion '0.1.1'
Assert-True ($prompt.StartsWith('andon v0.2.0 があります（今のバージョンは v0.1.1）。')) '新しい版と今の版を出す'
Assert-True ($prompt.EndsWith('アップデートは、いま起動している andon を終了して新しいバージョンをインストールして起動しなおします。')) 'アップデートすると何が起きるかを書く'
Assert-Equal ($prompt -match '更新|版|入れ') $false '状態の「更新」と分けるため、「アップデート」「バージョン」と書く。「入れる」ではなく「インストール」と書く'

Write-Host '== 利用者が読む文の表記: andon を「終わらせる」ではなく「終了する」と書く'
$endPattern = 'andon\s*(を|は|が|に)終わ'
foreach ($doc in 'README.md', 'README.txt', 'SECURITY.md') {
    $docText = Get-Content -LiteralPath (Join-Path $root $doc) -Raw -Encoding UTF8
    Assert-Equal ([regex]::IsMatch($docText, $endPattern)) $false "$doc は、andon が終わることを「終了」と書く"
}
foreach ($scriptName in 'andon.ps1', 'install.ps1') {
    # コメントは開発者向けなので見ない。画面とコンソールに出る文字列だけを見る
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $scriptName), [ref]$null, [ref]$null)
    $strings = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | ForEach-Object { [string]$_.Value })
    Assert-True ($strings.Count -gt 0) "$scriptName の文字列を読めた"
    Assert-Equal (@($strings | Where-Object { [regex]::IsMatch($_, $endPattern) }) -join ' / ') '' "$scriptName の文字列は、andon が終わることを「終了」と書く"
}

Write-Host '== 更新の確認: 新しい版の install.ps1 を起動するコマンド（Get-UpdateCommand）'
$updateCmd = Get-UpdateCommand -InstallScript "C:\Users\o'neil\AppData\Local\Temp\andon-update-0.2.0-x\install.ps1" -SystemRoot 'C:\Windows'
Assert-Equal $updateCmd.FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'Windows PowerShell 5.1 で実行する'
Assert-True ($updateCmd.Arguments.StartsWith('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ')) '実行ポリシーはそのプロセスだけ Bypass にし、スクリプトは -EncodedCommand で渡す'
Assert-Equal ($updateCmd.Arguments -match '-WindowStyle') $false 'コンソールを隠さない（install.ps1 の結果を読めるように）'
$decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($updateCmd.Arguments -split ' ')[-1]))
Assert-True ($decoded.Contains("& 'C:\Users\o''neil\AppData\Local\Temp\andon-update-0.2.0-x\install.ps1';")) 'パスの単一引用符を重ね、引数を付けずに install.ps1 を実行する'
$curly = Get-UpdateCommand -InstallScript ('C:\x\a' + [char]0x2019 + 'b\install.ps1')
$decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($curly.Arguments -split ' ')[-1]))
Assert-True ($decoded.Contains("& 'C:\x\a" + [char]0x2019 + [char]0x2019 + "b\install.ps1'")) '単一引用符として扱われる U+2019 も重ねる'

Write-Host '== 更新の確認: -NoUpdateCheck'
Assert-True ((Get-Command (Join-Path $root 'andon.ps1')).Parameters.ContainsKey('NoUpdateCheck')) 'andon.ps1 は -NoUpdateCheck を受け取る'
Assert-Equal (Get-ExtraArguments -Arguments ((Get-AndonLaunch -InstallDir 'C:\Apps\andon' -SystemRoot 'C:\Windows').Arguments + ' -NoUpdateCheck')) '-NoUpdateCheck' 'ショートカットに付けた -NoUpdateCheck は、更新しても引き継ぐ'

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
    $uninstallRoot = Join-Path $regBase 'Uninstall'
    $approved = Join-Path $regBase 'StartupApproved'
    foreach ($k in @((Join-Path $classes 'tbshiki.andon'), (Join-Path $notifications 'tbshiki.andon'), (Join-Path $notifications 'andon'), (Join-Path $notifications 'example.other'), (Join-Path $uninstallRoot 'example.other'), $approved)) {
        New-Item -Path $k -Force | Out-Null
    }

    Write-Host '== install.ps1: 「インストールされているアプリ」への登録'
    $layoutKey = (Get-AndonLayout).UninstallKey
    Assert-Equal $layoutKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\tbshiki.andon' '登録するのは、このユーザーの Uninstall\tbshiki.andon'
    $defaultRoot = ((Get-Command Remove-AndonRegistry).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'UninstallRoot' }).DefaultValue.Value
    Assert-Equal (Join-Path $defaultRoot 'tbshiki.andon') $layoutKey '消すときも、登録したのと同じキーを見る'
    $ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $entry = Get-AndonUninstallEntry -InstallDir "C:\Users\o'neil 100% & (1)\AppData\Local\Programs\andon" -Version '0.2.0' -PowerShell $ps -SizeBytes 2049 -Date ([datetime]'2026-11-05')
    Assert-Equal $entry['UninstallString'] ('"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -File "C:\Users\o''neil 100% & (1)\AppData\Local\Programs\andon\install.ps1" -Uninstall -PauseOnError') 'アンインストールのコマンドは、Windows PowerShell 5.1 を絶対パスで起動し、パスを引用符で囲む'
    Assert-Equal ($entry['UninstallString'] -match '(?i)cmd(\.exe)?\b|install\.cmd') $false 'アンインストールのコマンドは cmd.exe を通さない'
    Assert-Equal $entry['DisplayName'] 'andon' '名前'
    Assert-Equal $entry['DisplayVersion'] '0.2.0' 'バージョン'
    Assert-Equal $entry['InstallDate'] '20261105' '入れた日は yyyyMMdd'
    Assert-Equal $entry['EstimatedSize'] 3 '大きさは KB（切り上げ）'
    Assert-Equal $entry['DisplayIcon'] "C:\Users\o'neil 100% & (1)\AppData\Local\Programs\andon\andon.ico" 'アイコンはインストール先の andon.ico'
    Assert-Equal $entry.Contains('DisplayVersion') $true 'バージョンが分かれば書く'
    Assert-Equal (Get-AndonUninstallEntry -InstallDir 'C:\Apps\andon' -Version '' -PowerShell $ps).Contains('DisplayVersion') $false 'バージョンが分からなければ書かない'

    $testKey = Join-Path $uninstallRoot 'tbshiki.andon'
    Set-AndonUninstallEntry -Key $testKey -Values $entry
    $item = Get-Item -LiteralPath $testKey
    Assert-Equal $item.GetValue('UninstallString') $entry['UninstallString'] '登録したアンインストールのコマンドを読める'
    Assert-Equal $item.GetValueKind('NoModify').ToString() 'DWord' 'NoModify は DWORD'
    Assert-Equal $item.GetValueKind('EstimatedSize').ToString() 'DWord' 'EstimatedSize は DWORD'
    Assert-Equal $item.GetValueKind('DisplayVersion').ToString() 'String' 'DisplayVersion は文字列'
    $entry['DisplayVersion'] = '0.2.1'
    Set-AndonUninstallEntry -Key $testKey -Values $entry
    Assert-Equal (Get-Item -LiteralPath $testKey).GetValue('DisplayVersion') '0.2.1' 'もう一度入れると書き直す（バージョンをそろえる）'

    # Windows と同じく、先頭のバイトが 02 なら有効、03 なら無効
    New-ItemProperty -LiteralPath $approved -Name 'andon.lnk' -PropertyType Binary -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null
    New-ItemProperty -LiteralPath $approved -Name 'other.lnk' -PropertyType Binary -Value ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null
    Assert-True (Test-StartupDisabled -StartupApprovedKey $approved) '先頭が 03 なら、タスク マネージャーで無効にしてある'
    Set-ItemProperty -LiteralPath $approved -Name 'andon.lnk' -Value ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    Assert-Equal (Test-StartupDisabled -StartupApprovedKey $approved) $false '先頭が 02 なら有効'
    Set-ItemProperty -LiteralPath $approved -Name 'andon.lnk' -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    Assert-Equal (Test-StartupDisabled -StartupApprovedKey (Join-Path $regBase 'NoSuchKey')) $false '記録がなければ有効（無効にしていない）'
    # 本物の記録（StartupApproved\StartupFolder、Uninstall\tbshiki.andon）を消さないよう、場所は必ず渡す
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey $approved).Count 5 'アプリ ID の表示名、2 つの ID の通知の設定、「インストールされているアプリ」への登録、スタートアップの有効・無効の記録を消す'
    Assert-Equal (Test-Path -LiteralPath $testKey) $false '「インストールされているアプリ」への登録を消した'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $uninstallRoot 'example.other')) $true 'ほかのアプリの登録は消さない'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $notifications 'example.other')) $true 'ほかのアプリの通知の設定は消さない'
    Assert-Equal ((Get-Item -LiteralPath $approved).GetValueNames() -join ',') 'other.lnk' 'ほかのショートカットの有効・無効の記録は消さない'
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey $approved).Count 0 'なければ何もしない'
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey (Join-Path $regBase 'NoSuchKey')).Count 0 '記録の場所がなくても失敗しない'
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
    Copy-Item -LiteralPath (Join-Path $root 'andon.ico') -Destination (Join-Path $src 'andon.ico')
    # ブラウザで落としてエクスプローラーで展開したときと同じく、ダウンロードした印を付ける
    Set-Content -LiteralPath (Join-Path $src 'andon.ps1') -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    Assert-Equal @(Copy-AndonFiles -SourceDir $src -InstallDir $dst).Count 4 'アイコンを含む配るファイルを 4 つ置く'
    Add-Type -AssemblyName System.Drawing
    foreach ($size in @(16, 32, 48, 128)) {
        $icon = New-Object System.Drawing.Icon((Join-Path $dst 'andon.ico'), $size, $size)
        try { Assert-Equal $icon.Width $size "配ったアイコンを $size px で読める" }
        finally { $icon.Dispose() }
    }
    Assert-Equal (Test-Path -LiteralPath (Join-Path $dst 'notes.txt')) $false '配るファイルでないものは置かない'
    Assert-Equal @(Get-Item -LiteralPath (Join-Path $dst 'andon.ps1') -Stream * | Where-Object { $_.Stream -eq 'Zone.Identifier' }).Count 0 'ダウンロードした印を外す'
    Set-Content -LiteralPath (Join-Path $src 'andon.ps1') -Value 'v2' -Encoding UTF8
    [void](Copy-AndonFiles -SourceDir $src -InstallDir $dst)
    Assert-Equal (Get-Content -LiteralPath (Join-Path $dst 'andon.ps1') -Raw -Encoding UTF8).Trim() 'v2' 'もう一度入れると新しいファイルに置き換える'
    Assert-Equal @(Get-ChildItem -LiteralPath $dst -Filter '*.new').Count 0 '一時ファイルを残さない'
    Assert-Equal @(Copy-AndonFiles -SourceDir $dst -InstallDir $dst).Count 4 '入れた場所の install.ps1 から実行しても失敗しない'
    Remove-Item -LiteralPath (Join-Path $src 'andon.ps1')
    Assert-Throws { Copy-AndonFiles -SourceDir $src -InstallDir $dst } 'andon.ps1 がなければ例外にする'

    Write-Host '== install.ps1: ショートカット'
    $lnk = Join-Path $installTmp 'links\andon.lnk'
    $dstLaunch = Get-AndonLaunch -InstallDir $dst
    New-AndonShortcut -Path $lnk -Launch $dstLaunch
    Assert-Equal (Get-ShortcutArguments -Path $lnk) $dstLaunch.Arguments 'ショートカットに起動の引数を書く'
    $wsh = New-Object -ComObject WScript.Shell
    try {
        Assert-PathEqual $wsh.CreateShortcut($lnk).TargetPath $dstLaunch.FilePath 'ショートカットのリンク先は conhost.exe'
        Assert-PathEqual $wsh.CreateShortcut($lnk).IconLocation ((Join-Path $dst 'andon.ico') + ',0') 'ショートカットはインストール先のアイコンを使う'
        Remove-Item -LiteralPath (Join-Path $dst 'andon.ico')
        New-AndonShortcut -Path $lnk -Launch $dstLaunch
        Assert-PathEqual $wsh.CreateShortcut($lnk).IconLocation ($dstLaunch.PowerShell + ',0') 'アイコンがないときは PowerShell のアイコンで起動できる'
    }
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

    Write-Host '== install.ps1: 配る zip'
    foreach ($name in Get-AndonPayload) {
        # 古い andon は、アップデートの zip を展開する前に、項目の名前をこの形に限って確かめる（andon.ps1 の Expand-UpdatePackage）
        Assert-True ($name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') "配るファイルの名前は英数字と . _ - だけ: $name"
    }
    Assert-True ($andonText.Contains('''^[A-Za-z0-9][A-Za-z0-9._-]*$''')) 'andon.ps1 が zip の項目の名前を確かめる形は、上と同じ'
    $cmdBytes = [IO.File]::ReadAllBytes((Join-Path $root 'install.cmd'))
    $cmdText = [Text.Encoding]::ASCII.GetString($cmdBytes)
    Assert-Equal @($cmdBytes | Where-Object { $_ -ge 0x80 }).Count 0 'install.cmd は ASCII だけ（cmd.exe はコンソールのコード ページで読む）'
    Assert-True (-not [regex]::IsMatch($cmdText, "(?<!`r)`n")) 'install.cmd の改行は CRLF（LF だけだと goto の飛び先を読み違える）'
    Assert-True ($cmdText.Contains('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"')) 'install.cmd は Windows PowerShell 5.1 を絶対パスで起動し、隣の install.ps1 を引用符で囲んで渡す'
    Assert-Equal ([regex]::IsMatch($cmdText, '(?im)^\s*(rem|::).*%')) $false 'install.cmd の注釈に % を書かない（rem の行も % を展開する）'
    $readmeTxt = Get-Content -LiteralPath (Join-Path $root 'README.txt') -Raw -Encoding UTF8
    Assert-Equal ([regex]::IsMatch($readmeTxt, '入れ|入る|入り')) $false 'README.txt は「入れる」ではなく「インストール」「アップデート」と書く'
    $removeCalls = @([regex]::Matches((Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8), '(?m)^(?!\s*#).*\bRemove-AndonRegistry\s+-.*$') | ForEach-Object { $_.Value })
    Assert-True ($removeCalls.Count -gt 0 -and @($removeCalls | Where-Object { $_ -notmatch '-UninstallRoot\s' }).Count -eq 0) 'テストは Remove-AndonRegistry に必ずテスト用の場所を渡す（本物の登録を消さない）'
    # リポジトリのファイルから、Release の workflow と同じく zip を作る
    $zip = New-AndonPackage -SourceDir $root -OutDir (Join-Path $installTmp 'out') -Version $script:AndonVersion
    Assert-Equal (Split-Path -Leaf $zip) "andon-$($script:AndonVersion).zip" 'zip の名前は andon-<版>.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
        Assert-Equal ($entries -join ',') ((Get-AndonPayload | Sort-Object) -join ',') 'zip の直下に、配るファイルだけを入れる'
        $entry = $archive.GetEntry('andon.ps1')
        $stream = $entry.Open()
        try {
            $buffer = New-Object IO.MemoryStream
            $stream.CopyTo($buffer)
            $zipped = $buffer.ToArray()
        }
        finally { $stream.Dispose() }
        $original = [IO.File]::ReadAllBytes((Join-Path $root 'andon.ps1'))
        Assert-True ([Convert]::ToBase64String($zipped) -ceq [Convert]::ToBase64String($original)) 'zip の andon.ps1 はリポジトリのものと同じ（BOM と CRLF を保つ）'
    }
    finally { $archive.Dispose() }
    Assert-Equal (Split-Path -Leaf (New-AndonPackage -SourceDir $root -OutDir (Join-Path $installTmp 'out') -Version $script:AndonVersion)) "andon-$($script:AndonVersion).zip" '同じ版の zip があれば作り直す'
    Assert-Throws { New-AndonPackage -SourceDir $root -OutDir (Join-Path $installTmp 'out') -Version 'v0.1' } '版の形が違えば例外にする'
    $partial = Join-Path $installTmp 'partial'
    New-Item -ItemType Directory -Path $partial -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'andon.ps1') -Destination $partial
    Assert-Throws { New-AndonPackage -SourceDir $partial -OutDir (Join-Path $installTmp 'out') -Version $script:AndonVersion } '配るファイルが欠けていれば例外にする（欠けた zip を配らない）'

    Write-Host '== 更新の確認: 確かめるか（Test-UpdateCheckEnabled）'
    $plain = Join-Path $installTmp 'plain'
    $cloned = Join-Path $installTmp 'cloned'
    $worktree = Join-Path $installTmp 'worktree'
    foreach ($d in @($plain, (Join-Path $cloned '.git'), $worktree)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $worktree '.git'), 'gitdir: C:/work/repo/.git/worktrees/x')
    Assert-True (Test-UpdateCheckEnabled -ScriptDir $plain -Disabled $false) 'インストールした andon は確かめる'
    Assert-Equal (Test-UpdateCheckEnabled -ScriptDir $plain -Disabled $true) $false '-NoUpdateCheck を付けたら確かめない'
    Assert-Equal (Test-UpdateCheckEnabled -ScriptDir $cloned -Disabled $false) $false 'andon.ps1 の隣に .git があれば（clone で開発しているとき）確かめない'
    Assert-Equal (Test-UpdateCheckEnabled -ScriptDir $worktree -Disabled $false) $false 'worktree（.git がファイル）でも確かめない'
    Assert-Equal (Test-UpdateCheckEnabled -ScriptDir '' -Disabled $false) $false 'andon.ps1 の場所が分からなければ確かめない'

    Write-Host '== 更新の確認: 展開するフォルダ（New-UpdateWorkDir）'
    $tempRoot = Join-Path $installTmp 'temp'
    foreach ($d in @('andon-update-0.1.0-old\sub', 'other')) { New-Item -ItemType Directory -Path (Join-Path $tempRoot $d) -Force | Out-Null }
    $work = New-UpdateWorkDir -Version '0.2.0' -TempDir $tempRoot
    Assert-True (Test-Path -LiteralPath $work -PathType Container) '展開するフォルダを作る'
    Assert-True ((Split-Path -Leaf $work) -like 'andon-update-0.2.0-*') 'フォルダの名前に版を入れる'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $tempRoot 'andon-update-0.1.0-old')) $false '前の更新で残ったフォルダを消す'
    Assert-True (Test-Path -LiteralPath (Join-Path $tempRoot 'other')) 'ほかのフォルダは消さない'

    Write-Host '== 更新の確認: 落とした zip を確かめて展開する（Expand-UpdatePackage）'
    function Get-TestSha256 {
        param([byte[]]$Bytes)
        $h = [Security.Cryptography.SHA256]::Create()
        try { return -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
        finally { $h.Dispose() }
    }
    function New-TestZip {
        <# 名前と中身を並べた zip をメモリに作る。名前はそのまま項目の名前になる（フォルダやパスを含む項目も作れる） #>
        param([System.Collections.IDictionary]$Files)
        Add-Type -AssemblyName System.IO.Compression
        $ms = New-Object IO.MemoryStream
        $archive = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in $Files.Keys) {
                $writer = New-Object IO.StreamWriter($archive.CreateEntry($name).Open())
                try { $writer.Write([string]$Files[$name]) } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        return , $ms.ToArray()
    }
    # Release の workflow と同じく作った zip（上の「配る zip」）
    $released = [IO.File]::ReadAllBytes($zip)
    $installer = Expand-UpdatePackage -Bytes $released -Sha256 (Get-TestSha256 $released).ToUpperInvariant() -WorkDir (Join-Path $work 'released')
    Assert-PathEqual $installer (Join-Path $work 'released\install.ps1') '展開した install.ps1 のパスを返す'
    Assert-Equal ((@(Get-ChildItem -LiteralPath (Join-Path $work 'released') -Name) | Sort-Object) -join ',') ((Get-AndonPayload | Sort-Object) -join ',') '配る zip を展開すると、配るファイルがそろう'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $work 'released\andon.ps1'))) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'andon.ps1')))) '展開した andon.ps1 は元と同じ（BOM と CRLF を保つ）'

    $more = New-TestZip ([ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i'; 'new-file.txt' = 'n' })
    [void](Expand-UpdatePackage -Bytes $more -Sha256 (Get-TestSha256 $more) -WorkDir (Join-Path $work 'more'))
    Assert-True (Test-Path -LiteralPath (Join-Path $work 'more\new-file.txt')) '配るファイルを足した版の zip も展開できる'

    $plainZip = New-TestZip ([ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i' })
    Assert-Throws { Expand-UpdatePackage -Bytes $plainZip -Sha256 ('0' * 64) -WorkDir (Join-Path $work 'x1') } 'sha256 が Release の値と違えば例外にする'
    Assert-Throws { Expand-UpdatePackage -Bytes $plainZip -Sha256 '' -WorkDir (Join-Path $work 'x2') } 'sha256 が分からなければ例外にする'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $work 'x1')) $false 'sha256 が違えば何も展開しない'
    Assert-Throws { Expand-UpdatePackage -Bytes $plainZip -Sha256 (Get-TestSha256 $plainZip) -WorkDir (Join-Path $work 'x3') -MaxBytes 10 } '大きすぎる zip は例外にする'
    $notZip = [Text.Encoding]::UTF8.GetBytes('not a zip')
    Assert-Throws { Expand-UpdatePackage -Bytes $notZip -Sha256 (Get-TestSha256 $notZip) -WorkDir (Join-Path $work 'x4') } 'zip でなければ例外にする'
    Assert-Throws { Expand-UpdatePackage -Bytes ([byte[]]@()) -Sha256 ('0' * 64) -WorkDir (Join-Path $work 'x5') } '空なら例外にする'
    # ハッシュの式は大文字小文字を区別しないので、同じ名前を 2 つ並べる zip は別に作る
    $sameName = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    $sameName['andon.ps1'] = 'a'; $sameName['install.ps1'] = 'i'; $sameName['ANDON.PS1'] = 'b'
    $cases = [ordered]@{
        'install.ps1 がなければ例外にする'                        = [ordered]@{ 'andon.ps1' = 'a' }
        'andon.ps1 がなければ例外にする'                          = [ordered]@{ 'install.ps1' = 'i' }
        'フォルダの中の項目は例外にする'                          = [ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i'; 'sub/x.txt' = 'x' }
        '上のフォルダに書かせる項目（..）は例外にする'            = [ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i'; '../evil.ps1' = 'x' }
        '\ で区切った項目は例外にする'                            = [ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i'; '..\evil.ps1' = 'x' }
        'フォルダの項目は例外にする'                              = [ordered]@{ 'andon.ps1' = 'a'; 'install.ps1' = 'i'; 'docs/' = '' }
        '大文字小文字だけが違う同じ名前の項目は例外にする'        = $sameName
    }
    $n = 0
    foreach ($case in $cases.Keys) {
        $n++
        $bytes = New-TestZip $cases[$case]
        Assert-Throws { Expand-UpdatePackage -Bytes $bytes -Sha256 (Get-TestSha256 $bytes) -WorkDir (Join-Path $work "case$n") } $case
    }
    Assert-Equal (Test-Path -LiteralPath (Join-Path $work 'evil.ps1')) $false '上のフォルダには何も書かない'

    Write-Host '== 更新の確認: 起動するコマンドを実際に動かす'
    # 空白と、単一引用符として扱われる ' と U+2019 を含むフォルダに、終了コードを選べる偽の install.ps1 を置く
    $fakeDir = Join-Path $installTmp ("o'neil " + [char]0x2019 + 'dir')
    New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
    $fakeInstaller = Join-Path $fakeDir 'install.ps1'
    [IO.File]::WriteAllText($fakeInstaller, "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'ran.txt'), [string]`$args.Count)`r`nexit [int]`$env:ANDON_TEST_EXIT`r`n", (New-Object Text.UTF8Encoding($true)))
    $savedExit = $env:ANDON_TEST_EXIT
    try {
        foreach ($code in @(0, 4)) {
            Remove-Item -LiteralPath (Join-Path $fakeDir 'ran.txt') -ErrorAction SilentlyContinue
            $env:ANDON_TEST_EXIT = [string]$code
            $c = Get-UpdateCommand -InstallScript $fakeInstaller
            $psi = New-Object Diagnostics.ProcessStartInfo $c.FilePath, $c.Arguments
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            # 失敗のときは Enter キーを待つので、入力を閉じて先へ進ませる
            $psi.RedirectStandardInput = $true
            # 出力を渡さないと、PowerShell が進行状況を XML で書き、テストの表示に混ざる
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [Diagnostics.Process]::Start($psi)
            try {
                $proc.StandardInput.Close()
                [void]$proc.StandardOutput.ReadToEndAsync()
                [void]$proc.StandardError.ReadToEndAsync()
                $exited = $proc.WaitForExit(30000)
                if (-not $exited) { $proc.Kill() }
                Assert-True $exited "終了コード $code の install.ps1 のあと、コンソールは閉じる"
                Assert-Equal $proc.ExitCode $code "install.ps1 の終了コード $code を返す"
            }
            finally { $proc.Dispose() }
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $fakeDir 'ran.txt'))) '0' "引用符を含むパスの install.ps1 を、引数なしで実行する（終了コード $code）"
        }
    }
    finally { $env:ANDON_TEST_EXIT = $savedExit }

    function Start-TestProcess {
        <# 入力と出力をつないだまま、ウィンドウなしでプロセスを起動する。入力を閉じないので、PowerShell の Read-Host は待つ。
           cmd.exe の pause は、入力がパイプだと、待つかどうかが起動した側で違う（Windows PowerShell 5.1 から起動すると待たずに戻り、
           PowerShell 7 から起動すると待つ）。ダブルクリックしたときの入力はコンソールなので待つ。
           そのため pause は、少し待ってから Enter を送り、出力に pause の案内の末尾（日本語でも英語でも ASCII の " . . ."）があるかで見る #>
        param([string]$FilePath, [string]$Arguments = '', [hashtable]$Environment = @{})
        $psi = New-Object Diagnostics.ProcessStartInfo $FilePath, $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
        $proc = [Diagnostics.Process]::Start($psi)
        return [pscustomobject]@{
            Process = $proc
            Output  = $proc.StandardOutput.ReadToEndAsync()
            Error   = $proc.StandardError.ReadToEndAsync()
        }
    }
    function Stop-TestProcess {
        <# Enter を送って入力を閉じ、終わるのを待つ。終わらなければ止める。終わったかを返す #>
        param($Started)
        try { $Started.Process.StandardInput.WriteLine(); $Started.Process.StandardInput.Close() } catch { }
        $exited = $Started.Process.WaitForExit(30000)
        if (-not $exited) { try { $Started.Process.Kill() } catch { } }
        return $exited
    }
    function Get-TestOutput {
        param($Started)
        if (-not $Started.Output.Wait(5000)) { return '' }
        return [string]$Started.Output.Result
    }

    Write-Host '== install.cmd: ダブルクリックの入口を実際に動かす'
    # 偽の install.ps1 を置く。動いたら、受け取った引数の数を ran.txt に書き、ANDON_TEST_EXIT の終了コードで終わる。
    # フォルダの名前には、cmd.exe が特別に読む文字と、Shift-JIS で 2 バイト目が \ になる文字（表・ソ・能）を入れる
    $cmdSource = Join-Path $root 'install.cmd'
    $fakeScript = "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'ran.txt'), [string]`$args.Count)`r`nexit [int]`$env:ANDON_TEST_EXIT`r`n"
    $cmdDirs = @('a b', 'a&b', '100%', 'andon-0.2.0 (1)', ([string][char]0x8868 + [char]0x30BD + [char]0x80FD),
        ("all a&b 100% (1) ^ ! o'neil ;,= " + [char]0x8868 + [char]0x30BD + [char]0x80FD))
    $n = 0
    foreach ($dirName in $cmdDirs) {
        $n++
        $dir = Join-Path $installTmp "cmd$n\$dirName"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath $cmdSource -Destination $dir
        [IO.File]::WriteAllText((Join-Path $dir 'install.ps1'), $fakeScript, (New-Object Text.UTF8Encoding($true)))
        $t = Start-TestProcess -FilePath (Join-Path $dir 'install.cmd') -Environment @{ ANDON_TEST_EXIT = '0' }
        try {
            $before = $t.Process.WaitForExit(30000)
            $exited = Stop-TestProcess $t
            Assert-True ($before -and $exited) "成功したら閉じる: $dirName"
            if ($exited) { Assert-Equal $t.Process.ExitCode 0 "成功したら終了コード 0: $dirName" }
            Assert-Equal ((Get-TestOutput $t).Contains(' . . .')) $false "成功したらキーを待たない（pause を通らない）: $dirName"
        }
        finally { $t.Process.Dispose() }
        $ran = Join-Path $dir 'ran.txt'
        Assert-True (Test-Path -LiteralPath $ran) "隣の install.ps1 を実行する: $dirName"
        if (Test-Path -LiteralPath $ran) { Assert-Equal ([IO.File]::ReadAllText($ran)) '0' "install.ps1 に引数を渡さない: $dirName" }
    }

    # 失敗したとき: install.ps1 を実行したあと、pause でキーを待つ
    $dir = Join-Path $installTmp "cmd$n\$($cmdDirs[-1])"
    Remove-Item -LiteralPath (Join-Path $dir 'ran.txt') -ErrorAction SilentlyContinue
    $t = Start-TestProcess -FilePath (Join-Path $dir 'install.cmd') -Environment @{ ANDON_TEST_EXIT = '4' }
    try {
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath (Join-Path $dir 'ran.txt')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        [void]$t.Process.WaitForExit(2000)
        Assert-True (Stop-TestProcess $t) 'install.ps1 が失敗したときも、キーを押せば閉じる'
        Assert-True (Test-Path -LiteralPath (Join-Path $dir 'ran.txt')) '失敗する install.ps1 も実行する'
        Assert-True ((Get-TestOutput $t).Contains(' . . .')) 'install.ps1 が失敗したら、pause でキーを待つ'
        Assert-Equal $t.Process.ExitCode 1 'install.ps1 が失敗したら終了コード 1'
    }
    finally { $t.Process.Dispose() }

    # zip を開くアプリが、開いた install.cmd だけを取り出して動かしたとき（隣に install.ps1 がない）。
    # エクスプローラーは、zip の中のファイルを開くと、全部を取り出してから動かすので、この形にはならない
    $alone = Join-Path $installTmp 'cmd-alone'
    New-Item -ItemType Directory -Path $alone -Force | Out-Null
    Copy-Item -LiteralPath $cmdSource -Destination $alone
    $t = Start-TestProcess -FilePath (Join-Path $alone 'install.cmd')
    try {
        [void]$t.Process.WaitForExit(3000)
        Assert-True (Stop-TestProcess $t) 'install.ps1 がないときも、キーを押せば閉じる'
        $aloneOutput = Get-TestOutput $t
        Assert-True ($aloneOutput.Contains('install.ps1 was not found') -and $aloneOutput.Contains('Extract All')) '隣に install.ps1 がなければ、zip を展開するよう伝える'
        Assert-True ($aloneOutput.Contains(' . . .')) '隣に install.ps1 がなければ、pause でキーを待つ'
        Assert-Equal $t.Process.ExitCode 1 '隣に install.ps1 がなければ終了コード 1'
    }
    finally { $t.Process.Dispose() }

    Write-Host '== install.ps1: -PauseOnError'
    # install.ps1 だけを写したフォルダで動かす。隣に andon.ps1 がないので、実際の場所に触れる前に、失敗して終わる。
    # 念のため、インストール先（%LOCALAPPDATA%）もテスト用のフォルダに向ける
    $lonely = Join-Path $installTmp 'lonely'
    New-Item -ItemType Directory -Path (Join-Path $lonely 'localappdata') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'install.ps1') -Destination $lonely
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lonelyArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $lonely 'install.ps1')
    $lonelyEnv = @{ LOCALAPPDATA = (Join-Path $lonely 'localappdata') }
    $t = Start-TestProcess -FilePath $ps51 -Arguments $lonelyArgs -Environment $lonelyEnv
    try {
        $before = $t.Process.WaitForExit(30000)
        Assert-True ($before -and (Stop-TestProcess $t)) '-PauseOnError がなければ、失敗してもキーを待たずに閉じる'
        if ($before) { Assert-Equal $t.Process.ExitCode 1 '失敗したら終了コード 1' }
    }
    finally { $t.Process.Dispose() }
    # PowerShell の Read-Host は、入力がパイプでも、行が来るまで待つ
    $t = Start-TestProcess -FilePath $ps51 -Arguments ($lonelyArgs + ' -PauseOnError') -Environment $lonelyEnv
    try {
        Assert-Equal $t.Process.WaitForExit(8000) $false '-PauseOnError を付けたら、失敗したときに Enter キーを待つ'
        Assert-True (Stop-TestProcess $t) 'Enter キーを押せば閉じる'
        Assert-Equal $t.Process.ExitCode 1 '-PauseOnError を付けても、失敗したら終了コード 1'
    }
    finally { $t.Process.Dispose() }
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
        param([string]$Path, [string]$Root)
        # Windows PowerShell 5.1 の Process.StandardInput は先頭に BOM を書くので、ファイルから渡す
        $in = Join-Path $hookTmp 'in.json'
        $out = Join-Path $hookTmp 'out.txt'
        $json = '{"tool_name":"Edit","tool_input":{"file_path":' + (ConvertTo-Json $Path) + '}}'
        [IO.File]::WriteAllText($in, $json, (New-Object Text.UTF8Encoding($false)))
        $hookArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $hook
        if ($Root) { $hookArgs += ' -Root "{0}"' -f $Root }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $hookArgs `
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

        # このリポジトリを別のリポジトリ（外側）の中に置き、外側を root にして開いたとき。
        # 外側の settings から、外側用と、このリポジトリ用（-Root）の 2 回、hook を呼ぶ
        $outer = Join-Path $hookTmp 'outer'
        New-Item -ItemType Directory -Path $outer -Force | Out-Null
        foreach ($n in @('notes.md', 'AGENTS.md')) { [IO.File]::WriteAllText((Join-Path $outer $n), 'x') }
        $null = & git -C $outer init -q 2>&1
        $null = & git -C $outer add -- notes.md AGENTS.md 2>&1
        $env:CLAUDE_PROJECT_DIR = $outer
        Assert-Equal (Invoke-EditHook (Join-Path $root 'andon.ps1')) '' '-Root がなければ、外側で追跡していないファイルは自動許可しない'
        Assert-True ((Invoke-EditHook (Join-Path $root 'andon.ps1') -Root $root) -match '"permissionDecision":"allow"') '-Root で指定したリポジトリで追跡済みなら自動許可する'
        Assert-Equal (Invoke-EditHook (Join-Path $root 'AGENTS.md') -Root $root) '' '-Root で指定しても、AGENTS.md は自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $root '.claude\settings.json') -Root $root) '' '-Root で指定しても、.claude の下は自動許可しない'
        Assert-True ((Invoke-EditHook (Join-Path $outer 'notes.md')) -match '"permissionDecision":"allow"') '外側で追跡済みのファイルは自動許可する'
        Assert-Equal (Invoke-EditHook (Join-Path $outer 'AGENTS.md')) '' '外側の AGENTS.md も自動許可しない'
        Assert-Equal (Invoke-EditHook (Join-Path $outer 'notes.md') -Root $root) '' '-Root で指定したリポジトリの外のファイルは自動許可しない'
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
