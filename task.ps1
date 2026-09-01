param(
    [Parameter(Position = 0)]
    [string]$Command = "list",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

Add-Type -AssemblyName System.Net.Http

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Join-Path $env:USERPROFILE ".taskmanager"
}

$envFile = Join-Path $scriptDir ".env"
$tasksFile = Join-Path $scriptDir "tasks.json"
$skillsFile = Join-Path $scriptDir "skills.txt"

$envConfig = @{}
if (Test-Path $envFile) {
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $k = $parts[0].Trim()
            $v = $parts[1].Trim().Trim('"').Trim("'")
            $envConfig[$k] = $v
        }
    }
}

$workCalendarUrl = if ($envConfig["WORK_CALENDAR_URL"]) { $envConfig["WORK_CALENDAR_URL"] } else { "" }
$gasSyncUrl = if ($envConfig["GAS_SYNC_URL"]) { $envConfig["GAS_SYNC_URL"] } else { "" }
$maskTitle = if ($envConfig["MASK_TITLE"] -eq "true") { $true } else { $false }
$defaultSyncDays = if ($envConfig["SYNC_DAYS"]) { [int]$envConfig["SYNC_DAYS"] } else { 30 }

if ([string]::IsNullOrWhiteSpace($workCalendarUrl)) {
    $configFile = Join-Path $scriptDir "config.json"
    if (Test-Path $configFile) {
        $legacyConfig = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $workCalendarUrl = $legacyConfig.workCalendarUrl
        $gasSyncUrl = $legacyConfig.gasSyncUrl
    }
}

function Get-SkillsText {
    if (-not (Test-Path $skillsFile)) {
        return ""
    }

    try {
        $content = Get-Content $skillsFile -Raw -Encoding UTF8
    }
    catch {
        try {
            $content = Get-Content $skillsFile -Raw -Encoding Default
        }
        catch {
            return ""
        }
    }

    if ($null -eq $content) {
        return ""
    }

    return $content.Trim()
}

function Get-WorkCalendarEvents {
    param(
        [datetime]$StartDate = (Get-Date),
        [int]$Days = 30
    )

    if ([string]::IsNullOrWhiteSpace($workCalendarUrl)) {
        Write-Warning "WORK_CALENDAR_URL is not configured in .env"
        return @()
    }

    try {
        $client = [System.Net.WebClient]::new()
        $client.Encoding = [System.Text.Encoding]::UTF8
        $rawIcs = $client.DownloadString($workCalendarUrl)
    }
    catch {
        Write-Warning "Could not fetch work calendar: $_"
        return @()
    }

    $unfolded = [System.Text.RegularExpressions.Regex]::Replace($rawIcs, "\r?\n[ \t]", "")
    $eventMatches = [System.Text.RegularExpressions.Regex]::Matches($unfolded, "BEGIN:VEVENT([\s\S]*?)END:VEVENT")

    $targetDates = @()
    for ($i = 0; $i -lt $Days; $i++) {
        $targetDates += $StartDate.AddDays($i).ToString("yyyyMMdd")
    }

    $allEvents = @()
    $seenKeys = @{}

    foreach ($m in $eventMatches) {
        $block = $m.Groups[1].Value

        $summary = "(No Title)"
        if ($block -match "SUMMARY:(.*)") {
            $summary = $matches[1].Trim() -replace "\\,", "," -replace "\\;", ";" -replace "\\n", " "
        }

        $dtstartRaw = ""
        $isAllDay = $false
        if ($block -match "DTSTART[^:]*:([0-9]{8}(T[0-9]{6}Z?)?)") {
            $dtstartRaw = $matches[1]
        }

        $dtendRaw = ""
        if ($block -match "DTEND[^:]*:([0-9]{8}(T[0-9]{6}Z?)?)") {
            $dtendRaw = $matches[1]
        }

        if ($block -match "STATUS:CANCELLED") {
            continue
        }

        $datePart = if ($dtstartRaw.Length -ge 8) { $dtstartRaw.Substring(0, 8) } else { "" }
        if ($targetDates -contains $datePart) {
            $startTimeStr = ""
            $endTimeStr = ""
            $isoStart = ""
            $isoEnd = ""

            $y = $datePart.Substring(0, 4)
            $M = $datePart.Substring(4, 2)
            $d = $datePart.Substring(6, 2)

            if ($dtstartRaw.Length -eq 8) {
                $isAllDay = $true
                $startTimeStr = "ALL DAY"
                $endTimeStr = ""
                $isoStart = "$($y)-$($M)-$($d)T00:00:00+09:00"
                $isoEnd = "$($y)-$($M)-$($d)T23:59:59+09:00"
            }
            else {
                $timePart = $dtstartRaw.Substring(9, 4)
                $hh = $timePart.Substring(0, 2)
                $mm = $timePart.Substring(2, 2)
                $startTimeStr = "$($hh):$($mm)"
                $isoStart = "$($y)-$($M)-$($d)T$($hh):$($mm):00+09:00"

                if ($dtendRaw.Length -ge 13) {
                    $endTimePart = $dtendRaw.Substring(9, 4)
                    $ehh = $endTimePart.Substring(0, 2)
                    $emm = $endTimePart.Substring(2, 2)
                    $ey = $dtendRaw.Substring(0, 4)
                    $eM = $dtendRaw.Substring(4, 2)
                    $ed = $dtendRaw.Substring(6, 2)
                    $endTimeStr = "$($ehh):$($emm)"
                    $isoEnd = "$($ey)-$($eM)-$($ed)T$($ehh):$($emm):00+09:00"
                }
                else {
                    $endTimeStr = ""
                    $isoEnd = "$($y)-$($M)-$($d)T$($hh):$($mm):00+09:00"
                }
            }

            $key = "$summary|$dtstartRaw|$dtendRaw"
            if ($seenKeys.ContainsKey($key)) { continue }
            $seenKeys[$key] = $true

            $allEvents += [PSCustomObject]@{
                Summary = $summary
                IsAllDay = $isAllDay
                StartTimeStr = $startTimeStr
                EndTimeStr = $endTimeStr
                StartRaw = $dtstartRaw
                EndRaw = $dtendRaw
                IsoStart = $isoStart
                IsoEnd = $isoEnd
                DateStr = "$($y)/$($M)/$($d)"
            }
        }
    }

    return @($allEvents | Sort-Object StartRaw)
}

function Get-Tasks {
    if (-not (Test-Path $tasksFile)) { return @() }

    try {
        $content = Get-Content $tasksFile -Raw -Encoding UTF8
    }
    catch {
        try {
            $content = Get-Content $tasksFile -Raw -Encoding Default
        }
        catch {
            return @()
        }
    }

    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    try {
        $parsed = $content | ConvertFrom-Json
    }
    catch {
        return @()
    }

    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Save-Tasks($tasks) {
    $arr = @($tasks)
    $json = $arr | ConvertTo-Json -Depth 5
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($tasksFile, $json, $utf8Bom)
}

function Get-DisplayDateText {
    param(
        [datetime]$DateValue = (Get-Date)
    )

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo("ja-JP")
    $dayName = $culture.DateTimeFormat.GetDayName($DateValue.DayOfWeek)
    return $DateValue.ToString("yyyy/MM/dd") + " (" + $dayName + ")"
}

function New-InitPrompt {
  $lines = @(
    '【役割】',
    'あなたは親切で優秀な「タスク管理専属アシスタントAI」です。',
    'ユーザーがコマンドの仕様や使い方を知らなくても、対話を通じてローカルスクリプト（.\task.ps1）を簡単に操作できるようにサポートしてください。',
    '',
    '【基本動作ルール】',
    '1. 最初に必ず挨拶をし、「本日実行できること」を分かりやすくメニュー形式（選択肢）で案内してください。',
    '2. ユーザーが「日報出したい」「これ終わった」「予定同期して」など雑な指示を出してきたら、意図を汲み取って実行すべき PowerShell コマンドを生成してください。',
    '3. コマンドを出力する際は、ユーザーがワンクリックでコピーしてPowerShellに貼り付けられるよう、必ず ```powershell ... ``` のコードブロックの中にまとめて出力してください。',
    '4. 【最重要ルール】コマンドの実行ファイル名は、必ず「.\task.ps1」から始めてください。「task」単体や「task.ps1」だけで出力することは厳禁です。',
    '',
    '【利用可能なコマンド仕様一覧】',
    '・タスク追加: .\task.ps1 add "<タイトル>" [優先度: high/med/low] [見積時間(分)] (優先度デフォルト: med, 時間デフォルト: 30)',
    '・タスク完了: .\task.ps1 done <ID>',
    '・タスク削除: .\task.ps1 del <ID>',
    '・タスク一覧表示: .\task.ps1 list',
    '・カレンダー表示: .\task.ps1 cal',
    '・カレンダー同期: .\task.ps1 sync',
    '・日報用プロンプト作成: .\task.ps1 report',
    '・初期化プロンプト作成: .\task.ps1 start',
    '',
    '【出力イメージ】',
    '初回応答時:',
    '「こんにちは！今日のタスク管理・業務サポートを担当します。本日は何をしますか？',
    ' 1. タスクの確認・追加・完了処理',
    ' 2. Googleカレンダーの確認・同期 (.\task.ps1 sync / .\task.ps1 cal)',
    ' 3. 本日の日報作成 (.\task.ps1 report)',
    '指示を直接入力するか、番号で教えてくださいね！」',
    '',
    'ユーザーが「日報出したい」と言った場合:',
    '「了解しました！日報作成用のデータを抽出するコマンドを用意しました。こちらをPowerShellに貼り付けて実行してください！」',
    '```powershell',
    '.\task.ps1 report',
    '```',
    '',
    '【スタート指示】',
    'このルールを理解したら、まずはユーザーに対して「本日何をお手伝いするか」の選択肢メニューを提示して話しかけてください。'
)

    return ($lines -join "`r`n")
}

function New-DailyReportPrompt {
    param(
        [datetime]$Today = (Get-Date)
    )

    $tasks = @(Get-Tasks)
    $doneToday = @()
    foreach ($task in $tasks) {
        if ($task.status -ne "DONE") { continue }
        if ([string]::IsNullOrWhiteSpace($task.completedAt)) { continue }

        try {
            $completedAtValue = [datetime]::Parse($task.completedAt)
        }
        catch {
            continue
        }

        if ($completedAtValue.Date -eq $Today.Date) {
            $doneToday += $task
        }
    }

    $todoTasks = @($tasks | Where-Object { $_.status -eq "TODO" })
    $calendarEvents = @(Get-WorkCalendarEvents -StartDate $Today -Days 1)
    $skillsText = Get-SkillsText
    if ([string]::IsNullOrWhiteSpace($skillsText)) {
        $skillsText = "（空）"
    }

    $doneLines = @()
    if ($doneToday.Count -eq 0) {
        $doneLines += "- 今日は完了したタスクはありません。"
    }
    else {
        foreach ($task in $doneToday) {
            $doneLines += ("- #{0} {1} ({2})" -f $task.id, $task.title, $task.completedAt)
        }
    }

    $calendarLines = @()
    if ($calendarEvents.Count -eq 0) {
        $calendarLines += "- 本日の予定はありません。"
    }
    else {
        foreach ($event in $calendarEvents) {
            if ($event.IsAllDay) {
                $calendarLines += ("- {0} (終日)" -f $event.Summary)
            }
            else {
                $calendarLines += ("- {0} {1} - {2}" -f $event.StartTimeStr, $event.EndTimeStr, $event.Summary)
            }
        }
    }

    $todoLines = @()
    if ($todoTasks.Count -eq 0) {
        $todoLines += "- 残タスクはありません。"
    }
    else {
        foreach ($task in $todoTasks) {
            $priorityText = if ($null -ne $task.priority) { $task.priority.ToString().ToUpper() } else { "MED" }
            $todoLines += ("- #{0} [{1}] {2} ({3}m)" -f $task.id, $priorityText, $task.title, $task.estMinutes)
        }
    }

    $promptLines = @(
        '以下の情報を基に、指定フォーマットで日本語の日報を作成してください。',
        '',
        '[本日完了したタスク]'
    )
    $promptLines += $doneLines
    $promptLines += @(
        '',
        '[本日のカレンダー予定]'
    )
    $promptLines += $calendarLines
    $promptLines += @(
        '',
        '[明日以降の残タスク]'
    )
    $promptLines += $todoLines
    $promptLines += @(
        '',
        '[skills.txt の内容]',
        $skillsText,
        '',
        '【出力フォーマット】',
        ('【 ' + (Get-DisplayDateText -DateValue $Today) + ' 】'),
        '',
        '■ 今日の進捗',
        ' - [完了タスク・実績]',
        '',
        '■ 明日やること',
        ' - [残タスク・予定]',
        '',
        '■ 所感',
        ' [ユーザーのメモとskillsのルールを元に作成した文章]',
        '',
        '※ Geminiへ貼る際は、最後に 『■ 本日のメモ: 〜』 を追加して送信してください。'
    )

    return ($promptLines -join "`r`n")
}

function Show-CopiedPrompt {
    param(
        [string]$Title,
        [string]$Prompt
    )

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "---------------------------------------------" -ForegroundColor DarkGray

    try {
        Set-Clipboard -Value $Prompt
        Write-Host "[OK] Prompt copied to the clipboard." -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Clipboard copy failed in this environment." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host $Prompt -ForegroundColor White
    Write-Host "---------------------------------------------" -ForegroundColor DarkGray
}

$cmd = $Command.ToLower()

if ($cmd -eq "start") {
    $prompt = New-InitPrompt
    Show-CopiedPrompt -Title "[Task AI Init Prompt]" -Prompt $prompt
}
elseif ($cmd -eq "report") {
    $today = Get-Date
    $prompt = New-DailyReportPrompt -Today $today
    Show-CopiedPrompt -Title "[Daily Report Prompt]" -Prompt $prompt
}
elseif ($cmd -eq "sync") {
    $days = $defaultSyncDays
    if ($ArgsList.Count -ge 1) {
        $days = [int]$ArgsList[0]
    }
    if ([string]::IsNullOrWhiteSpace($gasSyncUrl)) {
        Write-Host "GAS_SYNC_URL is not configured in .env" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "[Syncing Work Calendar -> Private Google Calendar ($days Days)]" -ForegroundColor Cyan
    Write-Host "-------------------------------------------------------------"

    $events = Get-WorkCalendarEvents -StartDate (Get-Date) -Days $days
    if ($events.Count -eq 0) {
        Write-Host "No work events found for the next $days day(s)." -ForegroundColor DarkGray
        exit 0
    }

    Write-Host "Fetched $($events.Count) events from Work Calendar. Sending in bulk to GAS..." -ForegroundColor Yellow

    $eventPayloads = @()
    foreach ($e in $events) {
        $title = ""
        if ($maskTitle -eq $true) {
            $title = "[Work] Busy"
        }
        else {
            $title = "[Work] $($e.Summary)"
        }

        $eventPayloads += [PSCustomObject]@{
            title = $title
            startTime = $e.IsoStart
            endTime = $e.IsoEnd
        }
    }

    $bulkPayload = [PSCustomObject]@{
        events = $eventPayloads
    } | ConvertTo-Json -Depth 5

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(60)

    try {
        $content = New-Object System.Net.Http.StringContent($bulkPayload, [System.Text.Encoding]::UTF8, 'application/json')
        $res = $client.PostAsync($gasSyncUrl, $content).Result
        $body = $res.Content.ReadAsStringAsync().Result
        $jsonRes = $body | ConvertFrom-Json

        if ($jsonRes.status -eq "success") {
            Write-Host "  [OK] Successfully synchronized $days days of events!" -ForegroundColor Green
            Write-Host "       - Total Events Checked: $($jsonRes.total)" -ForegroundColor White
            Write-Host "       - Newly Created:        $($jsonRes.created)" -ForegroundColor Green
            Write-Host "       - Skipped (Existing):   $($jsonRes.skipped)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [!] Server responded: $body" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  [x] Error during bulk sync: $_" -ForegroundColor Red
    }

    Write-Host "============================================================="
}
elseif ($cmd -eq "cal") {
    $date = Get-Date
    Write-Host ""
    Write-Host "[Google Calendar (Work): $($date.ToString('yyyy/MM/dd dddd'))]" -ForegroundColor Cyan
    Write-Host "---------------------------------------------"
    $events = Get-WorkCalendarEvents -StartDate $date -Days 1
    if ($events.Count -eq 0) {
        Write-Host "No events scheduled for today." -ForegroundColor DarkGray
    }
    else {
        foreach ($e in $events) {
            if ($e.IsAllDay) {
                Write-Host ("  [ALL DAY]      {0}" -f $e.Summary) -ForegroundColor Magenta
            }
            else {
                Write-Host ("  [{0} - {1}]  {2}" -f $e.StartTimeStr, $e.EndTimeStr, $e.Summary) -ForegroundColor Yellow
            }
        }
    }
    Write-Host "---------------------------------------------"
}
elseif ($cmd -eq "add") {
    if ($ArgsList.Count -eq 0) {
        Write-Host "Usage: task add 'title' [priority: high/med/low] [est_minutes]" -ForegroundColor Red
        exit
    }

    $title = $ArgsList[0]
    $priority = if ($ArgsList.Count -ge 2) { $ArgsList[1] } else { "med" }
    $est = if ($ArgsList.Count -ge 3) { [int]$ArgsList[2] } else { 30 }

    $tasks = @(Get-Tasks)
    $nextId = 1
    if ($tasks.Count -gt 0) {
        $maxId = ($tasks | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum
        $nextId = $maxId + 1
    }

    $newTask = [PSCustomObject]@{
        id = $nextId
        title = $title
        priority = $priority
        estMinutes = $est
        status = "TODO"
        createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        completedAt = $null
    }
    $tasks += $newTask
    Save-Tasks $tasks
    Write-Host "[+] Added task #$($nextId): $title (Priority: $priority, Est: $($est)m)" -ForegroundColor Green
}
elseif ($cmd -eq "done") {
    if ($ArgsList.Count -eq 0) {
        Write-Host "Usage: task done [ID]" -ForegroundColor Red
        exit
    }

    $id = [int]$ArgsList[0]
    $tasks = @(Get-Tasks)
    $found = $false
    foreach ($t in $tasks) {
        if ($t.id -eq $id) {
            $t.status = "DONE"
            $t.completedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm")
            $found = $true
            Write-Host "[OK] Task #$($id) marked as completed: $($t.title)" -ForegroundColor Green
            break
        }
    }

    if (-not $found) {
        Write-Host "Task ID #$($id) not found." -ForegroundColor Red
    }
    else {
        Save-Tasks $tasks
    }
}
elseif ($cmd -eq "del") {
    if ($ArgsList.Count -eq 0) {
        Write-Host "Usage: task del [ID]" -ForegroundColor Red
        exit
    }

    $id = [int]$ArgsList[0]
    $tasks = @(Get-Tasks)
    $newTasks = @($tasks | Where-Object { $_.id -ne $id })
    Save-Tasks $newTasks
    Write-Host "[-] Deleted task #$($id)." -ForegroundColor Yellow
}
else {
    $date = Get-Date
    Write-Host ""
    Write-Host "[Today's Work Events ($($date.ToString('yyyy/MM/dd dddd')))]" -ForegroundColor Cyan
    Write-Host "---------------------------------------------"
    $events = Get-WorkCalendarEvents -StartDate $date -Days 1
    if ($events.Count -eq 0) {
        Write-Host "  No events scheduled for today." -ForegroundColor DarkGray
    }
    else {
        foreach ($e in $events) {
            if ($e.IsAllDay) {
                Write-Host ("  [ALL DAY]      {0}" -f $e.Summary) -ForegroundColor Magenta
            }
            else {
                Write-Host ("  [{0} - {1}]  {2}" -f $e.StartTimeStr, $e.EndTimeStr, $e.Summary) -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "[Tasks / Todo List]" -ForegroundColor Cyan
    Write-Host "---------------------------------------------"
    $tasks = @(Get-Tasks)
    $todoTasks = @($tasks | Where-Object { $_.status -eq "TODO" })
    $doneTasks = @($tasks | Where-Object { $_.status -eq "DONE" })

    if ($todoTasks.Count -eq 0 -and $doneTasks.Count -eq 0) {
        Write-Host "  No tasks registered yet." -ForegroundColor DarkGray
        Write-Host "  Tip: Tell me in chat or run 'task add <title>' to add a task." -ForegroundColor Gray
    }
    else {
        if ($todoTasks.Count -gt 0) {
            Write-Host " [TODO]" -ForegroundColor White
            foreach ($t in $todoTasks) {
                $priorityValue = if ($null -ne $t.priority) { $t.priority.ToString().ToLower() } else { "med" }
                $pBadge = switch ($priorityValue) {
                    "high" { "[HIGH]" }
                    "low"  { "[LOW] " }
                    default { "[MED] " }
                }
                Write-Host ("   [ ] #{0,-2} {1} {2,-30} ({3}m)" -f $t.id, $pBadge, $t.title, $t.estMinutes) -ForegroundColor White
            }
        }

        if ($doneTasks.Count -gt 0) {
            Write-Host ""
            Write-Host " [COMPLETED]" -ForegroundColor DarkGray
            foreach ($t in ($doneTasks | Select-Object -Last 5)) {
                Write-Host ("   [X] #{0,-2} {1}" -f $t.id, $t.title) -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "============================================="
}
