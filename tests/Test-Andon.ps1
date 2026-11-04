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
        'repo-b2\.git', 'repo-c\.git', 'repo d\.git', 'repo-f\.git', 'repo-g\.git') {
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
		{ "path": "$absF" },
		{ "path": "..\\repo-g" },
	],
	"settings": {}
}
"@
    [IO.File]::WriteAllText($wsA, $wsText)
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
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo-c')) (Join-Path $ws 'repo-c') 'workspace がなければフォルダを開く'
    Assert-PathEqual (Resolve-VSCodeTarget -Cwd (Join-Path $ws 'repo d')) $wsD '空白を含むパス'
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
