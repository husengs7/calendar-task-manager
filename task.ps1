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

    $rangeStart = $StartDate.Date
    $rangeEnd = $StartDate.AddDays([Math]::Max(1, $Days)).Date

    $unfolded = [System.Text.RegularExpressions.Regex]::Replace($rawIcs, "\r?\n[ \t]", "")
    $eventMatches = [System.Text.RegularExpressions.Regex]::Matches($unfolded, "BEGIN:VEVENT([\s\S]*?)END:VEVENT")

    $allEvents = @()
    $seenKeys = @{}

    foreach ($m in $eventMatches) {
        $block = $m.Groups[1].Value

        if ($block -match "STATUS:CANCELLED") {
            continue
        }

        $summary = "(No Title)"
        $summaryLine = ($block -split "`r?`n" | Where-Object { $_ -match "^SUMMARY(?:;[A-Z0-9=:/\-]+)?:" } | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($summaryLine)) {
            $summary = ($summaryLine -replace "^SUMMARY(?:;[A-Z0-9=:/\-]+)?:", "").Trim()
            $summary = $summary -replace "\\,", "," -replace "\\;", ";" -replace "\\n", " " -replace "\\N", " "
        }

        $dtstartLine = ($block -split "`r?`n" | Where-Object { $_ -match "^DTSTART(?:;[A-Z0-9=:/\-]+)?:" } | Select-Object -First 1)
        $dtendLine = ($block -split "`r?`n" | Where-Object { $_ -match "^DTEND(?:;[A-Z0-9=:/\-]+)?:" } | Select-Object -First 1)

        $dtstartRaw = if ($dtstartLine) { ($dtstartLine -replace "^DTSTART(?:;[A-Z0-9=:/\-]+)?:", "").Trim() } else { "" }
        $dtendRaw = if ($dtendLine) { ($dtendLine -replace "^DTEND(?:;[A-Z0-9=:/\-]+)?:", "").Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($dtstartRaw)) {
            continue
        }

        $datePart = ""
        if ($dtstartRaw -match "^(\d{8})") {
            $datePart = $matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($datePart)) {
            continue
        }

        $eventDt = [datetime]::ParseExact($datePart, "yyyyMMdd", $null)
        if ($eventDt -lt $rangeStart -or $eventDt -ge $rangeEnd) {
            continue
        }

        $isAllDay = $dtstartRaw -match "^\d{8}$" -or $dtstartRaw -match "^\d{8};VALUE=DATE$"
        $startTimeStr = ""
        $endTimeStr = ""
        $isoStart = ""
        $isoEnd = ""

        $y = $datePart.Substring(0, 4)
        $M = $datePart.Substring(4, 2)
        $d = $datePart.Substring(6, 2)

        if ($isAllDay) {
            $startTimeStr = "ALL DAY"
            $endTimeStr = ""
            $isoStart = "$($y)-$($M)-$($d)T00:00:00+09:00"
            $isoEnd = "$($y)-$($M)-$($d)T23:59:59+09:00"
        }
        else {
            $rawTime = $dtstartRaw -replace '^\d{8}T', ''
            $rawTime = $rawTime -replace 'Z$', ''
            if ($rawTime.Length -ge 4) {
                $hh = $rawTime.Substring(0, 2)
                $mm = $rawTime.Substring(2, 2)
                $startTimeStr = "$($hh):$($mm)"
                $isoStart = "$($y)-$($M)-$($d)T$($hh):$($mm):00+09:00"
            }

            if (-not [string]::IsNullOrWhiteSpace($dtendRaw) -and $dtendRaw -match '^\d{8}(T\d{4,6}Z?)?$') {
                $endDatePart = $dtendRaw.Substring(0, 8)
                $endTimePart = if ($dtendRaw.Length -gt 8) { $dtendRaw.Substring(9) } else { "" }
                $endTimePart = $endTimePart -replace 'Z$', ''
                if ($endTimePart.Length -ge 4) {
                    $ehh = $endTimePart.Substring(0, 2)
                    $emm = $endTimePart.Substring(2, 2)
                    $endTimeStr = "$($ehh):$($emm)"
                    $isoEnd = "$($endDatePart.Substring(0, 4))-$($endDatePart.Substring(4, 2))-$($endDatePart.Substring(6, 2))T$($ehh):$($emm):00+09:00"
                }
            }

            if ([string]::IsNullOrWhiteSpace($isoEnd)) {
                $endTimeStr = ""
                $isoEnd = $isoStart
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

function Get-ThisMonthLongEvents {
    $now = Get-Date
    $monthStart = [datetime]::ParseExact($now.ToString("yyyy-MM-01"), "yyyy-MM-dd", $null)
    $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
    $daysInMonth = [int](($monthEnd - $monthStart).TotalDays) + 1

    $events = @(Get-WorkCalendarEvents -StartDate $monthStart -Days $daysInMonth)
    $filtered = @()

    foreach ($event in $events) {
        $durationHours = 0
        $include = $false

        try {
            $startDt = [DateTimeOffset]::Parse($event.IsoStart)
            $endDt = [DateTimeOffset]::Parse($event.IsoEnd)
            $durationHours = ($endDt - $startDt).TotalHours
            if ($event.IsAllDay -and $durationHours -le 0) {
                $durationHours = 24
            }
            if ($durationHours -ge 3) {
                $include = $true
            }
        }
        catch {
            $include = $false
        }

        if ($include) {
            $filtered += [PSCustomObject]@{
                Summary = $event.Summary
                DateStr = $event.DateStr
                Start = $event.IsoStart
                End = $event.IsoEnd
                DurationHours = [math]::Round($durationHours, 1)
            }
        }
    }

    return @($filtered | Sort-Object Start)
}

function New-InitPrompt {
    $skillsText = Get-SkillsText
    if ([string]::IsNullOrWhiteSpace($skillsText)) {
        $skillsText = '（空）'
    }

    $thisMonthEvents = @(Get-ThisMonthLongEvents)
    $eventLines = @()
    if ($thisMonthEvents.Count -eq 0) {
        $eventLines += '- 今月の3時間以上の予定はありません。'
    }
    else {
        foreach ($event in $thisMonthEvents) {
            $eventLines += ("- {0} / {1} - {2} / 所要時間: {3}時間" -f $event.DateStr, $event.Summary, $event.Start, $event.DurationHours)
        }
    }

    $lines = @(
        '【役割】',
        'あなたは親切で優秀な「タスク管理専属アシスタントAI」です。',
        'ユーザーがコマンドの仕様や使い方を知らなくても、対話を通じてローカルスクリプト（.\task.ps1）を簡単に操作できるようにサポートしてください。',
        '今回の業務は Findy の DevRel インターン生として、開発者コミュニティ・技術広報・イベント運営・技術コンテンツ制作・社外連携を中心に行う。',
        '',
        '【基本動作ルール】',
        '1. 最初に必ず挨拶をし、「本日実行できること」を分かりやすくメニュー形式（選択肢）で案内してください。',
        '2. ユーザーが「日報出したい」「これ終わった」「予定同期して」など雑な指示を出してきたら、意図を汲み取って実行すべき PowerShell コマンドを生成してください。',
        '3. コマンドを出力する際は、ユーザーがワンクリックでコピーしてPowerShellに貼り付けられるよう、必ず ```powershell ... ``` のコードブロックの中にまとめて出力してください。',
        '4. 【最重要ルール】コマンドの実行ファイル名は、必ず「.\task.ps1」から始めてください。「task」単体や「task.ps1」だけで出力することは厳禁です。',
        '5. その月の 3時間以上の予定を必ず確認し、各イベントが業務にとって重要かどうか、準備が必要かどうかを判定してください。',
        '6. ユーザーの業務内容と優先度を踏まえて、外部影響・締切・コミュニティ価値・準備負荷を考慮し、必要なら「準備は大丈夫？」とリマインドしてください。',
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
        '【現在の業務コンテキスト / skills.txt】',
        $skillsText,
        '',
        '【今月の 3時間以上の予定】'
    )

    $lines += $eventLines

    $lines += @(
        '',
        '【判定の観点】',
        '・この予定が業務として重要かどうかを判断する',
        '・重要な場合は、準備が不足していないかを確認する',
        '・「準備は大丈夫？」と、必要なら短いリマインドを付ける',
        '・必要に応じて、優先度が高い順に整理してユーザーへ伝える',
        '',
        '【出力イメージ】',
        '初回応答時:',
        '「こんにちは！今月の重要イベントとタスク管理をサポートします。本日は何をしますか？',
        ' 1. タスクの確認・追加・完了処理',
        ' 2. Googleカレンダーの確認・同期 (.\task.ps1 sync / .\task.ps1 cal)',
        ' 3. 本日の日報作成 (.\task.ps1 report)',
        ' 4. 今月の重要イベントの確認と準備チェック',
        '指示を直接入力するか、番号で教えてくださいね！」',
        '',
        'ユーザーが「日報出したい」と言った場合:',
        '「了解しました！日報作成用のデータを抽出するコマンドを用意しました。こちらをPowerShellに貼り付けて実行してください！」',
        '```powershell',
        '.\task.ps1 report',
        '```',
        '',
        '【スタート指示】',
        'このルールを理解したら、まずはユーザーに対して「本日何をお手伝いするか」の選択肢メニューを提示して話しかけてください。',
        'そして今月の長時間予定を基に、業務上の優先度と準備状況を判断し、必要なら「準備は大丈夫？」とリマインドしてください。'
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
