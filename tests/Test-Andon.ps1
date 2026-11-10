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

# 通知に載せないセッション（$Quiet。Orca のセッションを通知しない設定のとき。D-136）
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t3 -Quiet @{ '4' = $true }
Assert-Equal $notice.Text "待ち: s5`n待ち: s6" 'Quiet にあるセッションは、通知に載せない'
Assert-Equal $notice.Key '5' 'Quiet にあるセッションは、通知のクリックで開くセッションにもならない'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t3 -Quiet @{ '4' = $true; '5' = $true; '6' = $true }) $null '新しい待ち・完了がどれも Quiet なら、通知しない'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t3 -Quiet @{}).Key '4' 'Quiet が空なら、これまでと同じ'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t3 -Quiet $null).Key '4' 'Quiet が $null でも、これまでと同じ'

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

function New-FlashMark { param($RootName, [long]$Window = 0) return [pscustomobject]@{ RootName = $RootName; Window = $Window } }
$flashState = @{
    '1' = [pscustomobject]@{ Key = '1'; Status = 'waiting'; Unread = $true }
    '2' = [pscustomobject]@{ Key = '2'; Status = 'idle'; Unread = $true }
    '3' = [pscustomobject]@{ Key = '3'; Status = 'busy'; Unread = $false }
    '5' = [pscustomobject]@{ Key = '5'; Status = 'waiting'; Unread = $true }
}
$flashKeys = @{ '1' = (New-FlashMark 'p1'); '2' = (New-FlashMark 'p2'); '3' = (New-FlashMark 'p3'); '4' = (New-FlashMark 'p4'); '5' = (New-FlashMark $null 5005) }
$kept = Get-PendingFlashKeys -FlashKeys $flashKeys -State $flashState -ForegroundTitle $null
Assert-Equal ((@($kept.Keys) | Sort-Object) -join ',') '1,2,5' '待ちと完了は残し、実行中に戻ったものと終わったものは外す'
$kept = Get-PendingFlashKeys -FlashKeys $flashKeys -State $flashState -ForegroundTitle 'a.ps1 - p1 - Visual Studio Code' -ForegroundWindow 7007
Assert-Equal ((@($kept.Keys) | Sort-Object) -join ',') '2,5' '前面の VS Code のウィンドウで開いているものは外す（ほかのウィンドウが前面でも、ターミナルのセッションは残す）'
Assert-Equal $kept['2'].RootName 'p2' '残したものは見分け方を保つ'
$kept = Get-PendingFlashKeys -FlashKeys $kept -State $flashState -ForegroundTitle $null -ForegroundWindow 5005
Assert-Equal ((@($kept.Keys) | Sort-Object) -join ',') '2' 'VS Code の外のターミナルのセッションは、そのウィンドウが前面にあれば外す'
$kept = Get-PendingFlashKeys -FlashKeys @{ '5' = (New-FlashMark 'p5' 5005) } -State $flashState -ForegroundTitle 'a.ps1 - p5 - Visual Studio Code'
Assert-Equal $kept.Count 1 'ターミナルのセッションは、題名に同じ名前の VS Code のウィンドウが前面にあっても外さない（ウィンドウで見分ける）'
$flashState['2'].Unread = $false
$kept = Get-PendingFlashKeys -FlashKeys @{ '2' = (New-FlashMark 'p2') } -State $flashState -ForegroundTitle $null
Assert-Equal $kept.Count 0 '既読にした完了も外す（残りがなければ点滅を止める）'

$markCwd = Join-Path ([IO.Path]::GetTempPath()) ('andon-mark-' + [guid]::NewGuid().ToString('N'))
$markEntry = [pscustomobject]@{ Key = '1'; Cwd = $markCwd }
$mark = Get-FlashMark -Entry $markEntry -SessionWindow ([pscustomobject]@{ Handle = [long]4242; IsCode = $false })
Assert-Equal "$($mark.RootName)|$($mark.Window)" '|4242' 'VS Code の外のターミナルのセッションは、ウィンドウで見分ける'
$mark = Get-FlashMark -Entry $markEntry -SessionWindow ([pscustomobject]@{ Handle = [long]4242; IsCode = $true })
Assert-Equal "$($mark.RootName)|$($mark.Window)" ((Split-Path -Leaf $markCwd) + '|0') 'VS Code のターミナルのセッションは、これまでどおり VS Code の題名で見分ける'
$mark = Get-FlashMark -Entry $markEntry -SessionWindow $null
Assert-Equal "$($mark.RootName)|$($mark.Window)" ((Split-Path -Leaf $markCwd) + '|0') 'ウィンドウが分からないセッションは、VS Code の題名で見分ける'

# ---------------------------------------------------------------------------
Write-Host '== セッションを映しているウィンドウ（Find-SessionConsoleWindow）'
$t0 = [datetime]'2026-01-01T12:00:00'
function New-Proc { param([int]$Id, [int]$Parent, [string]$Name, [int]$At) return [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CreationDate = $t0.AddSeconds($At) } }
function New-ConsoleWin {
    param([long]$Handle, [string]$Class, [int]$ProcessId, [bool]$Visible = $true, [long]$Owner = 0, [int]$OwnerProcessId = 0, [bool]$OwnerVisible = $true)
    return [pscustomobject]@{ Handle = $Handle; ClassName = $Class; ProcessId = $ProcessId; Visible = $Visible; OwnerHandle = $Owner; OwnerProcessId = $OwnerProcessId; OwnerVisible = $OwnerVisible }
}
$sessionProcs = @(
    (New-Proc 1 0 'explorer.exe' 0)
    (New-Proc 2 1 'Code.exe' 1)              # VS Code
    (New-Proc 3 2 'Code.exe' 2)              # VS Code のターミナルを持つプロセス
    (New-Proc 4 3 'pwsh.exe' 3)              # VS Code の統合ターミナルのシェル
    (New-Proc 5 4 'claude.exe' 4)            # VS Code の統合ターミナルのセッション
    (New-Proc 6 4 'powershell.exe' 5)        # VS Code のターミナルから、別のウィンドウ（Windows Terminal）で開いたシェル
    (New-Proc 7 6 'claude.exe' 6)            # そのセッション
    (New-Proc 8 1 'WindowsTerminal.exe' 1)
    (New-Proc 9 2 'Code.exe' 2)              # VS Code の拡張機能を動かすプロセス
    (New-Proc 10 9 'claude.exe' 7)           # 拡張機能のパネルのセッション
    (New-Proc 11 1 'cmd.exe' 1)              # conhost が描く cmd のウィンドウ
    (New-Proc 12 11 'claude.exe' 8)          # そのセッション
    (New-Proc 20 1 'cmd.exe' 0)              # VS Code を起動した cmd（ウィンドウがある）
    (New-Proc 21 20 'Code.exe' 1)
    (New-Proc 22 21 'claude.exe' 2)          # その VS Code の拡張機能のパネルのセッション
    (New-Proc 30 31 'claude.exe' 10)         # 親が終わり、親の PID がほかのプロセスに使い回された
    (New-Proc 31 1 'cmd.exe' 20)
    (New-Proc 40 41 'claude.exe' 3)
    (New-Proc 41 42 'powershell.exe' 2)      # 持ち主のない PseudoConsoleWindow（映しているウィンドウが分からない）
    (New-Proc 42 1 'cmd.exe' 1)
    (New-Proc 50 51 'claude.exe' 3)
    (New-Proc 51 1 'cmd.exe' 2)              # 隠れたコンソール
    (New-Proc 60 8 'claude.exe' 3)           # Windows Terminal が直接起動したセッション（コンソールを作ったのがセッション）
    (New-Proc 70 71 'claude.exe' 3)
    (New-Proc 71 8 'pwsh.exe' 2)             # 持ち主（Windows Terminal のウィンドウ）が隠れている
    (New-Proc 80 1 'Orca.exe' 1)             # Orca の本体（ウィンドウを持つ）
    (New-Proc 81 80 'Orca.exe' 2)            # 区画を動かす Orca（daemon-host。ウィンドウを持たない）
    (New-Proc 82 81 'pwsh.exe' 3)            # Orca の区画のシェル（持ち主のない PseudoConsoleWindow）
    (New-Proc 83 82 'claude.exe' 4)          # Orca の区画のセッション
    (New-Proc 84 82 'codex.exe' 5)           # Orca の区画の Codex
    (New-Proc 85 1 'Orca.exe' 1)             # ウィンドウが見えない Orca
    (New-Proc 86 85 'pwsh.exe' 2)
    (New-Proc 87 86 'claude.exe' 3)
    (New-Proc 88 89 'pwsh.exe' 3)            # 親が終わり、親の PID が、あとから起動した Orca に使い回された
    (New-Proc 89 1 'Orca.exe' 10)
    (New-Proc 90 88 'claude.exe' 4)
    (New-Proc 91 80 'pwsh.exe' 3)            # 持ち主が Orca のウィンドウの PseudoConsoleWindow
    (New-Proc 92 91 'claude.exe' 4)
    (New-Proc 95 80 'Code.exe' 2)            # Orca の区画から起動した VS Code
    (New-Proc 93 95 'pwsh.exe' 3)            # その VS Code のターミナルで、持ち主のない PseudoConsoleWindow
    (New-Proc 94 93 'claude.exe' 4)
)
$sessionWins = @(
    (New-ConsoleWin 104 'PseudoConsoleWindow' 4 -Visible $false -Owner 2002 -OwnerProcessId 2)
    (New-ConsoleWin 106 'PseudoConsoleWindow' 6 -Owner 8008 -OwnerProcessId 8)
    (New-ConsoleWin 1011 'ConsoleWindowClass' 11)
    (New-ConsoleWin 1020 'ConsoleWindowClass' 20)
    (New-ConsoleWin 1031 'ConsoleWindowClass' 31)
    (New-ConsoleWin 141 'PseudoConsoleWindow' 41 -Visible $false)
    (New-ConsoleWin 1042 'ConsoleWindowClass' 42)
    (New-ConsoleWin 1051 'ConsoleWindowClass' 51 -Visible $false)
    (New-ConsoleWin 160 'PseudoConsoleWindow' 60 -Visible $false -Owner 8009 -OwnerProcessId 8)
    (New-ConsoleWin 171 'PseudoConsoleWindow' 71 -Visible $false -Owner 8010 -OwnerProcessId 8 -OwnerVisible $false)
    (New-ConsoleWin 182 'PseudoConsoleWindow' 82 -Visible $false)
    (New-ConsoleWin 186 'PseudoConsoleWindow' 86 -Visible $false)
    (New-ConsoleWin 188 'PseudoConsoleWindow' 88 -Visible $false)
    (New-ConsoleWin 191 'PseudoConsoleWindow' 91 -Visible $false -Owner 8080 -OwnerProcessId 80)
    (New-ConsoleWin 193 'PseudoConsoleWindow' 93 -Visible $false)
)
# 見えるウィンドウを持つ Orca（Get-OrcaWindowList の形）。PID 85 の Orca はウィンドウが見えないので入らない
$sessionApps = @(
    [pscustomobject]@{ ProcessId = 80; Handle = [long]8080; Path = 'C:\Apps\orca\Orca.exe' }
    [pscustomobject]@{ ProcessId = 89; Handle = [long]8089; Path = 'C:\Apps\orca2\Orca.exe' }
)
function Format-SessionWindow { param($W) if ($null -eq $W) { return 'null' } return '{0}|{1}' -f $W.Handle, $W.IsCode }
function Format-OrcaWindow { param($W) if ($null -eq $W) { return 'null' } return '{0}|{1}|{2}' -f $W.Handle, $W.IsCode, $W.OrcaPath }
function Find-TestSessionWindow { param([int]$Id, [string]$Code = 'Code') return Format-SessionWindow (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id $Id -CodeProcessName $Code -AppWindows $sessionApps) }
function Find-TestOrcaWindow { param([int]$Id) return Format-OrcaWindow (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id $Id -AppWindows $sessionApps) }
Assert-Equal (Find-TestSessionWindow 5) '2002|True' 'VS Code の統合ターミナルのセッションは、そのターミナルを映している VS Code のウィンドウ（VS Code のもの）'
Assert-Equal (Find-TestSessionWindow 7) '8008|False' '親をたどると VS Code に着いても、Windows Terminal に映っていれば、その Windows Terminal のウィンドウ'
Assert-Equal (Find-TestSessionWindow 10) 'null' '拡張機能のパネルのセッション（VS Code が起動した）は、ターミナルのウィンドウを持たない'
Assert-Equal (Find-TestSessionWindow 12) '1011|False' 'conhost が描く cmd のウィンドウは、そのウィンドウ'
Assert-Equal (Find-TestSessionWindow 22) 'null' 'たどる途中で VS Code に着いたら、それより上（VS Code を起動した cmd のウィンドウ）はたどらない'
Assert-Equal (Find-TestSessionWindow 30) 'null' '子より後に起動した「親」（PID の使い回し）はたどらない'
Assert-Equal (Find-TestSessionWindow 40) 'null' '持ち主のない PseudoConsoleWindow では、映しているウィンドウが分からない（それより上の cmd のウィンドウもたどらない）'
Assert-Equal (Find-TestSessionWindow 50) 'null' '隠れたコンソールのウィンドウは前面に出さない'
Assert-Equal (Find-TestSessionWindow 60) '8009|False' 'セッションがコンソールを作ったときは、セッションのウィンドウの持ち主'
Assert-Equal (Find-TestSessionWindow 70) 'null' '持ち主のウィンドウが隠れていれば、前面に出さない'
Assert-Equal (Find-TestSessionWindow 99) 'null' '一覧にないプロセス（終わったセッション）は $null'
Assert-Equal (Find-TestSessionWindow 5 'Code - Insiders') '2002|False' 'VS Code かどうかは、見つけた VS Code のプロセス名で見分ける'
$kindEntry = [pscustomobject]@{ Key = '7'; Kind = 'background' }
Assert-Equal (Format-SessionWindow (Find-SessionWindow -Entry $kindEntry -Processes $sessionProcs -Windows $sessionWins)) 'null' 'background のセッションは、ターミナルのウィンドウを探さない（作業フォルダを VS Code で開く）'
$kindEntry.Kind = 'interactive'
Assert-Equal (Format-SessionWindow (Find-SessionWindow -Entry $kindEntry -Processes $sessionProcs -Windows $sessionWins)) '8008|False' '対話のセッションは、ターミナルのウィンドウを探す'
$kindEntry.Kind = ''
Assert-Equal (Format-SessionWindow (Find-SessionWindow -Entry $kindEntry -Processes $sessionProcs -Windows $sessionWins)) '8008|False' 'kind が分からなければ、対話のセッションとして探す'

Write-Host '== Orca の区画のセッションのウィンドウ（Find-OrcaWindow）'
Assert-Equal (Find-TestOrcaWindow 83) '8080|False|C:\Apps\orca\Orca.exe' 'Orca の区画のセッションは、区画を動かす Orca の親（ウィンドウを持つ Orca）のウィンドウ'
Assert-Equal (Find-TestOrcaWindow 84) '8080|False|C:\Apps\orca\Orca.exe' 'Orca の区画の Codex のプロセスからも、同じ Orca のウィンドウに着く'
Assert-Equal (Find-TestOrcaWindow 87) 'null' 'Orca のウィンドウが見えなければ、映しているウィンドウが分からない（VS Code で開く）'
Assert-Equal (Find-TestOrcaWindow 90) 'null' '子より後に起動した Orca（PID の使い回し）はたどらない'
Assert-Equal (Find-TestOrcaWindow 92) '8080|False|C:\Apps\orca\Orca.exe' '持ち主が Orca のウィンドウなら、そのウィンドウで、タブも選べるようにする'
Assert-Equal (Find-TestOrcaWindow 94) 'null' '持ち主のない PseudoConsoleWindow から Orca を探す途中で VS Code に着いたら、それより上（VS Code を起動した Orca）はたどらない'
Assert-Equal (Find-TestOrcaWindow 7) '8008|False|' 'Windows Terminal のセッションは、Orca として扱わない'
Assert-Equal (Format-OrcaWindow (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id 83)) 'null' 'Orca のウィンドウの一覧を渡さなければ（Orca が動いていなければ）、Orca の区画のセッションは見つからない'
Assert-Equal (Find-TestOrcaWindow 12) '1011|False|' 'conhost が描く cmd のウィンドウは、Orca として扱わない'

Write-Host '== ウィンドウを探す起点（Get-SessionWindowProcessId）と、Codex のセッションのウィンドウ'
Assert-Equal (Get-SessionWindowProcessId ([pscustomobject]@{ Key = '83'; Kind = 'interactive' })) 83 'Claude の対話のセッションは、セッションのプロセスから探す'
Assert-Equal (Get-SessionWindowProcessId ([pscustomobject]@{ Key = '83'; Kind = 'background' })) 0 'background のセッションは探さない'
$codexTerminal = [pscustomobject]@{ Key = 'codex:t'; Kind = 'codex'; HostPid = 84; HostStart = $t0.AddSeconds(5).ToUniversalTime().Ticks; HostKind = 'terminal' }
Assert-Equal (Get-SessionWindowProcessId $codexTerminal) 84 'ターミナルの中の Codex は、Codex のプロセスから探す（D-127）'
Assert-Equal (Format-OrcaWindow (Find-SessionWindow -Entry $codexTerminal -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps)) '8080|False|C:\Apps\orca\Orca.exe' 'Orca の区画の Codex は、Orca のウィンドウ'
$codexTerminal.HostPid = 7
$codexTerminal.HostStart = $t0.AddSeconds(6).ToUniversalTime().Ticks
Assert-Equal (Format-SessionWindow (Find-SessionWindow -Entry $codexTerminal -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps)) '8008|False' 'Orca の外のターミナルの Codex も、Claude と同じく、そのターミナルのウィンドウ（D-127）'
$codexTerminal.HostStart = $t0.AddSeconds(9).ToUniversalTime().Ticks
Assert-Equal (Find-SessionWindow -Entry $codexTerminal -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps) $null 'Codex のプロセスの起動時刻が記録と違えば（PID の使い回し）、探さない'
$codexTerminal.HostStart = [long]0
Assert-Equal (Format-SessionWindow (Find-SessionWindow -Entry $codexTerminal -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps)) '8008|False' '起動時刻が記録になければ、確かめずに探す'
$codexTerminal.HostPid = 999
$codexTerminal.HostStart = [long]1
Assert-Equal (Find-SessionWindow -Entry $codexTerminal -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps) $null 'Codex のプロセスが一覧になければ、探さない'
foreach ($hostKind in @('daemon', 'vscode', '')) {
    $codexOther = [pscustomobject]@{ Key = 'codex:d'; Kind = 'codex'; HostPid = 84; HostStart = [long]0; HostKind = $hostKind }
    Assert-Equal (Get-SessionWindowProcessId $codexOther) 0 "HostKind が「$hostKind」の Codex は、ウィンドウを探さない（作業フォルダを VS Code で開く）"
}
Assert-Equal (Get-SessionWindowProcessId ([pscustomobject]@{ Key = 'codex:z'; Kind = 'codex'; HostPid = 0; HostStart = [long]0; HostKind = 'terminal' })) 0 'Codex のプロセスが分からなければ、探さない'
# Orca の区画のセッションの見分け（Get-OrcaSessionKeys。D-136）
$alertWindows = @{
    '83' = (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id 83 -AppWindows $sessionApps)   # Orca の区画
    '7'  = (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id 7 -AppWindows $sessionApps)    # Windows Terminal
    '87' = $null                                                                                                        # ウィンドウが分からない
}
$orcaKeys = Get-OrcaSessionKeys -Windows $alertWindows
Assert-Equal (@($orcaKeys.Keys) -join ',') '83' 'Orca のウィンドウのセッションだけが、Orca のセッション'
Assert-Equal (Get-OrcaSessionKeys -Windows @{}).Count 0 'ウィンドウがなければ、Orca のセッションはない'
Assert-Equal (Get-OrcaSessionKeys -Windows $null).Count 0 'ウィンドウを調べられなければ、Orca のセッションはないとみなす（通知する）'
Assert-True ((Get-OrcaSessionKeys -Windows $null) -is [hashtable]) 'Orca のセッションがなくても、hashtable を返す'

Assert-Equal "$(Get-SessionAgent ([pscustomobject]@{ Kind = 'codex' }))|$(Get-SessionAgent ([pscustomobject]@{ Kind = 'interactive' }))|$(Get-SessionAgent ([pscustomobject]@{ Kind = '' }))" 'codex|claude|claude' 'Orca のターミナルのエージェントの種類は、Codex なら codex、それ以外は claude'

Write-Host '== Orca のターミナルの一覧（ConvertFrom-OrcaTerminalList）とタブの選び方（Select-OrcaTerminal）'
function New-OrcaTerminal {
    param([string]$Handle, [string]$Path, [string]$Agent = 'claude', [switch]$Orphaned)
    $o = [ordered]@{ handle = $Handle; worktreePath = $Path; orphaned = [bool]$Orphaned }
    if ($Agent) { $o.agentIdentity = $Agent }
    return [pscustomobject]$o
}
function ConvertTo-OrcaListJson { param([object[]]$Terminals, [bool]$Ok = $true, [bool]$Truncated = $false) return (ConvertTo-Json -Depth 5 ([ordered]@{ id = 'x'; ok = $Ok; result = [ordered]@{ terminals = @($Terminals); totalCount = @($Terminals).Count; truncated = $Truncated } })) }
$oneJson = ConvertTo-OrcaListJson @((New-OrcaTerminal 'term_a' 'C:/work/repo'))
$parsed = ConvertFrom-OrcaTerminalList $oneJson
Assert-Equal "$($parsed.Count)|$($parsed[0].handle)" '1|term_a' 'ターミナルが 1 つでも、一覧（配列）として読む'
Assert-Equal (ConvertFrom-OrcaTerminalList (ConvertTo-OrcaListJson @())).Count 0 'ターミナルがなければ空'
Assert-Equal (ConvertFrom-OrcaTerminalList ("warning: something`n" + $oneJson)).Count 1 'JSON の前に行が混ざっても読む'
Assert-Throws { ConvertFrom-OrcaTerminalList (ConvertTo-OrcaListJson @((New-OrcaTerminal 'term_a' 'C:/work/repo')) -Ok $false) } 'ok でなければ例外'
Assert-Throws { ConvertFrom-OrcaTerminalList (ConvertTo-OrcaListJson @((New-OrcaTerminal 'term_a' 'C:/work/repo')) -Truncated $true) } '一覧が切れていれば（truncated）例外（2 つ目が切れて 1 つに見えるおそれがあるので、タブを選ばない）'
Assert-Equal (ConvertFrom-OrcaTerminalList (ConvertTo-OrcaListJson @((New-OrcaTerminal 'term_a' 'C:/work/repo')) -Truncated $false)).Count 1 '一覧が切れていなければ（truncated が false）読む'
Assert-Throws { ConvertFrom-OrcaTerminalList 'Orca is not running' } 'JSON でなければ例外'
Assert-Throws { ConvertFrom-OrcaTerminalList '' } '空なら例外'

$orcaTerms = @(
    (New-OrcaTerminal 'term_repo' 'C:/work/repo')
    (New-OrcaTerminal 'term_repo_codex' 'C:/work/repo' -Agent 'codex')
    (New-OrcaTerminal 'term_repo_shell' 'C:/work/repo' -Agent '')
    (New-OrcaTerminal 'term_nested' 'C:/work/repo/.worktrees/b')
    (New-OrcaTerminal 'term_repo2' 'C:/work/repo2')
    (New-OrcaTerminal 'term_two_1' 'C:/work/two')
    (New-OrcaTerminal 'term_two_2' 'C:/work/two')
    (New-OrcaTerminal 'term_orphan' 'C:/work/orphan' -Orphaned)
    (New-OrcaTerminal 'term_case' 'c:/Work/Case/')
)
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\repo' -Agent 'claude') 'term_repo' '同じ worktree の Claude のターミナルが 1 つなら、そのタブ'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\repo\src\app' -Agent 'claude') 'term_repo' '作業フォルダが worktree の中のフォルダでも、その worktree のタブ'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\repo' -Agent 'codex') 'term_repo_codex' 'Codex のセッションは、Codex のターミナル'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\repo\.worktrees\b' -Agent 'claude') 'term_nested' 'worktree の中に worktree があれば、最も深い worktree のタブ'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\repo2' -Agent 'claude') 'term_repo2' '名前の前の部分が同じ別のフォルダ（repo と repo2）を取り違えない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\two' -Agent 'claude') $null '同じ worktree に Claude のターミナルが 2 つあれば、見分けられないので選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\orphan' -Agent 'claude') $null '区画のなくなったターミナル（orphaned）は選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\WORK\case\x' -Agent 'Claude') 'term_case' '/ と \、大文字・小文字、末尾の / を区別しない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\other' -Agent 'claude') $null '作業フォルダを含む worktree がなければ選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd 'C:\work\two' -Agent 'codex') $null '同じ種類のエージェントのターミナルがなければ選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals $orcaTerms -Cwd '' -Agent 'claude') $null '作業フォルダが分からなければ選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals @() -Cwd 'C:\work\repo' -Agent 'claude') $null 'ターミナルがなければ選ばない'
Assert-Equal (Select-OrcaTerminal -Terminals @((New-OrcaTerminal 'term_3864128f-65cf-40b7-abc1-77775e9f21fd' 'C:/work/h')) -Cwd 'C:\work\h' -Agent 'claude') 'term_3864128f-65cf-40b7-abc1-77775e9f21fd' 'Orca の handle の形（英数字と _ と -）は選ぶ'
Assert-Equal (Select-OrcaTerminal -Terminals @((New-OrcaTerminal 'term_" --x' 'C:/work/h')) -Cwd 'C:\work\h' -Agent 'claude') $null 'handle が英数字と _ . : - だけの形でなければ、CLI に渡さない'
Assert-Equal (Select-OrcaTerminal -Terminals @((New-OrcaTerminal '-x' 'C:/work/h')) -Cwd 'C:\work\h' -Agent 'claude') $null 'handle が - で始まれば（CLI の引数に見える）、渡さない'
Assert-Equal (Select-OrcaTerminal -Terminals @((New-OrcaTerminal 'term_ok' 'C:/work/h'), (New-OrcaTerminal 'bad handle' 'C:/work/h')) -Cwd 'C:\work\h' -Agent 'claude') $null '形の違う handle のターミナルも数える（残ったもう 1 つを選ばない）'

Write-Host '== Orca の CLI（Get-OrcaCliPath、New-OrcaCliStartInfo）'
$orcaTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-orca-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $orcaTmp 'resources\bin') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $orcaTmp 'resources\bin\orca.exe'), '')
    Assert-PathEqual (Get-OrcaCliPath -OrcaPath (Join-Path $orcaTmp 'Orca.exe')) (Join-Path $orcaTmp 'resources\bin\orca.exe') 'CLI は、Orca.exe と同じフォルダの resources\bin\orca.exe'
    Assert-Equal (Get-OrcaCliPath -OrcaPath (Join-Path $orcaTmp 'none\Orca.exe')) $null 'CLI がなければ $null（ウィンドウを前面に出すだけ）'
    Assert-Equal (Get-OrcaCliPath -OrcaPath '') $null 'Orca.exe のパスが分からなければ $null'
}
finally { Remove-Item -LiteralPath $orcaTmp -Recurse -Force -ErrorAction SilentlyContinue }
$env:ORCA_ANDON_TEST = '1'
try {
    $psi = New-OrcaCliStartInfo -Cli 'C:\Apps\orca\resources\bin\orca.exe' -Arguments @('terminal', 'switch', '--terminal', 'term_a', '--json')
    Assert-Equal $psi.Arguments '"terminal" "switch" "--terminal" "term_a" "--json"' 'CLI の引数は、1 つずつ引用して渡す'
    Assert-Equal "$($psi.UseShellExecute)|$($psi.CreateNoWindow)|$($psi.RedirectStandardOutput)" 'False|True|False' 'CLI はウィンドウを出さずに起動する。切り替えでは出力を受け取らない'
    Assert-Equal $psi.EnvironmentVariables.ContainsKey('ORCA_ANDON_TEST') $false 'andon を Orca の区画から起動していても、区画の環境変数（ORCA_ で始まるもの）を CLI に渡さない'
    Assert-True $psi.EnvironmentVariables.ContainsKey('PATH') 'ほかの環境変数は渡す'
    $psi = New-OrcaCliStartInfo -Cli 'C:\Apps\orca\resources\bin\orca.exe' -Arguments @('terminal', 'list', '--json') -Capture
    Assert-Equal "$($psi.RedirectStandardOutput)|$($psi.StandardOutputEncoding.WebName)" 'True|utf-8' '一覧は、標準出力を UTF-8 で受け取る'
}
finally { Remove-Item Env:\ORCA_ANDON_TEST -ErrorAction SilentlyContinue }
$orcaApps = $null
try { $orcaApps = @(Get-OrcaWindowList) } catch { Write-Host "       $($_.Exception.Message)" }
Assert-True ($null -ne $orcaApps) 'Orca のウィンドウの一覧を取れる（Orca が動いていなければ空）'

Write-Host '== コンソールのウィンドウの一覧（Get-ConsoleWindowList。C# の型を、この PowerShell で定義できるか）'
$consoleWins = $null
try { $consoleWins = @(Get-ConsoleWindowList) } catch { Write-Host "       $($_.Exception.Message)" }
Assert-True ($null -ne $consoleWins) 'コンソールのウィンドウの一覧を取れる（AndonSessionWindow を定義できる）'
Assert-Equal @($consoleWins | Where-Object { @('ConsoleWindowClass', 'PseudoConsoleWindow') -notcontains $_.ClassName }).Count 0 '一覧には、コンソールのウィンドウだけが入る'
$showResult = $null
try { $showResult = [AndonSessionWindow]::Show(0) } catch { }
Assert-Equal $showResult $false 'ないウィンドウは前面に出さない（false を返す）'

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
# スタートメニューとスタートアップのショートカットは、アップデートしても、それぞれ自分の引数を引き継ぐ
$withExtra = $launch.Arguments + ' -NoUpdateCheck -ScanMs 500'
Assert-Equal (Get-InheritedExtraArguments -Own $withExtra -Other $launch.Arguments) '-NoUpdateCheck -ScanMs 500' '自分のショートカットの引数を引き継ぐ（スタートアップの方にだけ付けた -NoUpdateCheck を消さない）'
Assert-Equal (Get-InheritedExtraArguments -Own $launch.Arguments -Other $withExtra) '' 'もう一方のショートカットの引数は足さない'
Assert-Equal (Get-InheritedExtraArguments -Own $null -Other $withExtra) '-NoUpdateCheck -ScanMs 500' '自分のショートカットがなければ（新しく作るとき）、もう一方の引数を使う'
Assert-Equal (Get-InheritedExtraArguments -Own $null -Other $null) '' 'どちらのショートカットもなければ空'
$installText = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw -Encoding UTF8
Assert-True ($installText -match '\$menuArguments = Get-ShortcutArguments -Path \$layout\.StartMenu\s+\$startupArguments = Get-ShortcutArguments -Path \$layout\.Startup') 'install.ps1 は、2 つのショートカットの引数を別々に読む'
Assert-True ($installText -match '\$launch = Get-AndonLaunch -InstallDir \$layout\.InstallDir -ExtraArguments \(Get-InheritedExtraArguments -Own \$menuArguments -Other \$startupArguments\)') 'スタートメニューのショートカットと、インストールしたあとの起動は、スタートメニューの引数を使う'
Assert-True ($installText -match '\$startupLaunch = Get-AndonLaunch -InstallDir \$layout\.InstallDir -ExtraArguments \(Get-InheritedExtraArguments -Own \$startupArguments -Other \$menuArguments\)') 'スタートアップのショートカットは、スタートアップの引数を使う'
Assert-True ($installText -match '''create'' \{ New-AndonShortcut -Path \$layout\.Startup -Launch \$startupLaunch \}') 'アップデートでスタートアップのショートカットを書き直すときは、スタートアップの引数を使う'

Assert-True (Test-AndonCommandLine -CommandLine 'powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\andon\andon.ps1') 'README の起動方法（相対パス）は andon'
Assert-True (Test-AndonCommandLine -CommandLine 'pwsh -File andon.ps1 -ScanMs 500') 'フォルダのない andon.ps1 も andon'
Assert-True (Test-AndonCommandLine -CommandLine '"C:\Program Files\PowerShell\7\pwsh.exe" -file "C:\My Apps\andon\ANDON.PS1"') '空白を含むパスと大文字小文字'
Assert-Equal (Test-AndonCommandLine -CommandLine 'powershell.exe -File C:\work\andon\tests\Test-Andon.ps1') $false 'テストのスクリプトは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine 'pwsh -Command "Get-Content .\andon.ps1"') $false 'andon.ps1 を読むだけのコマンドは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine 'powershell.exe -File C:\work\other.ps1 C:\work\andon\andon.ps1') $false 'andon.ps1 を引数に渡しただけのものは andon ではない'
Assert-Equal (Test-AndonCommandLine -CommandLine '') $false '起動引数が取れなければ andon ではない'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: スタートアップ'
Assert-Equal (Get-StartupAction -NoStartup $false -IsUpdate $false -Exists $false) 'none' '初めて入れるときは作らない（トレイのメニューの「ログオン時に起動」で作る）'
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

Write-Host '== VS Code がなくても起動する・セッションを映しているウィンドウを開く'
Assert-Equal ($andonText.Contains("MessageBox]::Show('VS Code の code.cmd")) $false 'VS Code（code.cmd）が見つからなくても起動する（メッセージを出して終わらない）'
Assert-True ($andonText.Contains("`$miOpen = `$menu.Items.Add('開く')")) '行の右クリックのメニューは「開く」（VS Code の外のセッションも開く）'
Assert-True ($andonText -match '(?s)function Open-Session \{.{0,900}?Find-SessionWindow -Entry \$Entry') 'セッションを開くときは、まずセッションを映しているウィンドウを探す'
Assert-True ($andonText -match '(?s)function Open-Session \{.{0,1500}?\[AndonSessionWindow\]::Show\(\[long\]\$window\.Handle\).{0,200}?if \(\$window\.OrcaPath\) \{\s+try \{ Start-OrcaTabSwitch') 'Orca のセッションは、先に Orca のウィンドウを前面に出してから、タブを切り替える（D-124）'
Assert-True ($andonText -match 'Find-SessionWindow -Entry \$e -CodeProcessName \$script:CodeProcessName -Processes \$procs -Windows \$wins -AppWindows \$apps') '点滅を始めるときも、Orca のウィンドウの一覧を渡す（Orca のセッションを見分ける）'
Assert-True ($andonText -match '(?m)^\s+catch \{ \$procs = \$null \}\r?\n(\s+#[^\r\n]*\r?\n)?\s+try \{ \$apps = @\(Get-OrcaWindowList\) \} catch \{ \$apps = @\(\) \}') '点滅を始めるとき、Orca のウィンドウを調べられなくても、ほかのターミナルのセッションの見分けに響かない'
Assert-True ($andonText -match '(?s)\$script:OrcaTimer\.Add_Tick\(\{\s+try \{ Update-OrcaTabSwitch') 'Orca の CLI は、timer で受け取る（andon の画面を止めない）'
Assert-True ($andonText -match '(?s)\$form\.Add_FormClosed\(\{.{0,200}?Stop-OrcaTabSwitch') '終了するとき、動いている Orca の CLI を止める'
Assert-True ($andonText -match '(?m)^try \{ Initialize-SessionWindowType \} catch \{ \}') '起動したときに、ウィンドウを探す型を定義しておく（初めてクリックしたときに待たせない）'
Assert-Equal ([regex]::Matches($andonText, '-ForegroundWindow \(\[AndonWindow\]::GetForegroundWindow\(\)\.ToInt64\(\)\)').Count) 2 '点滅を始めるときと止めるときに、前面のウィンドウも渡す（ターミナルのセッションを見分ける）'
Assert-True ($installText.Contains('注意: VS Code の code.cmd が見つかりません。andon は動きますが、クリックしても VS Code では開けません（cmd や PowerShell のウィンドウは前面に出せます）。')) 'install.ps1 は、VS Code がなくても andon が動くことを伝える'

# ---------------------------------------------------------------------------
Write-Host '== install.ps1: レジストリ'
# 本物のキーは使わず、テスト用のキーに作って消す
$regBase = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
try {
    $classes = Join-Path $regBase 'AppUserModelId'
    $notifications = Join-Path $regBase 'Notifications'
    $uninstallRoot = Join-Path $regBase 'Uninstall'
    $approved = Join-Path $regBase 'StartupApproved'
    $settingsRoot = Join-Path $regBase 'tbshiki'
    foreach ($k in @((Join-Path $classes 'tbshiki.andon'), (Join-Path $notifications 'tbshiki.andon'), (Join-Path $notifications 'andon'), (Join-Path $notifications 'example.other'), (Join-Path $uninstallRoot 'example.other'), $approved, (Join-Path $settingsRoot 'andon'))) {
        New-Item -Path $k -Force | Out-Null
    }
    New-ItemProperty -LiteralPath (Join-Path $settingsRoot 'andon') -Name 'Width' -PropertyType DWord -Value 640 | Out-Null

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
    # 本物の記録（StartupApproved\StartupFolder、Uninstall\tbshiki.andon、設定）を消さないよう、場所は必ず全部渡す
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey $approved -SettingsRoot $settingsRoot).Count 7 'アプリ ID の表示名、2 つの ID の通知の設定、「インストールされているアプリ」への登録、設定とその親（空なら）、スタートアップの有効・無効の記録を消す'
    Assert-Equal (Test-Path -LiteralPath $testKey) $false '「インストールされているアプリ」への登録を消した'
    Assert-Equal (Test-Path -LiteralPath $settingsRoot) $false '設定を消し、空になった親（tbshiki）も消した'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $uninstallRoot 'example.other')) $true 'ほかのアプリの登録は消さない'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $notifications 'example.other')) $true 'ほかのアプリの通知の設定は消さない'
    Assert-Equal ((Get-Item -LiteralPath $approved).GetValueNames() -join ',') 'other.lnk' 'ほかのショートカットの有効・無効の記録は消さない'
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey $approved -SettingsRoot $settingsRoot).Count 0 'なければ何もしない'
    Assert-Equal @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey (Join-Path $regBase 'NoSuchKey') -SettingsRoot (Join-Path $regBase 'NoSuchRoot')).Count 0 '記録の場所がなくても失敗しない'
    New-Item -Path (Join-Path $settingsRoot 'andon') -Force | Out-Null
    New-Item -Path (Join-Path $settingsRoot 'other') -Force | Out-Null
    $removedCount = -1   # 例外で止まらず、FAIL として数える
    try { $removedCount = @(Remove-AndonRegistry -ClassesRoot $classes -NotificationsRoot $notifications -UninstallRoot $uninstallRoot -StartupApprovedKey $approved -SettingsRoot $settingsRoot).Count } catch { }
    Assert-Equal $removedCount 1 '親（tbshiki）にほかのものがあれば、andon の設定だけを消す'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $settingsRoot 'other')) $true '親（tbshiki）のほかのものは消さない'
}
finally {
    if (Test-Path -LiteralPath $regBase) { Remove-Item -LiteralPath $regBase -Recurse -Force }
}

# ---------------------------------------------------------------------------
Write-Host '== andon.ps1: 設定（Read-AndonSettings / Write-AndonSettings）'
Assert-Equal (Get-AndonSettingsKey) 'HKCU:\Software\tbshiki\andon' '設定は HKCU\Software\tbshiki\andon に置く'
$settingsDefault = ((Get-Command Remove-AndonRegistry).ScriptBlock.Ast.Body.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'SettingsRoot' }).DefaultValue.Value
Assert-Equal (Join-Path $settingsDefault 'andon') (Get-AndonSettingsKey) 'アンインストールでは、andon が書くのと同じキーを消す'
foreach ($fn in 'Read-AndonSettings', 'Write-AndonSettings') {
    $keyParam = (Get-Command $fn).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Key' }
    Assert-True ($keyParam -and $null -eq $keyParam.DefaultValue) "$fn はキーの既定を持たない（テストが本物の設定に触れない）"
}
# 本物のキーは使わず、テスト用のキーで確かめる
$settingsBase = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
$settingsKey = Join-Path $settingsBase 'andon'
try {
    $s = Read-AndonSettings -Key $settingsKey
    Assert-Equal @(@($s.Left, $s.Top, $s.Width, $s.Height, $s.TopMost, $s.Vertical) | Where-Object { $null -ne $_ }).Count 0 'キーがなければ、どれも覚えていない（既定を使う）'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Left = -1500; Top = -200; Width = 700; Height = 300; TopMost = 0 })
    $s = Read-AndonSettings -Key $settingsKey
    Assert-Equal "$($s.Left),$($s.Top),$($s.Width),$($s.Height)" '-1500,-200,700,300' '書いた位置と大きさを読める（主画面の左や上の、マイナスの位置も）'
    Assert-Equal $s.TopMost $false '「常に手前」を外したことを覚える'
    Assert-Equal (Get-Item -LiteralPath $settingsKey).GetValueKind('Left').ToString() 'DWord' '値は DWORD で書く'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ TopMost = 1 })
    $s = Read-AndonSettings -Key $settingsKey
    Assert-True ($s.TopMost -eq $true -and $s.Width -eq 700) '一部だけ書いても、ほかの値は残る'

    Remove-ItemProperty -LiteralPath $settingsKey -Name 'Width'
    New-ItemProperty -LiteralPath $settingsKey -Name 'Width' -PropertyType String -Value '700' | Out-Null
    $s = Read-AndonSettings -Key $settingsKey
    Assert-Equal "$($s.Width),$($s.Height)" ',' 'DWORD でない大きさは使わない（大きさの組ごと既定にする）'
    Assert-Equal "$($s.Left),$($s.Top)" '-1500,-200' '大きさが読めなくても、位置は使う'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Width = 700 })
    Assert-Equal (Get-Item -LiteralPath $settingsKey).GetValueKind('Width').ToString() 'DWord' '型の違う値も、書き直すと DWORD になる'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Width = 50 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Width $null '小さすぎる大きさは使わない'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Width = 700; Left = 200000 })
    $s = Read-AndonSettings -Key $settingsKey
    Assert-True ($null -eq $s.Left -and $null -eq $s.Top -and $s.Width -eq 700) 'ありえない位置は使わない（位置の組ごと既定にする）'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ TopMost = 2 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).TopMost $null '「常に手前」が 0 か 1 でなければ使わない'

    # 縦表示（D-74）。0 か 1 の DWORD だけを使い、ほかは横表示（既定）にする
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Vertical = 1 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Vertical $true 'Vertical が 1 なら縦表示'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Vertical = 0 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Vertical $false 'Vertical が 0 なら横表示'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Vertical = 2 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Vertical $null 'Vertical が 0 か 1 でなければ使わない（横表示）'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ Vertical = -1 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Vertical $null 'Vertical がマイナスでも使わない'
    New-ItemProperty -LiteralPath $settingsKey -Name 'Vertical' -PropertyType String -Value '1' -Force | Out-Null
    Assert-Equal (Read-AndonSettings -Key $settingsKey).Vertical $null 'DWORD でない Vertical は使わない'

    # Orca のセッションも通知するか（D-136、D-140）。0 か 1 の DWORD だけを使い、ほかは既定（通知しない）にする
    Assert-Equal (Read-AndonSettings -Key $settingsKey).OrcaNotify $null 'OrcaNotify を覚えていなければ $null（通知しない）'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ OrcaNotify = 1 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).OrcaNotify $true 'OrcaNotify が 1 なら通知する'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ OrcaNotify = 0 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).OrcaNotify $false 'OrcaNotify が 0 なら通知しない'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ OrcaNotify = 2 })
    Assert-Equal (Read-AndonSettings -Key $settingsKey).OrcaNotify $null 'OrcaNotify が 0 か 1 でなければ使わない'
    New-ItemProperty -LiteralPath $settingsKey -Name 'OrcaNotify' -PropertyType String -Value '1' -Force | Out-Null
    Assert-Equal (Read-AndonSettings -Key $settingsKey).OrcaNotify $null 'DWORD でない OrcaNotify は使わない'

    # 選んだ Orca のペアリング先（D-141、D-149）。文字の値で、ID を ; で区切る。形の違うものは使わない
    Assert-Equal @((Read-AndonSettings -Key $settingsKey).OrcaRemote).Count 0 'OrcaRemote を覚えていなければ、どれも選んでいない'
    Write-AndonSettingText -Key $settingsKey -Name 'OrcaRemote' -Value 'env-1;bad id;env-2'
    Assert-Equal (@((Read-AndonSettings -Key $settingsKey).OrcaRemote) -join ',') 'env-1,env-2' 'OrcaRemote は、形の合う ID だけを読む'
    Write-AndonSettingText -Key $settingsKey -Name 'OrcaRemote' -Value ''
    Assert-Equal @((Read-AndonSettings -Key $settingsKey).OrcaRemote).Count 0 'OrcaRemote が空なら、どれも選んでいない'
    Write-AndonSettings -Key $settingsKey -Values ([ordered]@{ OrcaRemote = 1 })
    Assert-Equal @((Read-AndonSettings -Key $settingsKey).OrcaRemote).Count 0 '文字でない OrcaRemote は使わない'
}
finally {
    if (Test-Path -LiteralPath $settingsBase) { Remove-Item -LiteralPath $settingsBase -Recurse -Force }
}

Write-Host '== andon.ps1: ウィンドウの位置（Get-WindowPlacement）'
# 主画面と、その左に置いた画面（作業領域。タスクバーの分だけ高さが短い）
$primaryArea = [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1040 }
$leftArea = [pscustomobject]@{ Left = -1280; Top = 0; Width = 1280; Height = 984 }
$areas = @($primaryArea, $leftArea)
function Format-Placement { param($P) return '{0},{1},{2},{3}' -f $P.Left, $P.Top, $P.Width, $P.Height }
function New-Saved { param($Left, $Top, $Width, $Height) return [pscustomobject]@{ Left = $Left; Top = $Top; Width = $Width; Height = $Height; TopMost = $null } }
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '1256,763,656,269' '覚えていなければ、主画面の右下（端から 8）。これまでと同じ'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved $null -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '1256,763,656,269' '設定を読めなくても、主画面の右下'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved -Width 800 -Height 400) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '1112,632,800,400' '大きさだけ覚えていれば、その大きさで主画面の右下'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved -1000 100 600 300) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '-1000,100,600,300' '左の画面の中なら、そのまま戻す'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved 1700 500 600 300) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '1320,500,600,300' '右にはみ出していれば、画面の中に動かす'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved 100 -50 600 300) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '100,0,600,300' '上にはみ出していれば、画面の中に動かす'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved 3000 200 600 300) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '1320,200,600,300' 'どの画面とも重ならなければ（モニターを外したなど）、一番近い画面に収める'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved -400 100 600 300) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '-600,100,600,300' '2 つの画面にまたがっていれば、重なりの大きい画面に寄せる'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved -1280 0 2000 1200) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '-1280,0,1280,984' '画面より大きければ、画面に合わせて縮める'
Assert-Equal (Format-Placement (Get-WindowPlacement -Saved (New-Saved -Width 3000 -Height 2000) -Screens $areas -DefaultWidth 656 -DefaultHeight 269)) '0,0,1920,1040' '位置を覚えていなくても、主画面より大きければ縮める'

# ---------------------------------------------------------------------------
Write-Host '== andon.ps1: テーマ（Get-SystemAppsTheme / Resolve-AndonTheme / Get-ThemePalette）'
Assert-Equal ($script:ThemeChoices -join ',') 'System,Light,Dark' '設定の Theme は 0: Windows に合わせる、1: ライト、2: ダーク'
Assert-True ($andonText.Contains("'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'")) 'Windows のアプリ モードは Themes\Personalize から読む'
$themeBase = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
try {
    Assert-Equal (Get-SystemAppsTheme -Key $themeBase) 'Light' 'キーがなければ Light'
    New-Item -Path $themeBase -Force | Out-Null
    Assert-Equal (Get-SystemAppsTheme -Key $themeBase) 'Light' 'AppsUseLightTheme がなければ Light'
    New-ItemProperty -LiteralPath $themeBase -Name 'AppsUseLightTheme' -PropertyType DWord -Value 0 -Force | Out-Null
    Assert-Equal (Get-SystemAppsTheme -Key $themeBase) 'Dark' 'AppsUseLightTheme が 0 なら Dark'
    New-ItemProperty -LiteralPath $themeBase -Name 'AppsUseLightTheme' -PropertyType DWord -Value 1 -Force | Out-Null
    Assert-Equal (Get-SystemAppsTheme -Key $themeBase) 'Light' 'AppsUseLightTheme が 1 なら Light'
    Remove-ItemProperty -LiteralPath $themeBase -Name 'AppsUseLightTheme'
    New-ItemProperty -LiteralPath $themeBase -Name 'AppsUseLightTheme' -PropertyType String -Value '0' | Out-Null
    Assert-Equal (Get-SystemAppsTheme -Key $themeBase) 'Light' 'DWORD でなければ Light（読めないものとして扱う）'

    # テーマを覚える（設定のキーと同じ場所）
    $themeKey = Join-Path $themeBase 'andon'
    Assert-Equal (Read-AndonSettings -Key $themeKey).Theme $null 'テーマを覚えていなければ $null（Windows に合わせる）'
    foreach ($i in 0..2) {
        Write-AndonSettings -Key $themeKey -Values ([ordered]@{ Theme = $i })
        Assert-Equal (Read-AndonSettings -Key $themeKey).Theme $script:ThemeChoices[$i] "Theme が $i なら $($script:ThemeChoices[$i])"
    }
    Write-AndonSettings -Key $themeKey -Values ([ordered]@{ Theme = 3 })
    Assert-Equal (Read-AndonSettings -Key $themeKey).Theme $null 'Theme がありえない値なら $null（Windows に合わせる）'
    # PowerShell の配列は、-1 で最後の要素（Dark）を返してしまう
    Write-AndonSettings -Key $themeKey -Values ([ordered]@{ Theme = -1 })
    Assert-Equal (Read-AndonSettings -Key $themeKey).Theme $null 'Theme がマイナスなら $null（配列の後ろから読まない）'
}
finally {
    if (Test-Path -LiteralPath $themeBase) { Remove-Item -LiteralPath $themeBase -Recurse -Force }
}

Assert-Equal (Resolve-AndonTheme -Choice 'Light' -SystemTheme 'Dark') 'Light' 'ライトを選べば、Windows がダークでもライト'
Assert-Equal (Resolve-AndonTheme -Choice 'Dark' -SystemTheme 'Light') 'Dark' 'ダークを選べば、Windows がライトでもダーク'
Assert-Equal (Resolve-AndonTheme -Choice 'System' -SystemTheme 'Dark') 'Dark' 'Windows に合わせるなら、Windows のダークに従う'
Assert-Equal (Resolve-AndonTheme -Choice 'System' -SystemTheme 'Light') 'Light' 'Windows に合わせるなら、Windows のライトに従う'
Assert-Equal (Resolve-AndonTheme -Choice $null -SystemTheme 'Dark') 'Dark' '選んでいなければ（既定）、Windows に合わせる'

$light = Get-ThemePalette -Theme 'Light'
$dark = Get-ThemePalette -Theme 'Dark'
Assert-Equal ((Get-ThemePalette -Theme 'Other').Name) 'Light' '知らない名前ならライト'
Assert-Equal (@($light.PSObject.Properties.Name) -join ',') (@($dark.PSObject.Properties.Name) -join ',') 'ライトとダークは、同じ名前の色を持つ'
function Format-Rgb { param($Rgb) if ($null -eq $Rgb) { return 'default' } return ($Rgb -join ',') }
# ライトは、これまでの見た目と同じ（行の色、待機の灰色の字、状態の表示の DimGray。ほかは Windows の既定）
Assert-Equal ('{0}|{1}|{2}' -f (Format-Rgb $light.Rows[0].Back), (Format-Rgb $light.Rows[0].Fore), $light.Rows[0].Bold) '255,210,210|default|True' 'ライトの待ちの行は、これまでと同じ（薄い赤、太字）'
Assert-Equal ('{0}|{1}|{2}' -f (Format-Rgb $light.Rows[1].Back), (Format-Rgb $light.Rows[1].Fore), $light.Rows[1].Bold) '255,240,180|default|True' 'ライトの完了の行は、これまでと同じ（薄い黄、太字）'
Assert-Equal ('{0}|{1}|{2}' -f (Format-Rgb $light.Rows[2].Back), (Format-Rgb $light.Rows[2].Fore), $light.Rows[2].Bold) '228,248,230|default|False' 'ライトの実行中の行は、これまでと同じ（薄い緑、太字にしない。D-54）'
Assert-Equal ('{0}|{1}|{2}' -f (Format-Rgb $light.Rows[3].Back), (Format-Rgb $light.Rows[3].Fore), $light.Rows[3].Bold) 'default|128,128,128|False' 'ライトの待機の行は、これまでと同じ（灰色の字）'
Assert-Equal (Format-Rgb $light.SubText) '105,105,105' 'ライトの状態の表示は、これまでと同じ DimGray'
Assert-Equal (@('Back', 'Text', 'List', 'ListText', 'Header', 'Button', 'Menu') | Where-Object { $null -ne $light.$_ }).Count 0 'ライトのウィンドウとメニューは、Windows の既定のまま'
# ダークは、行の背景で状態を示す（D-72）。待ちと完了は太字、実行中は太字にしない（ライトと同じ）
Assert-Equal (@(0..3 | ForEach-Object { $dark.Rows[$_].Bold }) -join ',') (@(0..3 | ForEach-Object { $light.Rows[$_].Bold }) -join ',') 'ダークでも、太字にする行はライトと同じ'
Assert-Equal (@(0..2 | ForEach-Object { Format-Rgb $dark.Rows[$_].Back } | Sort-Object -Unique).Count) 3 'ダークの待ち・完了・実行中の行は、それぞれ違う背景'
foreach ($rank in 0..3) {
    $ratio = Get-ContrastRatio -Fore $dark.Rows[$rank].Fore -Back $dark.Rows[$rank].Back
    Assert-True ($ratio -ge 4.5) ("ダークの行（{0}）の字は読める（コントラスト比 {1:0.0} が 4.5 以上）" -f $rank, $ratio)
}
foreach ($pair in @(@('Text', 'Back'), @('ListText', 'List'), @('HeaderText', 'Header'), @('Text', 'Button'), @('MenuText', 'Menu'), @('MenuText', 'MenuSelected'), @('SubText', 'Back'))) {
    $ratio = Get-ContrastRatio -Fore $dark.($pair[0]) -Back $dark.($pair[1])
    Assert-True ($ratio -ge 4.5) ("ダークの {0} は {1} の上で読める（コントラスト比 {2:0.0} が 4.5 以上）" -f $pair[0], $pair[1], $ratio)
}
Assert-True ((Get-ContrastRatio -Fore $dark.MenuDisabled -Back $dark.Menu) -ge 3) 'ダークの選べないメニュー（版の表示）も、3 以上で読める'
foreach ($p in @($light, $dark)) {
    $colors = @(foreach ($prop in $p.PSObject.Properties) { if ($prop.Value -is [array]) { , $prop.Value } })
    $colors += @(foreach ($rank in 0..3) { foreach ($c in @($p.Rows[$rank].Back, $p.Rows[$rank].Fore, $p.Rows[$rank].Hover)) { if ($c) { , $c } } })
    Assert-Equal @($colors | Where-Object { $_.Count -ne 3 -or @($_ | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count -gt 0 }).Count 0 "$($p.Name) の色は、どれも 0〜255 の R, G, B"
}
Assert-Equal ('{0:0.00}' -f (Get-ContrastRatio -Fore @(0, 0, 0) -Back @(255, 255, 255))) '21.00' 'コントラスト比の計算: 黒と白は 21'

# 縦表示の色（D-77、D-78）。行の区切りの線と、マウスを乗せたときの背景
foreach ($p in @($light, $dark)) {
    Assert-Equal @(0..3 | Where-Object { $null -eq $p.Rows[$_].Hover }).Count 0 "$($p.Name) は、どの行にも、マウスを乗せたときの背景を持つ"
}
Assert-True ((Format-Rgb $light.RowLine) -ne '255,255,255') 'ライトの行の区切りの線は、一覧の地（白）と違う色'
Assert-True ((Format-Rgb $dark.RowLine) -ne (Format-Rgb $dark.List)) 'ダークの行の区切りの線は、一覧の地と違う色'
foreach ($rank in 0..3) {
    $back = $light.Rows[$rank].Back
    if (-not $back) { $back = @(255, 255, 255) }   # ライトの待機は、Windows の既定の地（白）
    $diff = @(0..2 | ForEach-Object { $back[$_] - $light.Rows[$rank].Hover[$_] })
    Assert-True (@($diff | Where-Object { $_ -lt 0 -or $_ -gt 32 }).Count -eq 0 -and @($diff | Where-Object { $_ -gt 0 }).Count -gt 0) "ライトの行（$rank）は、マウスを乗せると少し暗くなる（状態の色は残る）"
    $diff = @(0..2 | ForEach-Object { $dark.Rows[$rank].Hover[$_] - $dark.Rows[$rank].Back[$_] })
    Assert-True (@($diff | Where-Object { $_ -lt 0 -or $_ -gt 32 }).Count -eq 0 -and @($diff | Where-Object { $_ -gt 0 }).Count -gt 0) "ダークの行（$rank）は、マウスを乗せると少し明るくなる（状態の色は残る）"
    $ratio = Get-ContrastRatio -Fore $dark.Rows[$rank].Fore -Back $dark.Rows[$rank].Hover
    Assert-True ($ratio -ge 4.5) ("ダークの行（{0}）は、マウスを乗せても字が読める（コントラスト比 {1:0.0} が 4.5 以上）" -f $rank, $ratio)
}
foreach ($rank in 0..2) {
    # ライトの字は、Windows の既定（黒）
    $ratio = Get-ContrastRatio -Fore @(0, 0, 0) -Back $light.Rows[$rank].Hover
    Assert-True ($ratio -ge 4.5) ("ライトの行（{0}）は、マウスを乗せても字が読める（コントラスト比 {1:0.0} が 4.5 以上）" -f $rank, $ratio)
}
# ライトの待機は灰色の字で、もともとコントラスト比が 4.5 未満（これまでと同じ見た目）。マウスを乗せても 3 以上は保つ
$ratio = Get-ContrastRatio -Fore $light.Rows[3].Fore -Back $light.Rows[3].Hover
Assert-True ($ratio -ge 3) ("ライトの待機の行は、マウスを乗せても 3 以上で読める（コントラスト比 {0:0.0}）" -f $ratio)

# ---------------------------------------------------------------------------
Write-Host '== andon.ps1: 縦表示（Get-VerticalName / Get-VerticalRowHeight / Get-VerticalItemLayout）'
Assert-Equal (Get-VerticalName -Name 'api-refactor' -Cwd 'C:\work\backend') 'api-refactor' '中の段は、セッション名'
Assert-Equal (Get-VerticalName -Name '' -Cwd 'C:\work\backend') 'backend' '名前がなければ、フォルダの名前（cwd の最後のフォルダ。D-79）'
Assert-Equal (Get-VerticalName -Name '  ' -Cwd 'C:\work\backend') 'backend' '空白だけの名前は、ないものとして扱う'
Assert-Equal (Get-VerticalName -Name '' -Cwd 'C:\work\backend\') 'backend' 'cwd の末尾の区切りは無視する'
Assert-Equal (Get-VerticalName -Name '' -Cwd 'C:\') 'C:\' 'ドライブの直下で、フォルダの名前がなければ cwd のまま'
Assert-Equal (Get-VerticalName -Name '' -Cwd '\\server\share\proj') 'proj' '共有フォルダの中でも、最後のフォルダの名前'
Assert-Equal (Get-VerticalName -Name 'api-refactor' -Cwd '') 'api-refactor' 'フォルダがなくても、名前は出す'
Assert-Equal (Get-VerticalName -Name '' -Cwd '') '' 'どちらもなければ空'
$noticeEntry = [pscustomobject]@{ Key = '9'; Status = 'waiting'; Unread = $true; Name = ''; Cwd = 'C:\work\proj'; WaitingFor = ''; AlertAt = $t0 }
Assert-True ((Get-AlertNotice -Entries @($noticeEntry) -Now $t0).Text.EndsWith((Get-VerticalName -Name '' -Cwd 'C:\work\proj'))) '名前がないときの中の段は、通知の題と同じ（フォルダの名前）'
Assert-Equal (Get-VerticalRowHeight -LineHeight 15 -Padding 4) 53 '1 件の高さは、3 段の字と上下の余白'
function Format-Box { param($B) return '{0},{1},{2},{3}' -f $B.Left, $B.Top, $B.Width, $B.Height }
$layout = Get-VerticalItemLayout -Left 0 -Top 53 -Width 251 -LineHeight 15 -Padding 4 -ElapsedWidth 40 -Gap 8
Assert-Equal (Format-Box $layout.Status) '4,57,195,15' '上の段の状態は、余白の内側で、経過と間の分だけ狭める（重ならない）'
Assert-Equal (Format-Box $layout.Elapsed) '4,57,243,15' '経過は、上の段の幅いっぱいの場所に、右寄せで描く'
Assert-Equal (Format-Box $layout.Name) '4,72,243,15' '中の段（セッション名）は、上の段のすぐ下に、幅いっぱい'
Assert-Equal (Format-Box $layout.Folder) '4,87,243,15' '下の段（フォルダ）は、中の段のすぐ下に、幅いっぱい'
Assert-Equal ($layout.Folder.Top + $layout.Folder.Height + 4) (53 + (Get-VerticalRowHeight -LineHeight 15 -Padding 4)) '下の段は、1 件の高さの中に収まる'
Assert-Equal (Get-VerticalItemLayout -Left 0 -Top 0 -Width 251 -LineHeight 15 -Padding 4 -ElapsedWidth 0 -Gap 8).Status.Width 243 '経過がなければ、状態は幅いっぱい'
$narrow = Get-VerticalItemLayout -Left 0 -Top 0 -Width 30 -LineHeight 15 -Padding 4 -ElapsedWidth 40 -Gap 8
Assert-Equal "$($narrow.Status.Width),$($narrow.Name.Width),$($narrow.Folder.Width)" '0,22,22' '経過より狭くても、状態の幅はマイナスにしない'
$tiny = Get-VerticalItemLayout -Left 0 -Top 0 -Width 5 -LineHeight 15 -Padding 4 -ElapsedWidth 0 -Gap 8
Assert-Equal "$($tiny.Status.Width),$($tiny.Elapsed.Width),$($tiny.Name.Width),$($tiny.Folder.Width)" '0,0,0,0' '余白より狭ければ、どれも 0'

# 縦の一覧は GUI の部分（ドットソースの境界より後ろ）で作るので、つなぎ方を本文で確かめる
Assert-True ($andonText -match '\$lvV\.Activation = ''OneClick''') '縦の一覧も、1 回のクリックで開く（Activation = OneClick）'
Assert-True ($andonText -match '\$lvV\.Add_ItemActivate\(') '縦の一覧も、行のクリックでセッションを開く（ItemActivate）'
Assert-True ($andonText -match '\$lvV\.ContextMenuStrip = \$menu') '縦の一覧も、右クリックのメニューを出す'
Assert-True ($andonText -match 'if \(\$script:Vertical\) \{ \$name = Get-VerticalName ') '縦の一覧の中の段は、Get-VerticalName で作る（名前がなければフォルダの名前）'
Assert-True ($andonText -match '\$lvV\.BeginInvoke\(\[Action\] \{ Update-VerticalColumn \}\)') '縦の一覧の列は、一覧が大きさを変え終えてから合わせる（途中で変えると、横のスクロールバーが残る）'
Assert-True ($andonText -match '\$lvV\.GetType\(\)\.GetProperty\(''DoubleBuffered''') '縦の一覧は二重バッファで描く（マウスを乗せた行を描き直すときに、ちらつかない）'
Assert-True ($andonText -match '(?s)\$form\.Add_Layout\(\{.{0,600}?\$lvV\.Columns\[0\]\.Width = \$target') 'ウィンドウの幅を縮めるときは、一覧が縮む前に列を縮める（横のスクロールバーが一瞬出ない）'
# ListView は DoubleBuffered を受け持ち、LVS_EX_DOUBLEBUFFER として一覧に渡す（リフレクションで立てる先がある）
Add-Type -AssemblyName System.Windows.Forms
$dbProp = [System.Windows.Forms.ListView].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance, NonPublic')
Assert-True ($dbProp -and $dbProp.DeclaringType -eq [System.Windows.Forms.ListView]) 'ListView は DoubleBuffered を自分で受け持つ（二重バッファを一覧に渡す）'
Assert-True ($andonText -match 'Set-ThemeColors -Control \$lvV ') 'テーマを変えると、縦の一覧も塗る'
Assert-True ($andonText -match '\[AndonThemeNative\]::SetTheme\(\$lvV\.Handle') 'ダークでは、縦の一覧のスクロールバーも暗くする'
$subItemHandler = [regex]::Match($andonText, '\$lvV\.Add_DrawSubItem\(\{[^}]*\}\)')
Assert-True ($subItemHandler.Success -and $subItemHandler.Value -notmatch 'DrawDefault') '縦の一覧の列は、Windows に描かせない（描いた行の上に描かれないように）'
$verticalAst = $andonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-VerticalItem' }, $true)
Assert-True ($verticalAst -and $verticalAst.Extent.Text.Contains('PathEllipsis')) '下の段は、フォルダの途中を省略して最後のフォルダ名を残す（PathEllipsis。D-75）'
$themeAdd = $andonText.IndexOf('$trayMenu.Items.Add($miTheme)')
$verticalAdd = $andonText.IndexOf('$trayMenu.Items.Add($miVertical)')
$exitAdd = $andonText.IndexOf('$trayMenu.Items.Add(''終了'')')
Assert-True ($themeAdd -ge 0 -and $verticalAdd -gt $themeAdd -and $exitAdd -gt $verticalAdd) 'トレイのメニューの「縦表示」は、「テーマ」の下、「終了」の上（D-40）'

Write-Host '== andon.ps1: Orca のセッションの通知（D-136、D-137、D-140）'
$orcaNotifyAdd = $andonText.IndexOf('$trayMenu.Items.Add($miOrcaNotify)')
$codexAdd = $andonText.IndexOf('$trayMenu.Items.Add($miCodex)')
Assert-True ($codexAdd -ge 0 -and $orcaNotifyAdd -gt $codexAdd -and $themeAdd -gt $orcaNotifyAdd) 'トレイのメニューの「Orca のセッションも通知する」は、「Codex の状態を出す」の下、「テーマ」の上'
Assert-True ($andonText.Contains('$script:OrcaNotify = $script:Settings.OrcaNotify -eq $true')) '覚えていなければ、Orca のセッションは通知しない（既定）'
$alertAst = $andonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Alert' }, $true)
Assert-True ($alertAst -and $alertAst.Extent.Text -match 'if \(-not \$script:OrcaNotify\) \{ \$quiet = Get-OrcaSessionKeys -Windows \$windows -Entries \$hits \}') '通知しない設定のときだけ、Orca のセッション（区画とリモート）を通知から外す'

Write-Host '== andon.ps1: Orca のリモートのセッションを画面に繋ぐ（D-141、D-145、D-147、D-149）'
function Get-AndonFunctionText { param([string]$Name) $f = $andonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }.GetNewClosure(), $true); if ($f) { return $f.Extent.Text }; return '' }
Assert-True ($andonText.Contains('$script:OrcaRemoteIds = @($script:Settings.OrcaRemote)')) '読むペアリング先は、設定に覚えたものだけ（既定は、どれも選んでいない）'
$remoteAdd = $andonText.IndexOf('$trayMenu.Items.Add($miOrcaRemote)')
Assert-True ($orcaNotifyAdd -ge 0 -and $remoteAdd -gt $orcaNotifyAdd -and $themeAdd -gt $remoteAdd) 'トレイのメニューの「Orca のリモートを出す」は、「Orca のセッションも通知する」の下、「テーマ」の上'
$startRemote = Get-AndonFunctionText 'Start-OrcaRemotePoll'
Assert-True ($startRemote.Contains("@('worktree', 'ps', '--environment', `$EnvId, '--limit', [string]`$script:OrcaRemoteLimit, '--json')") -and $andonText.Contains('$script:OrcaRemoteLimit = 500') -and $startRemote.Contains('Test-OrcaId $EnvId')) 'ペアリング先は、形を確かめた ID で指定して読む'
Assert-True ($startRemote.Contains('Get-OrcaCliPath -OrcaPath $app.Path') -and $startRemote.Contains('New-OrcaCliStartInfo')) 'CLI は、動いている Orca と同じフォルダのものを、ORCA_ の環境変数を渡さずに起動する'
Assert-True (-not $andonText.Contains("@('open'")) 'andon からは Orca を起動しない（orca open を使わない）'
$updateRemote = Get-AndonFunctionText 'Update-OrcaRemote'
Assert-True ($updateRemote.Contains('Get-OrcaRemoteStep') -and $updateRemote -match "'clear' \{\s*Stop-OrcaRemotePoll") '今の回にすることは Get-OrcaRemoteStep で決め、Orca が動いていなければ CLI を止める'
Assert-True ($updateRemote.Contains('Get-OrcaRemoteInterval -Sessions $sessions') -and $updateRemote.Contains('Set-OrcaRemoteFailed')) '次に読む時刻は、読めたら Get-OrcaRemoteInterval、読めなければ Set-OrcaRemoteFailed で決める'
$failRemote = Get-AndonFunctionText 'Set-OrcaRemoteFailed'
Assert-True ($failRemote.Contains('Get-OrcaRemoteInterval -Failed') -and $failRemote.Contains('-ge $script:OrcaRemoteFailLimit) { return (Clear-OrcaRemoteState -EnvId $EnvId) }')) '読めなかったら間隔をあけ、続けて読めなかったときだけ、そのペアリング先のセッションを消す'
Assert-True ($andonText.Contains('$script:OrcaRemoteFailLimit = 3')) '続けて 3 回読めなければ消す'
Assert-True ($updateRemote.Contains('($dueNow -and -not $script:OrcaRemotePoll -and @($script:OrcaRemoteApps).Count -gt 0)')) 'Orca が動いていないあいだは、Orca を探すのを 10 秒ごとに抑える'
$openSession = Get-AndonFunctionText 'Open-Session'
Assert-True ($openSession.Contains('{ Open-OrcaRemoteSession -Entry $Entry; return }')) 'リモートのセッションは、VS Code では開かず、Orca を開く'
$openRemote = Get-AndonFunctionText 'Open-OrcaRemoteSession'
Assert-True ($openRemote.Contains('-Environment $Entry.Remote.EnvId -PaneKey $Entry.Remote.PaneKey') -and $openRemote -notmatch 'Start-VSCode|Find-VSCodeTarget') 'リモートのセッションのタブは、ペアリング先と区画で選ぶ'
$startSwitch = Get-AndonFunctionText 'Start-OrcaTabSwitch'
Assert-True ($startSwitch.Contains("@('terminal', 'list', '--environment', `$Environment, '--json')") -and $startSwitch.Contains('Test-OrcaId $Environment) -or -not (Test-OrcaId $PaneKey)')) 'リモートのタブの一覧は、形を確かめたペアリング先の ID で取る'
$updateSwitch = Get-AndonFunctionText 'Update-OrcaTabSwitch'
Assert-True ($updateSwitch.Contains('Select-OrcaTerminalByPane -Terminals $terminals -PaneKey $s.PaneKey') -and $updateSwitch.Contains("'--terminal', `$handle, '--environment', `$s.Environment, '--json'")) 'リモートのタブは区画で選び、そのペアリング先に向けて切り替える'
Assert-True ((Get-AndonFunctionText 'Update-ListView').Contains('SubItems.Add((Get-EntryFolder $e))')) '一覧の「フォルダ」は Get-EntryFolder（リモートは、ペアリング先の名前を前に付ける）'
Assert-True ((Get-AndonFunctionText 'Get-AlertWindows') -match '(?s)if \(Test-OrcaKey .{0,300}OrcaPath = \[string\]\$app.Path') 'リモートのセッションの点滅は、この PC の Orca のウィンドウで見分ける'
Assert-True ($andonText -match '(?s)\$remote = Update-OrcaRemote -Now \$now.{0,400}catch \{ try \{ Stop-OrcaRemotePoll \} catch \{ \} \}') 'リモートを読む処理が失敗しても、ほかのセッションの表示は続ける'
Assert-True ($andonText -match '(?s)\$form.Add_FormClosed\(\{.{0,300}Stop-OrcaRemotePoll') '終了するときに、リモートを読んでいる CLI を止める'
$remoteClick = [regex]::Match($andonText, '(?s)\$miOrcaRemote.Add_DropDownOpening\(\{.*?\r?\n    \}\)').Value
Assert-True ($remoteClick.Contains('MessageBoxButtons]::YesNo') -and $remoteClick.Contains('MessageBoxDefaultButton]::Button2') -and $remoteClick.Contains('if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }')) 'ペアリング先を選ぶときは、通信することを示して確かめる（初めから選ばれているのは「いいえ」）'

$dueNext = @{ 'a' = $t0.AddSeconds(30); 'b' = $t0.AddSeconds(10) }
Assert-Equal "$((Get-OrcaRemoteDue -Ids @('a', 'b') -Next $dueNext).Id)|$((Get-OrcaRemoteDue -Ids @('a', 'b') -Next $dueNext).At -eq $t0.AddSeconds(10))" 'b|True' '次に読むのは、読む時刻が一番早いペアリング先'
Assert-Equal "$((Get-OrcaRemoteDue -Ids @('a', 'c', 'b') -Next $dueNext).Id)|$($null -eq (Get-OrcaRemoteDue -Ids @('a', 'c', 'b') -Next $dueNext).At)" 'c|True' '読む時刻が決まっていないペアリング先を先に読む'
Assert-Equal "$($null -eq (Get-OrcaRemoteDue -Ids @() -Next $dueNext))|$((Get-OrcaRemoteDue -Ids @('a') -Next $null).Id)" 'True|a' '選んだものがなければ $null。時刻の表がなければ、最初のもの'
Assert-True ($alertAst -and $alertAst.Extent.Text -match 'Start-Flash -Hits \$hits -Windows \$windows' -and $alertAst.Extent.Text -notmatch 'Start-Flash[^\r\n]*quiet') '点滅は、Orca のセッションでも変えない（D-137）'
Assert-True ($alertAst -and $alertAst.Extent.Text -match 'Get-AlertNotice -Entries \$hits -Now \$Now -Quiet \$quiet') '通知は、外したセッションを除いて作る'

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

    Write-Host '== andon.ps1: ログオン時に起動（トレイのメニュー）'
    $logonLayout = Get-LogonStartupLayout
    $installLayout = Get-AndonLayout
    Assert-PathEqual $logonLayout.InstallDir $installLayout.InstallDir 'インストール先は install.ps1 と同じ'
    Assert-PathEqual $logonLayout.StartMenu $installLayout.StartMenu 'スタートメニューのショートカットは install.ps1 と同じ'
    Assert-PathEqual $logonLayout.Startup $installLayout.Startup 'スタートアップのショートカットは install.ps1 と同じ'
    $approvedDefault = ((Get-Command Remove-AndonRegistry).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'StartupApprovedKey' }).DefaultValue.Value
    Assert-Equal $logonLayout.ApprovedKey $approvedDefault 'タスク マネージャーの記録は、アンインストールで消すのと同じキー'
    foreach ($fn in 'Set-LogonStartup', 'Get-LogonStartup', 'Test-LogonStartupDisabled') {
        $defaults = @((Get-Command $fn).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.DefaultValue })
        Assert-Equal $defaults.Count 0 "$fn は場所の既定を持たない（テストが本物のスタートアップとレジストリに触れない）"
    }

    # 本物のスタートアップとキーは使わず、テスト用の場所で確かめる
    $menuLnk = Join-Path $installTmp 'menu\andon.lnk'
    $startLnk = Join-Path $installTmp 'startup\andon.lnk'
    $logonKey = 'HKCU:\Software\andon-test-' + [guid]::NewGuid().ToString('N')
    $disabled = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    $enabled = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    try {
        New-AndonShortcut -Path $menuLnk -Launch (Get-AndonLaunch -InstallDir $dst -ExtraArguments '-ScanMs 500')
        Assert-True (Test-LogonStartupAvailable -ScriptDir $dst -InstallDir $dst -StartMenu $menuLnk) 'インストール先の andon なら出す'
        Assert-True (Test-LogonStartupAvailable -ScriptDir ($dst + '\') -InstallDir $dst.ToUpperInvariant() -StartMenu $menuLnk) '末尾の区切りと大文字小文字は問わない'
        Assert-Equal (Test-LogonStartupAvailable -ScriptDir $src -InstallDir $dst -StartMenu $menuLnk) $false 'clone など、インストール先でない andon では出さない'
        Assert-Equal (Test-LogonStartupAvailable -ScriptDir $dst -InstallDir $dst -StartMenu (Join-Path $installTmp 'menu\none.lnk')) $false 'スタートメニューのショートカットがなければ出さない'
        Assert-Equal (Test-LogonStartupAvailable -ScriptDir $dst -InstallDir $dst -StartMenu $other) $false 'スタートメニューのショートカットが andon を起動しなければ出さない'

        Assert-Equal (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) $false 'ショートカットがなければ、チェックしない'
        Set-LogonStartup -Enabled $true -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-Equal (Get-ShortcutArguments -Path $startLnk) (Get-ShortcutArguments -Path $menuLnk) '入れると、スタートメニューのショートカットを写す（末尾の引数も揃う）'
        Assert-True (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) '入れたら、チェックする'

        New-Item -Path $logonKey -Force | Out-Null
        New-ItemProperty -LiteralPath $logonKey -Name 'andon.lnk' -PropertyType Binary -Value $disabled -Force | Out-Null
        New-ItemProperty -LiteralPath $logonKey -Name 'other.lnk' -PropertyType Binary -Value $disabled -Force | Out-Null
        Assert-Equal (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) $false 'タスク マネージャーで無効にしてあれば、チェックしない'
        Set-LogonStartup -Enabled $true -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-True (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) '入れ直すと、無効の記録を消して有効に戻す'
        Assert-Equal ((Get-Item -LiteralPath $logonKey).GetValueNames() -join ',') 'other.lnk' 'ほかのショートカットの記録は消さない'

        New-ItemProperty -LiteralPath $logonKey -Name 'andon.lnk' -PropertyType Binary -Value $enabled -Force | Out-Null
        Set-LogonStartup -Enabled $false -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-Equal (Test-Path -LiteralPath $startLnk) $false '外すと、ショートカットを消す'
        Assert-Equal ((Get-Item -LiteralPath $logonKey).GetValueNames() -join ',') 'other.lnk' '外すと、有効・無効の記録も消す'
        Assert-Equal (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) $false '外したら、チェックしない'
        Set-LogonStartup -Enabled $false -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-Equal (Test-Path -LiteralPath $startLnk) $false 'ないときに外しても失敗しない'

        # Windows は、ショートカットを消しても記録を残す。前に無効にした記録が残っていても、入れたら有効にする
        New-ItemProperty -LiteralPath $logonKey -Name 'andon.lnk' -PropertyType Binary -Value $disabled -Force | Out-Null
        Set-LogonStartup -Enabled $true -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-True (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) 'ショートカットを作るとき、残っていた無効の記録を消す'

        # 同じ名前でも、andon を起動しないショートカットは andon のものとして扱わない
        Remove-Item -LiteralPath $startLnk -Force
        Copy-Item -LiteralPath $other -Destination $startLnk
        New-ItemProperty -LiteralPath $logonKey -Name 'andon.lnk' -PropertyType Binary -Value $disabled -Force | Out-Null
        Assert-Equal (Get-LogonStartup -Startup $startLnk -ApprovedKey $logonKey) $false 'andon を起動しない andon.lnk なら、チェックしない'
        Set-LogonStartup -Enabled $false -StartMenu $menuLnk -Startup $startLnk -ApprovedKey $logonKey
        Assert-True (Test-Path -LiteralPath $startLnk) '外しても、andon を起動しない andon.lnk は消さない'
        Assert-True ((Get-Item -LiteralPath $logonKey).GetValueNames() -contains 'andon.lnk') '外しても、andon を起動しない andon.lnk の記録には触れない'

        Remove-Item -LiteralPath $startLnk -Force
        Assert-Throws { Set-LogonStartup -Enabled $true -StartMenu (Join-Path $installTmp 'menu\none.lnk') -Startup $startLnk -ApprovedKey $logonKey } 'スタートメニューのショートカットがなければ、入れられない（例外にする）'
        Assert-Equal (Test-Path -LiteralPath $startLnk) $false '入れられなかったときは、何も作らない'
    }
    finally {
        if (Test-Path -LiteralPath $logonKey) { Remove-Item -LiteralPath $logonKey -Recurse -Force }
    }

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
    Assert-True ($cmdText.Contains('set "ANDON_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"')) 'install.cmd は Windows PowerShell 5.1 を絶対パスで起動する'
    Assert-True ($cmdText.Contains('if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ANDON_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"')) 'install.cmd は、32 ビットの cmd.exe で動いたときは、64 ビットの PowerShell（Sysnative）を起動する'
    Assert-True ($cmdText.Contains('"%ANDON_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"')) 'install.cmd は、隣の install.ps1 を引用符で囲んで渡す'
    Assert-Equal ([regex]::IsMatch($cmdText, '(?im)^\s*(rem|::).*%')) $false 'install.cmd の注釈に % を書かない（rem の行も % を展開する）'
    $readmeTxt = Get-Content -LiteralPath (Join-Path $root 'README.txt') -Raw -Encoding UTF8
    Assert-Equal ([regex]::IsMatch($readmeTxt, '入れ|入る|入り')) $false 'README.txt は「入れる」ではなく「インストール」「アップデート」と書く'
    $removeCalls = @([regex]::Matches((Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8), '(?m)^(?!\s*#).*\bRemove-AndonRegistry\s+-.*$') | ForEach-Object { $_.Value })
    # 場所の引数は、関数の定義から取る（引数を足したときに、ここを直し忘れても漏れない）
    $removeParams = @((Get-Command Remove-AndonRegistry).ScriptBlock.Ast.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-True ($removeParams.Count -ge 5) 'Remove-AndonRegistry の場所の引数を読めた'
    foreach ($param in $removeParams) {
        Assert-True ($removeCalls.Count -gt 0 -and @($removeCalls | Where-Object { $_ -notmatch ('-' + $param + '\s') }).Count -eq 0) "テストは Remove-AndonRegistry に必ず -$param を渡す（本物の登録や設定を消さない）"
    }
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

    # 32 ビットのプログラム（アーカイバなど）から開くと、32 ビットの cmd.exe で動く。32 ビットの PowerShell からは
    # System32\conhost.exe が見えずインストールできないので、そのときも 64 ビットの PowerShell で install.ps1 を実行する
    $wowCmd = Join-Path $env:SystemRoot 'SysWOW64\cmd.exe'
    if (-not [Environment]::Is64BitOperatingSystem -or -not (Test-Path -LiteralPath $wowCmd)) {
        Write-Host '[SKIP] 64 ビットの Windows でないので、32 ビットの cmd.exe から開く場合を確かめられない'
    }
    else {
        $wowDir = Join-Path $installTmp 'cmd-wow64\a b&c'
        New-Item -ItemType Directory -Path $wowDir -Force | Out-Null
        Copy-Item -LiteralPath $cmdSource -Destination $wowDir
        [IO.File]::WriteAllText((Join-Path $wowDir 'install.ps1'), "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'ran.txt'), [string][Environment]::Is64BitProcess)`r`nexit 0`r`n", (New-Object Text.UTF8Encoding($true)))
        $t = Start-TestProcess -FilePath $wowCmd -Arguments ('/c ""' + (Join-Path $wowDir 'install.cmd') + '""')
        try {
            $before = $t.Process.WaitForExit(30000)
            Assert-True ($before -and (Stop-TestProcess $t)) '32 ビットの cmd.exe から開いても、成功したら閉じる'
            if ($before) { Assert-Equal $t.Process.ExitCode 0 '32 ビットの cmd.exe から開いても、成功したら終了コード 0' }
        }
        finally { $t.Process.Dispose() }
        $ran = Join-Path $wowDir 'ran.txt'
        $ranText = ''
        if (Test-Path -LiteralPath $ran) { $ranText = [IO.File]::ReadAllText($ran) }
        Assert-Equal $ranText 'True' '32 ビットの cmd.exe から開いても、install.ps1 は 64 ビットの PowerShell で動く'
    }

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

    Write-Host '== install.ps1: 32 ビットの PowerShell'
    # 64 ビットの Windows の 32 ビットの PowerShell からは System32\conhost.exe が見えないので、理由を出して終わる。
    # 上と同じく、隣に andon.ps1 がないフォルダで動かす（確かめが外れても、実際の場所に触れる前に失敗して終わる）
    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [Environment]::Is64BitOperatingSystem -or -not (Test-Path -LiteralPath $ps32)) {
        Write-Host '[SKIP] 64 ビットの Windows でないので、32 ビットの PowerShell の場合を確かめられない'
    }
    else {
        $t = Start-TestProcess -FilePath $ps32 -Arguments $lonelyArgs -Environment $lonelyEnv
        try {
            $before = $t.Process.WaitForExit(30000)
            Assert-True ($before -and (Stop-TestProcess $t)) '32 ビットの PowerShell なら、キーを待たずに閉じる'
            if ($before) { Assert-Equal $t.Process.ExitCode 1 '32 ビットの PowerShell なら、終了コード 1' }
            Assert-True ((Get-TestOutput $t) -match 'SysWOW64') '32 ビットの PowerShell なら、その場所を示して、インストールできない理由を出す'
        }
        finally { $t.Process.Dispose() }
    }
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
    # andon と同じく、起動したときの Process.StartTime を渡すとき（子の起動時刻は WMI から取るので、2 つの時刻の基準が
    # 揃っていないと、子孫を止めなくなる）と、渡さずに、動いている相手の起動時刻を調べるとき
    foreach ($passStart in @($true, $false)) {
        $how = '起動時刻を渡さないとき'
        if ($passStart) { $how = '起動時刻を渡したとき' }
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
        Assert-True $child "子プロセスが起動した（$how）"
        if ($passStart) { Stop-ProcessTree -Id $parentProc.Id -StartTime $parentProc.StartTime }
        else { Stop-ProcessTree -Id $parentProc.Id }
        Assert-True ($parentProc.WaitForExit(5000)) "親プロセスを止める（$how）"
        if ($child) {
            $childGone = $false
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $childGone -and (Get-Date) -lt $deadline) {
                $childGone = -not (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue)
                if (-not $childGone) { Start-Sleep -Milliseconds 200 }
            }
            Assert-True $childGone "子孫のプロセスも止める（$how）"
        }
        $parentProc.Dispose()
    }

    Write-Host '== Get-ProcessDescendant（親の PID の使い回し）'
    $t0 = [datetime]'2026-01-01T12:00:00'
    $procs = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; CreationDate = $t0 }                     # 止める相手
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; CreationDate = $t0.AddSeconds(1) }    # 子
        [pscustomobject]@{ ProcessId = 300; ParentProcessId = 200; CreationDate = $t0.AddSeconds(2) }    # 孫
        [pscustomobject]@{ ProcessId = 400; ParentProcessId = 100; CreationDate = $t0.AddSeconds(-10) }  # 前に同じ PID だったプロセスの子
        [pscustomobject]@{ ProcessId = 500; ParentProcessId = 400; CreationDate = $t0.AddSeconds(-5) }   # その子
        [pscustomobject]@{ ProcessId = 600; ParentProcessId = 1; CreationDate = $t0.AddSeconds(3) }      # 無関係
        [pscustomobject]@{ ProcessId = 700; ParentProcessId = 100; CreationDate = $null }                # 起動時刻が分からない
    )
    $found = @(Get-ProcessDescendant -Processes $procs -Id 100 -StartTime $t0 | ForEach-Object { $_.ProcessId }) -join ','
    Assert-Equal $found '300,200' '子孫を深いものから返す。止める相手より前に起動した「子」とその子孫、起動時刻の分からないものは含めない'
    Assert-Equal @(Get-ProcessDescendant -Processes $procs -Id 100 -StartTime $t0.AddSeconds(5)).Count 0 '止める相手が「子」より後に起動していれば（PID の使い回し）、子孫はない'

    Write-Host '== Stop-ProcessTree: 親が終わったあとの子'
    # 親（cmd.exe）が終わったあとも動き続ける子を作る。子の ParentProcessId は、終わった親の PID のまま残る。
    # 親の Process を Dispose するまで、その PID はほかのプロセスに使い回されない（テストが無関係なプロセスを止めない）
    function Test-SameProcess {
        param($Cim)
        $now = Get-CimInstance Win32_Process -Filter "ProcessId=$($Cim.ProcessId)" -ErrorAction SilentlyContinue
        return [bool]($now -and $now.CreationDate -eq $Cim.CreationDate)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe', '/c start "" /b powershell.exe -NoProfile -Command Start-Sleep -Seconds 60'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $goneProc = [Diagnostics.Process]::Start($psi)
    $orphan = $null
    try {
        [void]$goneProc.WaitForExit(10000)
        $deadline = (Get-Date).AddSeconds(10)
        while (-not $orphan -and (Get-Date) -lt $deadline) {
            $orphan = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($goneProc.Id) AND Name='powershell.exe'" | Select-Object -First 1
            if (-not $orphan) { Start-Sleep -Milliseconds 200 }
        }
        Assert-True ($goneProc.HasExited -and $orphan) '親が終わったあとも動き続ける子ができた'
        if ($orphan) {
            Stop-ProcessTree -Id $goneProc.Id
            Start-Sleep -Milliseconds 500
            Assert-True (Test-SameProcess $orphan) '止める相手がもう終わっていて、起動時刻が分からなければ、子孫は止めない'
            # 同じ PID を新しいプロセスが使い回したときと同じ（止める相手は、子より後に起動した）
            Stop-ProcessTree -Id $goneProc.Id -StartTime (Get-Date)
            Start-Sleep -Milliseconds 500
            Assert-True (Test-SameProcess $orphan) '止める相手より前に起動した「子」は止めない（PID の使い回し）'
        }
    }
    finally {
        if ($orphan -and (Test-SameProcess $orphan)) { try { Stop-Process -Id $orphan.ProcessId -Force -ErrorAction Stop } catch { } }
        $goneProc.Dispose()
    }
    Assert-True ($andonText -match 'try \{ \$script:PollStartTime = \$script:PollProc\.StartTime \}') 'claude agents --json を起動したときに、その起動時刻を覚える'
    Assert-Equal ([regex]::Matches($andonText, 'Stop-ProcessTree -Id \$script:PollProc\.Id -StartTime \$script:PollStartTime').Count) 2 'claude agents --json を止めるとき（応答しないとき、andon を終了するとき）は、起動時刻を渡す'
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
Write-Host '== Codex の hook（andon-codex-hook.ps1）: イベントの当てはめ'
$t0 = [datetime]'2026-01-01T00:00:00'
function New-HookPayload {
    param([string]$EventName, [string]$Session = 's1', [string]$Turn = 't1', [hashtable]$Extra = @{})
    $o = [ordered]@{ session_id = $Session; hook_event_name = $EventName; cwd = 'C:\work\c1'; turn_id = $Turn }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    return [pscustomobject]$o
}
function Get-HookEventText {
    param($Payload)
    $e = ConvertFrom-AndonCodexHookEvent $Payload
    if (-not $e) { return 'null' }
    return '{0}|{1}|{2}|{3}|{4}|{5}' -f $e.Status, $e.WaitingFor, $e.Done, $e.Interrupted, $e.CreateOnly, $e.Remove
}
Assert-Equal (Get-HookEventText (New-HookPayload 'SessionStart')) 'idle||False|False|True|False' 'SessionStart は、記録がなければ待機で作る'
Assert-Equal (Get-HookEventText (New-HookPayload 'UserPromptSubmit')) 'busy||False|False|False|False' 'UserPromptSubmit は実行中'
Assert-Equal (Get-HookEventText (New-HookPayload 'PermissionRequest')) 'waiting|permission prompt|False|False|False|False' 'PermissionRequest は許可待ち'
Assert-Equal (Get-HookEventText (New-HookPayload 'Stop')) 'idle||True|False|False|False' 'Stop は完了'
Assert-Equal (Get-HookEventText (New-HookPayload 'Stop' -Extra @{ agent_id = 'a1' })) 'null' 'サブエージェントの Stop（agent_id）は当てない'
Assert-Equal (Get-HookEventText (New-HookPayload 'Stop' -Extra @{ agent_type = 'worker' })) 'null' 'サブエージェントの Stop（agent_type）は当てない'
Assert-Equal (Get-HookEventText (New-HookPayload 'Interrupt')) 'idle||False|True|False|False' 'Interrupt は待機（既読）'
Assert-Equal (Get-HookEventText (New-HookPayload 'SessionEnd')) '||False|False|False|True' 'SessionEnd は記録を消す'
Assert-Equal (Get-HookEventText (New-HookPayload 'PreToolUse')) 'null' '使わないイベントは当てない'
Assert-Equal (Get-HookEventText (New-HookPayload 'Stop' -Session '..\x')) 'null' 'ファイル名に使えないセッションの ID は当てない'
Assert-Equal (Get-HookEventText (New-HookPayload 'Stop' -Session '')) 'null' 'セッションの ID がなければ当てない'

$hostInfo = [pscustomobject]@{ Pid = 100; Start = 5; Kind = 'vscode' }
function New-HookEvent { param([string]$EventName, [string]$Turn = 't1') return ConvertFrom-AndonCodexHookEvent (New-HookPayload $EventName -Turn $Turn) }
$st1 = Merge-AndonCodexState -Current $null -Event (New-HookEvent 'SessionStart') -At 10 -HostInfo $hostInfo
Assert-Equal "$($st1.Status)|$($st1.HostPid)|$($st1.HostStart)|$($st1.HostKind)|$($st1.Cwd)|$($st1.At)" 'idle|100|5|vscode|C:\work\c1|10' '最初のイベントで記録を作り、Codex のプロセスを書く'
$st2 = Merge-AndonCodexState -Current $st1 -Event (New-HookEvent 'UserPromptSubmit') -At 20 -HostInfo $null
Assert-Equal "$($st2.Status)|$($st2.HostPid)|$($st2.HostKind)" 'busy|100|vscode' '記録の Codex のプロセスを引き継ぐ'
Assert-Equal (Merge-AndonCodexState -Current $st2 -Event (New-HookEvent 'SessionStart') -At 30 -HostInfo $null) $null 'SessionStart は、記録があれば当てない（最初のプロンプトと順が入れ替わるため）'
Assert-Equal (Merge-AndonCodexState -Current $st2 -Event (New-HookEvent 'PermissionRequest') -At 15 -HostInfo $null) $null '記録より古いイベントは当てない'
$st3 = Merge-AndonCodexState -Current $st2 -Event (New-HookEvent 'Interrupt') -At 40 -HostInfo $null
Assert-Equal "$($st3.Status)|$($st3.Interrupted)|$($st3.Done)" 'idle|True|False' '中断は待機'
Assert-Equal (Merge-AndonCodexState -Current $st3 -Event (New-HookEvent 'Stop') -At 41 -HostInfo $null) $null '中断した同じターンの Stop は、完了にしない'
$st4 = Merge-AndonCodexState -Current $st3 -Event (New-HookEvent 'Stop' -Turn 't2') -At 50 -HostInfo $null
Assert-Equal "$($st4.Status)|$($st4.Done)|$($st4.Interrupted)|$($st4.Turn)" 'idle|True|False|t2' '別のターンの Stop は完了'

function New-HostProc {
    param([int]$Id, [int]$Parent, [string]$Name, [int]$At, [string]$Cmd = '')
    return [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CreationDate = $t0.AddSeconds($At); CommandLine = $Cmd }
}
$hostProcs = @(
    (New-HostProc 1 0 'Code.exe' 0 'Code.exe'),
    (New-HostProc 2 1 'codex.exe' 10 'codex.exe -c features.x=true app-server --analytics-default-enabled'),
    (New-HostProc 3 2 'pwsh.exe' 20), (New-HostProc 4 3 'powershell.exe' 21),
    (New-HostProc 11 0 'codex.exe' 5 'codex.exe app-server --listen unix:// --analytics-default-enabled --managed-daemon'),
    (New-HostProc 12 11 'pwsh.exe' 30), (New-HostProc 13 12 'powershell.exe' 31),
    (New-HostProc 21 0 'pwsh.exe' 1 'pwsh.exe'), (New-HostProc 22 21 'codex.exe' 40 'codex.exe -c approvals_reviewer=user'),
    (New-HostProc 23 22 'pwsh.exe' 41), (New-HostProc 24 23 'powershell.exe' 42),
    (New-HostProc 31 99 'powershell.exe' 60),
    (New-HostProc 41 42 'powershell.exe' 5), (New-HostProc 42 0 'codex.exe' 70 'codex.exe')
)
function Format-CodexHost { param($H) if (-not $H) { return 'null' } return '{0}|{1}' -f $H.Pid, $H.Kind }
Assert-Equal (Format-CodexHost (Find-AndonCodexHost -Processes $hostProcs -Id 4)) '2|vscode' 'VS Code の拡張機能の app-server（親が VS Code）は vscode'
Assert-Equal (Find-AndonCodexHost -Processes $hostProcs -Id 4).Start $t0.AddSeconds(10).ToUniversalTime().Ticks 'Codex のプロセスの起動時刻（UTC の Ticks）'
Assert-Equal (Format-CodexHost (Find-AndonCodexHost -Processes $hostProcs -Id 13)) '11|daemon' '共有のデーモンは daemon'
Assert-Equal (Format-CodexHost (Find-AndonCodexHost -Processes $hostProcs -Id 24)) '22|terminal' 'デーモンを使わない codex（-c で起動したものなど）は terminal'
Assert-Equal (Format-CodexHost (Find-AndonCodexHost -Processes $hostProcs -Id 31)) 'null' '親をたどれなければ見つからない'
Assert-Equal (Format-CodexHost (Find-AndonCodexHost -Processes $hostProcs -Id 41)) 'null' '子より後に起動した親（PID の使い回し）はたどらない'

# ---------------------------------------------------------------------------
Write-Host '== Codex の hook（andon-codex-hook.ps1）: hooks.json の入れ外し'
function Get-HooksField {
    <# hooks.json を読んだもの（$Root）の、イベントの組の handler の項目。なければ空（壊したときに、例外で止めずに FAIL にする） #>
    param($Root, [string]$EventName, [int]$Group = 0, [int]$Handler = 0, [string]$Field = 'command')
    try {
        $g = @($Root.hooks.$EventName)[$Group]
        if ($Field -eq 'matcher') { return [string]$g.matcher }
        return [string](@($g.hooks)[$Handler].$Field)
    }
    catch { return '' }
}
$hookCmd = Get-AndonCodexHookCommand -ScriptPath "C:\Users\O'Brien\andon\andon-codex-hook.ps1"
Assert-Equal $hookCmd "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\Users\O''Brien\andon\andon-codex-hook.ps1'" 'パスは単一引用符で囲み、単一引用符は 2 つ重ねる'
$added = Add-AndonCodexHooks -Json '' -Command $hookCmd
$hj = ConvertFrom-Json $added
Assert-Equal (@($hj.hooks.PSObject.Properties.Name) -join ',') 'SessionStart,UserPromptSubmit,PermissionRequest,Stop,Interrupt,SessionEnd' '空の hooks.json に、6 つのイベントを足す'
Assert-Equal "$(Get-HooksField $hj 'Stop' -Field type)|$(Get-HooksField $hj 'Stop' -Field async)|$(Get-HooksField $hj 'Stop')" "command|True|$hookCmd" 'andon の hook は async（Codex は待たず、判断に関われない）'
Assert-Equal "$(Get-HooksField $hj 'SessionEnd' -Field timeout)|$(Get-HooksField $hj 'Stop' -Field timeout)" '3|30' 'SessionEnd の待ち時間は、上限の 3 秒'
Assert-True (Test-AndonCodexHooks $added) '足したら andon の hook がある'
$userHooks = '{"description":"mine","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 check.py","timeout":30}]}],"Stop":[{"hooks":[{"type":"command","command":"notify.cmd"}]}]}}'
$added = Add-AndonCodexHooks -Json $userHooks -Command $hookCmd
$hj = ConvertFrom-Json $added
Assert-Equal $hj.description 'mine' 'ほかの項目を残す'
Assert-Equal "$(Get-HooksField $hj 'PreToolUse' -Field matcher)|$(Get-HooksField $hj 'PreToolUse')|$(Get-HooksField $hj 'PreToolUse' -Field timeout)" 'Bash|python3 check.py|30' 'ほかのイベントの hook を残す'
Assert-Equal "$(@($hj.hooks.Stop).Count)|$(Get-HooksField $hj 'Stop')" '2|notify.cmd' '同じイベントのほかの hook は先頭のまま、andon の組を最後に足す（信頼を保つ）'
Assert-True (Test-AndonCodexHandler (@(@($hj.hooks.Stop)[1].hooks)[0])) '最後の組が andon の hook'
$again = Add-AndonCodexHooks -Json $added -Command ($hookCmd.Replace('andon\', 'andon2\'))
$hj = ConvertFrom-Json $again
Assert-Equal "$(@($hj.hooks.Stop).Count)|$((Get-HooksField $hj 'Stop' -Group 1).Contains('andon2'))" '2|True' 'もう一度足すと、andon の分を入れ直す（重ならない）'
$removed = Remove-AndonCodexHooks -Json $added
$hj = ConvertFrom-Json $removed
Assert-Equal (@($hj.hooks.PSObject.Properties.Name) -join ',') 'PreToolUse,Stop' 'andon の hook だけを消し、andon の分だけだったイベントは消す'
Assert-Equal "$(@($hj.hooks.Stop).Count)|$(Get-HooksField $hj 'Stop')" '1|notify.cmd' '消しても、ほかの hook は残す'
Assert-True (-not (Test-AndonCodexHooks $removed)) '消したら andon の hook はない'
$mixed = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"a.cmd"},{"type":"command","command":"powershell.exe -File C:\\x\\andon-codex-hook.ps1"}]}]}}'
$hj = ConvertFrom-Json (Remove-AndonCodexHooks -Json $mixed)
Assert-Equal "$(@(@($hj.hooks.Stop)[0].hooks).Count)|$(Get-HooksField $hj 'Stop')" '1|a.cmd' '同じ組のほかの handler は残す'
Assert-Throws { Add-AndonCodexHooks -Json '{ broken' -Command $hookCmd } '読めない hooks.json には足さない（例外）'
Assert-Throws { Add-AndonCodexHooks -Json '[1,2]' -Command $hookCmd } 'オブジェクトでない hooks.json には足さない（例外）'
Assert-Throws { Add-AndonCodexHooks -Json '{"hooks":[1]}' -Command $hookCmd } 'hooks がオブジェクトでなければ足さない（例外）'
Assert-True (-not (Test-AndonCodexHooks '{ broken')) '読めなければ、andon の hook はないとみなす'

# 足し直しと、外すと詰まる hook（D-116）。Codex は hook の信頼を、イベントの中の位置で覚えている
$around = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"first.cmd"}]},{"hooks":[{"type":"command","command":"powershell.exe -File C:\\old\\andon-codex-hook.ps1"}]},{"hooks":[{"type":"command","command":"after.cmd"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"powershell.exe -File C:\\old\\andon-codex-hook.ps1"}]},{"hooks":[{"type":"command","command":"tool.cmd"}]}]}}'
Assert-Equal ((Get-AndonCodexHooksShifted $around) -join ',') 'Stop,PostToolUse' 'andon の hook の後ろに、ほかの hook があるイベントを見つける'
$hj = ConvertFrom-Json (Add-AndonCodexHooks -Json $around -Command $hookCmd)
Assert-Equal "$(Get-HooksField $hj 'Stop' -Group 0)|$(Get-HooksField $hj 'Stop' -Group 1)|$(Get-HooksField $hj 'Stop' -Group 2)" "first.cmd|$hookCmd|after.cmd" '足し直すときは、andon の hook をその場で書き換え、前後の hook を動かさない'
Assert-Equal "$(@($hj.hooks.PostToolUse).Count)|$(Get-HooksField $hj 'PostToolUse')" '1|tool.cmd' 'andon が使わなくなったイベントに残った andon の hook は消す'
$dup = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x\\andon-codex-hook.ps1"}]},{"hooks":[{"type":"command","command":"y\\andon-codex-hook.ps1"}]}]}}'
$hj = ConvertFrom-Json (Add-AndonCodexHooks -Json $dup -Command $hookCmd)
Assert-Equal "$(@($hj.hooks.Stop).Count)|$(Get-HooksField $hj 'Stop')" "1|$hookCmd" 'andon の hook が 2 つあれば、最初の 1 つだけを残して書き換える'
Assert-Equal @(Get-AndonCodexHooksShifted (Add-AndonCodexHooks -Json $userHooks -Command $hookCmd)).Count 0 'andon の hook が最後なら、外しても詰まる hook はない'
$sameGroup = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x\\andon-codex-hook.ps1"},{"type":"command","command":"b.cmd"}]}]}}'
Assert-Equal ((Get-AndonCodexHooksShifted $sameGroup) -join ',') 'Stop' '同じ組の中で、andon の hook の後ろにほかの hook があっても見つける'
Assert-Equal @(Get-AndonCodexHooksShifted '{ broken').Count 0 '読めなければ、詰まる hook はないとみなす'

$hooksTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-hooks-' + [guid]::NewGuid().ToString('N'))
try {
    $hp = Join-Path $hooksTmp 'hooks.json'
    Set-AndonCodexHooks -Enabled $true -Path $hp -Command $hookCmd
    Assert-True (Test-AndonCodexHooks (Read-AndonCodexHooksFile -Path $hp)) 'hooks.json がなければ、作って足す'
    Assert-True (-not (Test-Path -LiteralPath "$hp.andon-backup")) 'もとの hooks.json がなければ、写しは作らない'
    [IO.File]::WriteAllText($hp, $userHooks)
    Set-AndonCodexHooks -Enabled $true -Path $hp -Command $hookCmd
    $backupText = ''
    if (Test-Path -LiteralPath "$hp.andon-backup") { $backupText = [IO.File]::ReadAllText("$hp.andon-backup") }
    Assert-Equal $backupText $userHooks '書き換える前に、写しを作る'
    $bytes = [IO.File]::ReadAllBytes($hp)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'hooks.json は BOM なしで書く'
    Set-AndonCodexHooks -Enabled $false -Path $hp -Command ''
    $hj = ConvertFrom-Json (Read-AndonCodexHooksFile -Path $hp)
    Assert-Equal "$(Test-AndonCodexHooks (Read-AndonCodexHooksFile -Path $hp))|$($hj.description)" 'False|mine' '外すと、andon の hook だけを消す'
    [IO.File]::WriteAllText($hp, '{ broken')
    Assert-Throws { Set-AndonCodexHooks -Enabled $true -Path $hp -Command $hookCmd } '読めない hooks.json には足さない'
    Set-AndonCodexHooks -Enabled $false -Path $hp -Command ''
    Assert-Equal ([IO.File]::ReadAllText($hp)) '{ broken' '読めない hooks.json は書き換えない'
}
finally { Remove-Item -LiteralPath $hooksTmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '== install.ps1: アンインストールで Codex の hook と記録を消す'
Assert-True ((Get-AndonPayload) -contains 'andon-codex-hook.ps1') '配るファイルに、Codex の hook のスクリプトを入れる'
$unTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-uninstall-codex-' + [guid]::NewGuid().ToString('N'))
try {
    $hp = Join-Path $unTmp 'codex\hooks.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hp) -Force | Out-Null
    [IO.File]::WriteAllText($hp, $userHooks)
    Set-AndonCodexHooks -Enabled $true -Path $hp -Command $hookCmd
    $dataDir = Join-Path $unTmp 'andon'
    New-Item -ItemType Directory -Path (Join-Path $dataDir 'codex') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dataDir 'codex\s1.json'), '{}')
    $lines = Remove-AndonCodexData -HookScript (Join-Path $root 'andon-codex-hook.ps1') -DataDir $dataDir -HooksPath $hp
    $hj = ConvertFrom-Json (Read-AndonCodexHooksFile -Path $hp)
    Assert-Equal "$(Test-AndonCodexHooks (Read-AndonCodexHooksFile -Path $hp))|$(Get-HooksField $hj 'PreToolUse')" 'False|python3 check.py' 'アンインストールで andon の hook だけを消し、ほかの hook は残す'
    Assert-Equal "$(Test-Path -LiteralPath $dataDir)|$(@($lines).Count)" 'False|2' 'アンインストールで記録のフォルダを消し、消したものを知らせる'
    $lines = Remove-AndonCodexData -HookScript (Join-Path $root 'andon-codex-hook.ps1') -DataDir $dataDir -HooksPath $hp
    Assert-Equal @($lines).Count 0 '消すものがなければ、何も知らせない'
    [IO.File]::WriteAllText($hp, $around)
    $lines = Remove-AndonCodexData -HookScript (Join-Path $root 'andon-codex-hook.ps1') -DataDir $dataDir -HooksPath $hp
    Assert-True (@($lines | Where-Object { $_.StartsWith('注意:') -and $_.Contains('Stop、PostToolUse') -and $_.Contains('/hooks') }).Count -eq 1) 'アンインストールで、後ろの hook が詰まるときは、信頼し直すよう知らせる'
    [IO.File]::WriteAllText($hp, '{ broken')
    $lines = Remove-AndonCodexData -HookScript (Join-Path $root 'andon-codex-hook.ps1') -DataDir $dataDir -HooksPath $hp
    Assert-Equal "$(@($lines).Count)|$([IO.File]::ReadAllText($hp))" '0|{ broken' '読めない hooks.json は書き換えない（andon の hook はないとみなす）'
    $lines = Remove-AndonCodexData -HookScript (Join-Path $unTmp 'missing.ps1') -DataDir $dataDir -HooksPath $hp
    Assert-Equal @($lines).Count 0 'hook のスクリプトがなければ、hooks.json に触れない'
}
finally { Remove-Item -LiteralPath $unTmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Write-Host '== Codex の hook（andon-codex-hook.ps1）: 記録を書く'
$stateTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-codex-' + [guid]::NewGuid().ToString('N'))
try {
    $lookups = @{ Count = 0 }
    $getProcs = { $lookups.Count++; $hostProcs }.GetNewClosure()
    Invoke-AndonCodexHook -Payload (New-HookPayload 'SessionStart') -StateDir $stateTmp -At 100 -GetProcesses $getProcs -SelfId 4
    $rec = Read-AndonCodexState -Path (Join-Path $stateTmp 's1.json')
    Assert-Equal "$($rec.Status)|$($rec.HostPid)|$($rec.HostKind)|$($lookups.Count)" 'idle|2|vscode|1' '最初のイベントで、Codex のプロセスを調べて記録を書く'
    Invoke-AndonCodexHook -Payload (New-HookPayload 'UserPromptSubmit') -StateDir $stateTmp -At 200 -GetProcesses $getProcs -SelfId 4
    $rec = Read-AndonCodexState -Path (Join-Path $stateTmp 's1.json')
    Assert-Equal "$($rec.Status)|$($rec.HostPid)|$($lookups.Count)" 'busy|2|1' '2 回目からは、Codex のプロセスを調べない'
    $raw = [IO.File]::ReadAllText((Join-Path $stateTmp 's1.json'))
    Assert-True (-not $raw.Contains('prompt') -and -not $raw.Contains('transcript')) '記録に、プロンプトや会話の記録の場所を書かない'
    Invoke-AndonCodexHook -Payload (New-HookPayload 'PreToolUse') -StateDir $stateTmp -At 300 -GetProcesses $getProcs -SelfId 4
    Assert-Equal (Read-AndonCodexState -Path (Join-Path $stateTmp 's1.json')).At ([long]200) '使わないイベントでは書かない'
    Invoke-AndonCodexHook -Payload (New-HookPayload 'SessionEnd') -StateDir $stateTmp -At 400 -GetProcesses $getProcs -SelfId 4
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateTmp 's1.json'))) 'SessionEnd で記録を消す'
    Assert-Equal @(Get-ChildItem -LiteralPath $stateTmp -Filter '*.tmp').Count 0 '一時ファイルを残さない'

    # 本物の子プロセスとして動かす（Codex と同じく、標準入力に JSON を渡す）。何も出力せず、終了コード 0 で、記録を書く
    $savedLocal = $env:LOCALAPPDATA
    $savedEncoding = $OutputEncoding
    try {
        $env:LOCALAPPDATA = $stateTmp
        # Windows PowerShell 5.1 は、ネイティブのコマンドへ ASCII で送るので、UTF-8 にする（Codex は UTF-8 で渡す）
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $payloadJson = '{"session_id":"child-1","hook_event_name":"UserPromptSubmit","cwd":"C:\\work\\日本語","turn_id":"t9","prompt":"secret"}'
        $hookOut = $payloadJson | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'andon-codex-hook.ps1')
        $hookExit = $LASTEXITCODE
    }
    finally { $env:LOCALAPPDATA = $savedLocal; $OutputEncoding = $savedEncoding }
    $rec = Read-AndonCodexState -Path (Join-Path $stateTmp 'andon\codex\child-1.json')
    Assert-Equal "$hookExit|$(($hookOut -join '').Length)" '0|0' 'hook として動かすと、何も出力せず、終了コード 0'
    Assert-Equal "$($rec.Status)|$($rec.Cwd)" 'busy|C:\work\日本語' 'hook として動かすと、記録を書く（日本語の作業フォルダも読める）'
    Assert-True (-not ([IO.File]::ReadAllText((Join-Path $stateTmp 'andon\codex\child-1.json'))).Contains('secret')) 'hook として動かしても、プロンプトを書かない'
    $hookOut = '{ broken' | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'andon-codex-hook.ps1')
    Assert-Equal "$LASTEXITCODE|$(($hookOut -join '').Length)" '0|0' '読めない入力でも、何も出力せず、終了コード 0'
}
finally { Remove-Item -LiteralPath $stateTmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Write-Host '== Codex のセッション（andon の一覧）'
Assert-Equal (Get-JsonValue $null 'a') $null 'Get-JsonValue は $null に $null を返す'
Assert-True (Test-CodexKey 'codex:abc') 'codex: で始まるキーは Codex のセッション'
Assert-True (-not (Test-CodexKey '1234')) 'PID のキーは Codex のセッションでない'
function New-CodexRecord {
    param([string]$Id, [string]$Status, [long]$At, [switch]$Done, [switch]$Interrupted, [string]$Kind = 'daemon', [int]$HostPid = 0, [string]$WaitingFor = '')
    return [pscustomobject]@{
        SessionId = $Id; Status = $Status; WaitingFor = $WaitingFor; Done = [bool]$Done; Interrupted = [bool]$Interrupted
        Turn = 't'; Cwd = "C:\work\$Id"; At = $At; HostPid = $HostPid; HostStart = 1; HostKind = $Kind
    }
}
function New-CodexSession { return ConvertTo-CodexSession (New-CodexRecord @args) }
Assert-Equal (ConvertTo-CodexSession (New-CodexRecord 'x' 'strange' 1)) $null '知らない状態の記録は読まない'
Assert-Equal (ConvertTo-CodexSession $null) $null '記録がなければ読まない'

$readTmp = Join-Path ([IO.Path]::GetTempPath()) ('andon-codex-read-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $readTmp -Force | Out-Null
    $nowR = [datetime]'2026-01-02T00:00:00'
    $fresh = $nowR.ToUniversalTime().AddMinutes(-5).Ticks
    $old = $nowR.ToUniversalTime().AddHours(-25).Ticks
    [IO.File]::WriteAllText((Join-Path $readTmp 'a.json'), (ConvertTo-Json (New-CodexRecord 'a' 'busy' $fresh -HostPid 5)))
    [IO.File]::WriteAllText((Join-Path $readTmp 'b.json'), (ConvertTo-Json (New-CodexRecord 'b' 'idle' $old -HostPid 5)))
    [IO.File]::WriteAllText((Join-Path $readTmp 'c.json'), (ConvertTo-Json (New-CodexRecord 'c' 'idle' $fresh -HostPid 7)))
    [IO.File]::WriteAllText((Join-Path $readTmp 'd.json'), '{ broken')
    [IO.File]::WriteAllText((Join-Path $readTmp 'e.json'), (ConvertTo-Json (New-CodexRecord 'e' 'idle' $fresh -HostPid 0)))
    $read = Read-CodexSessions -Dir $readTmp -Now $nowR -IsAlive { param($HostPid, $HostStart) $HostPid -ne 7 }
    Assert-Equal (@($read | ForEach-Object { $_.Key } | Sort-Object) -join ',') 'codex:a,codex:e' '古いもの、Codex のプロセスが終わったもの、読めないものは除く'
    Assert-Equal "$(Test-Path (Join-Path $readTmp 'b.json'))|$(Test-Path (Join-Path $readTmp 'c.json'))|$(Test-Path (Join-Path $readTmp 'd.json'))" 'False|False|True' '古いものと終わったものの記録は消し、読めないものは残す'
    Assert-Equal (Read-CodexSessions -Dir (Join-Path $readTmp 'none') -Now $nowR -IsAlive $null).Count 0 'フォルダがなければ空'
}
finally { Remove-Item -LiteralPath $readTmp -Recurse -Force -ErrorAction SilentlyContinue }
Assert-True (Test-CodexHostAlive -HostPid $PID -HostStart ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)) '動いているプロセスは生きている'
Assert-True (-not (Test-CodexHostAlive -HostPid $PID -HostStart 1)) '起動時刻が違えば、PID の使い回しとして終わったとみなす'

$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 1 'busy')) -Now $t0
$alert = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'busy' 1)) -Now $t0
Assert-Equal $alert $false '初めて見た待機と実行中では知らせない'
Assert-Equal "$(Get-StatusLabel $script:State['codex:a'])|$(Get-StatusLabel $script:State['codex:b'])" '待機|実行中' 'Codex のセッションの待機と実行中'
Assert-Equal "$($script:State['codex:a'].Kind)|$($script:State['codex:a'].Sdk)" 'codex|False' 'Codex のセッションの Kind は codex。デーモンのセッションは隠さない'
Assert-Equal (Find-SessionWindow -Entry $script:State['codex:a'] -Processes @() -Windows @() -AppWindows @()) $null '共有のデーモンの Codex のセッションはウィンドウを探さない'
$null = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'busy' 1), (New-CodexSession 't' 'busy' 1 -Kind 'terminal' -HostPid 84)) -Now $t0
Assert-Equal "$($script:State['codex:t'].HostPid)|$($script:State['codex:t'].HostStart)|$($script:State['codex:t'].HostKind)" '84|1|terminal' 'Codex のセッションに、Codex のプロセスと種類を覚える（ターミナルの中ならウィンドウを探す）'
Assert-Equal (Get-SessionWindowProcessId $script:State['codex:t']) 84 '記録から作った Codex のセッションも、ターミナルの中なら Codex のプロセスから探す'
$null = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'busy' 1)) -Now $t0
$alert = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'waiting' 2 -WaitingFor 'permission prompt')) -Now $t0.AddSeconds(5)
Assert-Equal "$alert|$(Get-StatusLabel $script:State['codex:b'])" 'True|許可待ち' '許可待ちになったら知らせる'
$alert = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'idle' 3 -Done)) -Now $t0.AddSeconds(10)
Assert-Equal "$alert|$(Get-StatusLabel $script:State['codex:b'])" 'True|完了' '許可待ちのあとの Stop も完了（許可したあとにターンが終わった）'
$alert = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 1), (New-CodexSession 'b' 'idle' 3 -Done)) -Now $t0.AddSeconds(15)
Assert-Equal "$alert|$($script:State['codex:b'].Unread)" 'False|True' '同じイベントでは、もう一度知らせない'
$null = Update-CodexState -Sessions @((New-CodexSession 'a' 'busy' 4), (New-CodexSession 'b' 'idle' 3 -Done)) -Now $t0.AddSeconds(20)
$alert = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 5 -Interrupted), (New-CodexSession 'b' 'idle' 3 -Done)) -Now $t0.AddSeconds(25)
Assert-Equal "$alert|$(Get-StatusLabel $script:State['codex:a'])" 'False|待機' '中断は知らせず、既読の待機'
$null = Update-CodexState -Sessions @((New-CodexSession 'v' 'busy' 1 -Kind 'vscode')) -Now $t0.AddSeconds(30)
Assert-Equal "$($script:State['codex:v'].Sdk)|$(Test-SessionVisible $script:State['codex:v'])" 'True|True' 'VS Code の拡張機能のセッションは、実行中なら出す'
Assert-Equal $script:State.ContainsKey('codex:a') $false '一覧にない Codex のセッションは消す'
$null = Update-CodexState -Sessions @((New-CodexSession 'v' 'idle' 2 -Kind 'vscode' -Done)) -Now $t0.AddSeconds(35)
Assert-Equal (Test-SessionVisible $script:State['codex:v']) $true 'VS Code の拡張機能のセッションは、完了なら出す'
$script:State['codex:v'].Unread = $false
Assert-Equal (Test-SessionVisible $script:State['codex:v']) $false 'VS Code の拡張機能のセッションは、待機（確認済み）なら出さない'
Assert-Equal $script:State.ContainsKey('1') $true 'Codex の一覧は Claude のセッションを消さない'
$null = Update-SessionState -Sessions @((New-Session 2 'idle')) -Now $t0.AddSeconds(40)
Assert-Equal "$($script:State.ContainsKey('codex:v'))|$($script:State.ContainsKey('1'))" 'True|False' 'Claude の一覧は Codex のセッションを消さず、Claude のセッションは消す'
Assert-Equal (Clear-CodexState) $true 'Codex のセッションを消したら $true'
Assert-Equal "$($script:State.ContainsKey('codex:v'))|$($script:State.ContainsKey('2'))|$(Clear-CodexState)" 'False|True|False' 'Clear-CodexState は Codex のセッションだけを消す'

$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 1 'waiting' 'permission prompt')) -Now $t0
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t0).Title 'Claude Code が待っています' 'Claude のセッションの通知の題'
$script:State = @{}
$null = Update-CodexState -Sessions @((New-CodexSession 'a' 'waiting' 1 -WaitingFor 'permission prompt')) -Now $t0
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t0
Assert-Equal "$($notice.Title)|$($notice.Text)|$($notice.Key)" 'Codex が待っています|許可待ち: a|codex:a' 'Codex のセッションの待ちの通知（名前がなければフォルダの名前）'
$null = Update-CodexState -Sessions @((New-CodexSession 'a' 'idle' 2 -Done)) -Now $t0.AddSeconds(5)
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t0.AddSeconds(5)).Title 'Codex が完了しました' 'Codex のセッションの完了の通知の題'
$script:State = @{}

# ---------------------------------------------------------------------------
Write-Host '== Orca のリモートのセッション（D-141、D-143、D-145、D-147）'
# 例の値は作りもの。ペアリング先の ID、区画、パス、名前に、実在のものを書かない
$envA = '11111111-2222-3333-4444-555555555555'
$envB = 'env-b'
function New-OrcaAgent {
    param([string]$Pane, [string]$State, [string]$Type = 'claude', [long]$At = 1000, [switch]$Interrupted, [string]$Parent = $null, [string]$Program = '')
    $programStatus = $null
    if ($Program) { $programStatus = [ordered]@{ state = $Program; message = 'secret status text' } }
    return [ordered]@{
        programStatus = $programStatus
        paneKey = $Pane; parentPaneKey = $Parent; state = $State; agentType = $Type; prompt = 'secret prompt text'
        lastAssistantMessage = 'secret reply text'; toolName = 'Bash'; toolInput = 'secret command'; interrupted = [bool]$Interrupted
        stateStartedAt = $At; updatedAt = $At + 5
    }
}
function New-OrcaWorktree { param([string]$Name, [string]$Path, [object[]]$Agents = @(), $Repo = $null) return [ordered]@{ repo = $Repo; displayName = $Name; path = $Path; status = 'active'; agents = @($Agents) } }
function ConvertTo-OrcaPsJson { param([object[]]$Worktrees, [bool]$Ok = $true, [bool]$Truncated = $false) return (ConvertTo-Json -Depth 8 ([ordered]@{ id = 'x'; ok = $Ok; result = [ordered]@{ worktrees = @($Worktrees); totalCount = @($Worktrees).Count; truncated = $Truncated } })) }
function Format-OrcaSession { param($S) return '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f $S.Key, $S.Status, $S.Done, $S.Name, $S.Cwd, $S.Agent, $S.At, $S.Active, $S.WaitingFor }

Assert-Equal "$(Test-OrcaKey 'orca:e:p')|$(Test-OrcaKey 'codex:a')|$(Test-OrcaKey '123')" 'True|False|False' 'Orca のリモートのセッションは、キーが orca: で始まる'
Assert-Equal "$(Test-OrcaId $envA)|$(Test-OrcaId 'tab-1:leaf_2')|$(Test-OrcaId 'term_a.b')" 'True|True|True' 'ID は、英数字と _ . : - だけ'
Assert-Equal "$(Test-OrcaId '')|$(Test-OrcaId '-x')|$(Test-OrcaId 'a b')|$(Test-OrcaId 'a"b')|$(Test-OrcaId 'a;b')|$(Test-OrcaId ('a' * 129))|$(Test-OrcaId "a`nb")" 'False|False|False|False|False|False|False' '空、記号で始まるもの、空白や引用符や ; や改行を含むもの、長すぎるものは、ID として使わない'
Assert-Equal (ConvertTo-OrcaText "  a`r`nb`tc  ") 'a  b c' '名前やパスは、制御文字を空白にして 1 行にする'
Assert-Equal "$((ConvertTo-OrcaText ('x' * 300) -Max 10).Length)|$(ConvertTo-OrcaText $null)|$(ConvertTo-OrcaText 12)" '10||' '長い文字は切り、文字でないものは空にする'

Assert-Throws { ConvertFrom-OrcaResult '' } '出力が空なら例外'
Assert-Throws { ConvertFrom-OrcaResult 'connection refused' } 'JSON でなければ例外'
Assert-Throws { ConvertFrom-OrcaResult '{"ok":false,"error":{"code":"runtime_unavailable"}}' } 'ok でなければ例外'
Assert-Equal (ConvertFrom-OrcaResult "warning`n{`"ok`":true,`"result`":{`"n`":3}}").n 3 'JSON の前に行が混ざっても読む'

$envJson = ConvertTo-Json -Depth 6 ([ordered]@{ ok = $true; result = [ordered]@{ environments = @(
                [ordered]@{ id = $envA; name = " Work Laptop`n"; endpoints = @(@{ endpoint = 'ws://example.invalid' }) }
                [ordered]@{ id = 'bad id'; name = 'x' }
                [ordered]@{ id = $envB; name = '' }
                [ordered]@{ id = 5; name = 'n' }
            ) } })
$envs = ConvertFrom-OrcaEnvironmentList $envJson
Assert-Equal (@($envs | ForEach-Object { "$($_.Id)=$($_.Name)" }) -join ',') "$envA=Work Laptop,env-b=env-b" 'ペアリング先の一覧は、ID の形が合うものだけ。名前は 1 行にし、なければ ID'
Assert-Equal (@($envs[0].PSObject.Properties.Name) -join ',') 'Id,Name' 'ペアリング先の一覧からは、ID と名前だけを取り出す（繋ぎ先は持たない）'
Assert-Equal (ConvertFrom-OrcaEnvironmentList '{"ok":true,"result":{"environments":[]}}').Count 0 'ペアリング先がなければ空'
Assert-Throws { ConvertFrom-OrcaEnvironmentList '{"ok":false}' } 'ペアリング先の一覧が失敗なら例外'

$psJson = ConvertTo-OrcaPsJson @(
    (New-OrcaWorktree 'proj-a' '/home/user/proj-a' @(
            (New-OrcaAgent 'tab1:leaf1' 'working' -At 1000)
            (New-OrcaAgent 'tab1:leaf2' 'done' -Type 'codex' -At 2000)
            (New-OrcaAgent 'tab1:leaf3' 'done' -At 3000 -Interrupted)
            (New-OrcaAgent 'tab1:leaf4' 'working' -Parent 'tab1:leaf1')
            (New-OrcaAgent 'tab1:leaf5' 'working' -Type 'gemini')
            (New-OrcaAgent 'tab 1:leaf6' 'working')
            (New-OrcaAgent 'tab1:leaf1' 'done')
        ))
    (New-OrcaWorktree "proj-b`nx" '/home/user/proj-b' @(
            (New-OrcaAgent 'tab2:leaf1' 'idle' -At 4000)
            (New-OrcaAgent 'tab2:leaf2' 'blocked' -At 5000)
            (New-OrcaAgent 'tab2:leaf3' 'Weird State!' -At 6000)
            (New-OrcaAgent 'tab2:leaf4' 'waiting' -At 7000 -Program 'blocked')
            (New-OrcaAgent 'tab2:leaf5' 'busy' -At 8000)
            (New-OrcaAgent 'tab2:leaf6' 'waiting' -At 9000 -Program 'working')
            (New-OrcaAgent 'tab2:leaf7' 'waiting' -At 9500)
        ))
    (New-OrcaWorktree 'empty' '/home/user/empty')
)
$remote = ConvertTo-OrcaRemoteSessions -Json $psJson -EnvId $envA
Assert-Equal (@($remote | ForEach-Object { Format-OrcaSession $_ }) -join "`n") (@(
        "orca:${envA}:tab1:leaf1|busy|False|proj-a|/home/user/proj-a|claude|1000|True|"
        "orca:${envA}:tab1:leaf2|idle|True|proj-a|/home/user/proj-a|codex|2000|False|"
        "orca:${envA}:tab1:leaf3|idle|False|proj-a|/home/user/proj-a|claude|3000|False|"
        "orca:${envA}:tab2:leaf1|idle|False|proj-b x|/home/user/proj-b|claude|4000|False|"
        "orca:${envA}:tab2:leaf2|blocked|False|proj-b x|/home/user/proj-b|claude|5000|False|"
        "orca:${envA}:tab2:leaf4|waiting|False|proj-b x|/home/user/proj-b|claude|7000|True|permission prompt"
        "orca:${envA}:tab2:leaf6|waiting|False|proj-b x|/home/user/proj-b|claude|9000|True|"
        "orca:${envA}:tab2:leaf7|waiting|False|proj-b x|/home/user/proj-b|claude|9500|True|"
    ) -join "`n") 'working は実行中、waiting は待ち（Orca が止まっていると見ていれば許可待ち）、done は完了、中断した done と idle は待機。知らない状態はそのまま出す。子の区画、ほかのエージェント、形の違う区画、重なり、形の違う状態、andon の状態の名前（busy）は出さない'
Assert-Equal (@($remote[0].PSObject.Properties.Name) -join ',') 'Key,Status,WaitingFor,Done,Name,Cwd,Agent,PaneKey,At,Active' 'プロンプト、返事、ツールの入力は取り出さない'
Assert-True (-not ((ConvertTo-Json -Depth 5 $remote) -match 'secret')) '取り出したものに、プロンプトや返事の文字が入っていない'
Assert-Equal (ConvertTo-OrcaRemoteSessions -Json (ConvertTo-OrcaPsJson @()) -EnvId $envA).Count 0 'workspace がなければ空'
$named = ConvertTo-OrcaRemoteSessions -EnvId $envA -Json (ConvertTo-OrcaPsJson @(
        (New-OrcaWorktree 'main' '/home/user/proj-a' @((New-OrcaAgent 'n:1' 'working')) -Repo "proj-a`n")
        (New-OrcaWorktree '' '/home/user/proj-b' @((New-OrcaAgent 'n:2' 'working')) -Repo 'proj-b')
        (New-OrcaWorktree 'feature' '/home/user/proj-c' @((New-OrcaAgent 'n:3' 'working')) -Repo 7)
        (New-OrcaWorktree '' '/home/user/proj-d' @((New-OrcaAgent 'n:4' 'working')))
    ))
Assert-Equal (@($named | ForEach-Object { $_.Name }) -join '|') 'proj-a : main|proj-b|feature|' '名前は「プロジェクトの名前 : workspace の名前」。片方しかなければ、ある方だけ。文字でないプロジェクトの名前は使わない（D-151）'
Assert-Throws { ConvertTo-OrcaRemoteSessions -Json (ConvertTo-OrcaPsJson @() -Truncated $true) -EnvId $envA } '一覧が切れていれば例外（切れた分を、終わったものとして消さない）'
Assert-Throws { ConvertTo-OrcaRemoteSessions -Json (ConvertTo-OrcaPsJson @() -Ok $false) -EnvId $envA } 'ok でなければ例外'
Assert-Throws { ConvertTo-OrcaRemoteSessions -Json $psJson -EnvId 'bad id' } 'ペアリング先の ID の形が違えば例外'
$noAt = ConvertTo-OrcaRemoteSessions -Json '{"ok":true,"result":{"worktrees":[{"displayName":5,"path":null,"agents":[{"paneKey":"t:l","state":"working","agentType":"claude","stateStartedAt":"abc"},{"paneKey":"t:m","state":5,"agentType":"claude"},null]},null]}}' -EnvId $envB
Assert-Equal (@($noAt | ForEach-Object { Format-OrcaSession $_ }) -join "`n") 'orca:env-b:t:l|busy|False|||claude|0|True|' '名前、パス、時刻が思った型でなくても読む。状態が文字でない行は出さない'

Write-Host '== Orca のリモートのセッションの取り込み（Update-OrcaRemoteState）'
function New-RemoteSession {
    param([string]$Pane, [string]$Status, [long]$At, [switch]$Done, [string]$Agent = 'claude', [string]$Env = $envA)
    return [pscustomobject]@{ Key = "orca:${Env}:$Pane"; Status = $Status; WaitingFor = ''; Done = [bool]$Done; Name = "n-$Pane"; Cwd = "/home/user/$Pane"
        Agent = $Agent; PaneKey = $Pane; At = $At; Active = ($Status -eq 'busy' -or $Status -eq 'waiting') }
}
$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 1 'busy')) -Now $t0
$null = Update-CodexState -Sessions @((New-CodexSession 'c' 'busy' 1)) -Now $t0
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'busy' 10), (New-RemoteSession 'a:2' 'idle' 20 -Done), (New-RemoteSession 'a:3' 'blocked' 30)) -EnvId $envA -EnvName 'Work Laptop' -Now $t0
$ka1 = "orca:${envA}:a:1"; $ka2 = "orca:${envA}:a:2"; $ka3 = "orca:${envA}:a:3"
Assert-Equal $alert $false '初めて見た実行中・完了・知らない状態は、知らせない'
$e = $script:State[$ka1]
Assert-Equal "$($e.Kind)|$($e.Sdk)|$($e.Agent)|$($e.Name)|$($e.Cwd)|$($e.Remote.EnvId)|$($e.Remote.EnvName)|$($e.Remote.PaneKey)" "orca|False|claude|n-a:1|/home/user/a:1|$envA|Work Laptop|a:1" 'リモートのセッションの項目'
Assert-Equal "$(Get-StatusLabel $script:State[$ka1])|$(Get-StatusLabel $script:State[$ka2])|$(Get-StatusLabel $script:State[$ka3])|$(Get-Rank $script:State[$ka3])" '実行中|待機|blocked|3' '初めて見た完了は既読（待機）。知らない状態は、そのまま出し、並びは待機と同じ'
Assert-Equal (Get-SessionWindowProcessId $script:State[$ka1]) 0 'リモートのセッションは、この PC のウィンドウを探さない'
Assert-Equal (Find-SessionWindow -Entry $script:State[$ka1] -Processes $sessionProcs -Windows $sessionWins -AppWindows $sessionApps) $null 'リモートのセッションのウィンドウは、見つからない'
Assert-Equal (Get-EntryFolder $script:State[$ka1]) 'Work Laptop: /home/user/a:1' '「フォルダ」には、ペアリング先の名前を前に付ける'
Assert-Equal (Get-EntryFolder $script:State['1']) $script:State['1'].Cwd 'リモートでないセッションの「フォルダ」は、作業フォルダのまま'
Assert-Equal (Test-SessionVisible $script:State[$ka2]) $true 'リモートのセッションは、待機でも一覧に出す'

$t1 = $t0.AddSeconds(10)
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'idle' 11 -Done), (New-RemoteSession 'a:2' 'idle' 20 -Done), (New-RemoteSession 'a:3' 'blocked' 30)) -EnvId $envA -EnvName 'Work Laptop' -Now $t1
Assert-Equal "$alert|$(Get-StatusLabel $script:State[$ka1])|$($script:State[$ka1].AlertAt -eq $t1)|$(Get-StatusLabel $script:State[$ka2])" 'True|完了|True|待機' '実行中から完了になったら知らせる。変わっていない完了は、知らせない'
$notice = Get-AlertNotice -Entries @($script:State.Values) -Now $t1
Assert-Equal "$($notice.Title)|$($notice.Text)|$($notice.Key)" "Claude Code が完了しました|完了: n-a:1|$ka1" 'リモートのセッションの完了の通知'
$script:State[$ka1].Unread = $false
$t2 = $t0.AddSeconds(70)
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'idle' 11 -Done), (New-RemoteSession 'a:2' 'idle' 25 -Done -Agent 'codex')) -EnvId $envA -EnvName 'Work Laptop' -Now $t2
Assert-Equal "$alert|$(Get-StatusLabel $script:State[$ka1])|$(Get-StatusLabel $script:State[$ka2])|$($script:State.ContainsKey($ka3))" 'True|待機|完了|False' '実行中を見ないまま次の完了になったら（時刻が変わった）、知らせる。既読にした完了は、変わらなければ既読のまま。一覧にないものは消す'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t2).Title 'Codex が完了しました' 'リモートの Codex の通知の題'
Assert-Equal "$(Get-SessionAgent $script:State[$ka2])|$(Get-SessionAgent $script:State[$ka1])" 'codex|claude' 'リモートのセッションのエージェントの種類'
$t3 = $t0.AddSeconds(80)
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'busy' 40), (New-RemoteSession 'a:2' 'idle' 26)) -EnvId $envA -EnvName 'Work Laptop' -Now $t3
Assert-Equal "$alert|$(Get-StatusLabel $script:State[$ka1])|$(Get-StatusLabel $script:State[$ka2])" 'False|実行中|完了' '完了でない待機（中断など）に時刻だけ変わっても、知らせず、未確認の完了はそのまま'
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'idle' 41)) -EnvId $envA -EnvName 'Work Laptop' -Now $t3.AddSeconds(10)
Assert-Equal "$alert|$(Get-StatusLabel $script:State[$ka1])" 'False|待機' '実行中から、完了でない待機（中断）になっても、知らせない'
$alert = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'b:1' 'waiting' 1 -Env $envB), (New-RemoteSession 'x:1' 'busy' 1 -Env 'other')) -EnvId $envB -EnvName 'B' -Now $t3
Assert-Equal "$alert|$($script:State.ContainsKey("orca:env-b:b:1"))|$($script:State.ContainsKey('orca:other:x:1'))|$($script:State.ContainsKey($ka1))" 'True|True|False|True' '初めて見た待ちは知らせる。ほかのペアリング先のキーは取り込まず、ほかのペアリング先のセッションは消さない'
$null = Update-SessionState -Sessions @((New-Session 2 'idle')) -Now $t3
$null = Update-CodexState -Sessions @() -Now $t3
Assert-Equal "$($script:State.ContainsKey($ka1))|$($script:State.ContainsKey('1'))|$($script:State.ContainsKey('codex:c'))" 'True|False|False' 'Claude と Codex の一覧は、リモートのセッションを消さない'
$null = Update-OrcaRemoteState -Sessions @() -EnvId $envA -EnvName 'Work Laptop' -Now $t3
Assert-Equal "$($script:State.ContainsKey($ka1))|$($script:State.ContainsKey('2'))|$($script:State.ContainsKey('orca:env-b:b:1'))" 'False|True|True' 'リモートの一覧は、そのペアリング先のセッションだけを消す'
$null = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'busy' 1)) -EnvId $envA -EnvName 'Work Laptop' -Now $t3
Assert-Equal "$(Clear-OrcaRemoteState -EnvId $envB)|$($script:State.ContainsKey('orca:env-b:b:1'))|$($script:State.ContainsKey($ka1))" 'True|False|True' 'ペアリング先を指定して消す'
Assert-Equal "$(Clear-OrcaRemoteState)|$($script:State.ContainsKey($ka1))|$($script:State.ContainsKey('2'))|$(Clear-OrcaRemoteState)" 'True|False|True|False' 'リモートのセッションを全部消す。ほかは消さない'

Write-Host '== Orca のリモートのセッションの通知と、取りに行く間隔'
$script:State = @{}
$null = Update-SessionState -Sessions @((New-Session 1 'waiting')) -Now $t0
$null = Update-OrcaRemoteState -Sessions @((New-RemoteSession 'a:1' 'waiting' 1)) -EnvId $envA -EnvName 'Work Laptop' -Now $t0
$quiet = Get-OrcaSessionKeys -Windows $null -Entries @($script:State.Values)
Assert-Equal (@($quiet.Keys) -join ',') $ka1 'リモートのセッションは、ウィンドウを調べられなくても Orca のセッション（通知しない設定で、通知から外す）'
Assert-Equal (Get-AlertNotice -Entries @($script:State.Values) -Now $t0 -Quiet $quiet).Text '待ち: s1' '通知しない設定では、リモートのセッションを通知に載せない'
Assert-Equal (@((Get-OrcaSessionKeys -Windows @{ '83' = (Find-SessionConsoleWindow -Processes $sessionProcs -Windows $sessionWins -Id 83 -AppWindows $sessionApps) } -Entries @($script:State.Values)).Keys | Sort-Object) -join ',') "83,$ka1" '区画のセッションとリモートのセッションの両方を選ぶ'
$script:State = @{}

Assert-Equal "$(Get-OrcaRemoteInterval -Sessions @((New-RemoteSession 'a:1' 'idle' 1 -Done), (New-RemoteSession 'a:2' 'busy' 1)))|$(Get-OrcaRemoteInterval -Sessions @((New-RemoteSession 'a:1' 'waiting' 1)))" '10|10' '実行中か待ちのセッションがあれば、10 秒ごと'
Assert-Equal "$(Get-OrcaRemoteInterval -Sessions @((New-RemoteSession 'a:1' 'idle' 1 -Done), (New-RemoteSession 'a:3' 'blocked' 1)))|$(Get-OrcaRemoteInterval -Sessions @())|$(Get-OrcaRemoteInterval -Sessions $null)" '60|60|60' '完了や待機だけ、または 1 つもなければ、60 秒ごと'
Assert-Equal (Get-OrcaRemoteInterval -Sessions @((New-RemoteSession 'a:2' 'busy' 1)) -Failed) 60 '読めなかったあとは、60 秒あける'

function Get-TestStep { param([int]$Selected = 1, [bool]$OrcaRunning = $true, [bool]$Running = $false, [bool]$Completed = $false, $Started = $null, $Next = $null) return Get-OrcaRemoteStep -Now $t0 -Selected $Selected -OrcaRunning $OrcaRunning -Running $Running -Completed $Completed -Started $Started -Next $Next }
Assert-Equal "$(Get-TestStep -Selected 0)|$(Get-TestStep -Selected 0 -Running $true -Completed $true)" 'clear|clear' 'ペアリング先を選んでいなければ、読まない'
Assert-Equal "$(Get-TestStep -OrcaRunning $false)|$(Get-TestStep -OrcaRunning $false -Running $true)" 'clear|clear' 'Orca が動いていなければ、読まない（動かしている CLI も止める）'
Assert-Equal "$(Get-TestStep)|$(Get-TestStep -Next $t0)|$(Get-TestStep -Next $t0.AddSeconds(-1))" 'start|start|start' '次に読む時刻になったら（決まっていなければすぐ）、CLI を起動する'
Assert-Equal (Get-TestStep -Next $t0.AddSeconds(1)) 'none' '次に読む時刻の前は、何もしない'
Assert-Equal "$(Get-TestStep -Running $true -Started $t0.AddSeconds(-5))|$(Get-TestStep -Running $true -Started $t0.AddSeconds(-15))" 'wait|wait' 'CLI が返るまで待つ（15 秒まで）'
Assert-Equal (Get-TestStep -Running $true -Started $t0.AddSeconds(-16)) 'timeout' '15 秒を過ぎても返らなければ、止める'
Assert-Equal "$(Get-TestStep -Running $true -Completed $true -Started $t0.AddSeconds(-1))|$(Get-TestStep -Running $true -Completed $true -Started $t0.AddSeconds(-60))" 'collect|collect' 'CLI が返ったら、取り込む'

$paneTerms = @(
    [pscustomobject]@{ handle = 'term_1'; tabId = 'tab1'; leafId = 'leaf1' }
    [pscustomobject]@{ handle = 'term_2'; tabId = 'tab1'; leafId = 'leaf2' }
    [pscustomobject]@{ handle = 'term_3'; tabId = 'dup'; leafId = 'x' }
    [pscustomobject]@{ handle = 'term_4'; tabId = 'dup'; leafId = 'x' }
    [pscustomobject]@{ handle = 'bad handle'; tabId = 'tab9'; leafId = 'leaf9' }
    [pscustomobject]@{ handle = 'term_5'; tabId = $null; leafId = 'leaf1' }
    $null
)
Assert-Equal "$(Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'tab1:leaf2')|$(Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'tab1:leaf1')" 'term_2|term_1' '区画（tabId:leafId）が同じターミナルの handle を選ぶ'
Assert-Equal "$($null -eq (Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'dup:x'))|$($null -eq (Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'tab9:leaf9'))|$($null -eq (Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'none:none'))|$($null -eq (Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey ''))|$($null -eq (Select-OrcaTerminalByPane -Terminals $paneTerms -PaneKey 'TAB1:leaf1'))" 'True|True|True|True|True' '2 つ以上ある、handle の形が違う、ない、区画が空、大文字・小文字が違うときは、選ばない'

Assert-Equal ((ConvertFrom-OrcaRemoteSetting "$envA; env-b ;bad id;;$envA") -join ',') "$envA,env-b" '覚えたペアリング先の ID は、形の合うものだけ。重なりは除く'
Assert-Equal "$((ConvertFrom-OrcaRemoteSetting $null).Count)|$((ConvertFrom-OrcaRemoteSetting 5).Count)|$((ConvertFrom-OrcaRemoteSetting '').Count)|$((ConvertFrom-OrcaRemoteSetting ((1..20 | ForEach-Object { "e$_" }) -join ';')).Count)" '0|0|0|16' '文字でない、空なら 0 個。16 個まで'

# ---------------------------------------------------------------------------
$passed = $script:Count - $script:Failures
Write-Host ''
Write-Host "$passed / $($script:Count) passed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
