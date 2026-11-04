#Requires -Version 5.1
<#
.SYNOPSIS
    andon.ps1 の GUI 以外の部分を確かめる。Pester などの依存はない。失敗があれば終了コード 1 を返す。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Andon.ps1

.EXAMPLE
    pwsh -NoProfile -File .\tests\Test-Andon.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'andon.ps1')

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
        Assert-Equal (Invoke-EditHook (Join-Path $root '[a]ndon.ps1')) '' 'パスの [ ] をワイルドカードとして扱わない'
        Assert-Equal (Invoke-EditHook (Join-Path $root 'untracked-new-file.ps1')) '' '未追跡のファイルは自動許可しない'
    }
    finally {
        $env:CLAUDE_PROJECT_DIR = $savedProjectDir
        Remove-Item -LiteralPath $hookTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
$passed = $script:Count - $script:Failures
Write-Host ''
Write-Host "$passed / $($script:Count) passed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
