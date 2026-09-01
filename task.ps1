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

# Load .env file
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

# Fallback to config.json if .env is missing
if ([string]::IsNullOrWhiteSpace($workCalendarUrl)) {
    $configFile = Join-Path $scriptDir "config.json"
    if (Test-Path $configFile) {
        $legacyConfig = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $workCalendarUrl = $legacyConfig.workCalendarUrl
        $gasSyncUrl = $legacyConfig.gasSyncUrl
    }
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
    } catch {
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
            } else {
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
                } else {
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
    $content = Get-Content $tasksFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }
    $parsed = $content | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Save-Tasks($tasks) {
    $arr = @($tasks)
    $json = $arr | ConvertTo-Json -Depth 5
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($tasksFile, $json, $utf8Bom)
}

$cmd = $Command.ToLower()

if ($cmd -eq "sync") {
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
        } else {
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
        } else {
            Write-Host "  [!] Server responded: $body" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [x] Error during bulk sync: $_" -ForegroundColor Red
    }

    Write-Host "============================================================="
} elseif ($cmd -eq "cal") {
    $date = Get-Date
    Write-Host ""
    Write-Host "[Google Calendar (Work): $($date.ToString('yyyy/MM/dd dddd'))]" -ForegroundColor Cyan
    Write-Host "---------------------------------------------"
    $events = Get-WorkCalendarEvents -StartDate $date -Days 1
    if ($events.Count -eq 0) {
        Write-Host "No events scheduled for today." -ForegroundColor DarkGray
    } else {
        foreach ($e in $events) {
            if ($e.IsAllDay) {
                Write-Host ("  [ALL DAY]      {0}" -f $e.Summary) -ForegroundColor Magenta
            } else {
                Write-Host ("  [{0} - {1}]  {2}" -f $e.StartTimeStr, $e.EndTimeStr, $e.Summary) -ForegroundColor Yellow
            }
        }
    }
    Write-Host "---------------------------------------------"
} elseif ($cmd -eq "add") {
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
        $nextId = ($tasks | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum + 1
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
} elseif ($cmd -eq "done") {
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
    } else {
        Save-Tasks $tasks
    }
} elseif ($cmd -eq "del") {
    if ($ArgsList.Count -eq 0) {
        Write-Host "Usage: task del [ID]" -ForegroundColor Red
        exit
    }
    $id = [int]$ArgsList[0]
    $tasks = @(Get-Tasks)
    $newTasks = @($tasks | Where-Object { $_.id -ne $id })
    Save-Tasks $newTasks
    Write-Host "[-] Deleted task #$($id)." -ForegroundColor Yellow
} else {
    $date = Get-Date
    Write-Host ""
    Write-Host "[Today's Work Events ($($date.ToString('yyyy/MM/dd dddd')))]" -ForegroundColor Cyan
    Write-Host "---------------------------------------------"
    $events = Get-WorkCalendarEvents -StartDate $date -Days 1
    if ($events.Count -eq 0) {
        Write-Host "  No events scheduled for today." -ForegroundColor DarkGray
    } else {
        foreach ($e in $events) {
            if ($e.IsAllDay) {
                Write-Host ("  [ALL DAY]      {0}" -f $e.Summary) -ForegroundColor Magenta
            } else {
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
    } else {
        if ($todoTasks.Count -gt 0) {
            Write-Host " [TODO]" -ForegroundColor White
            foreach ($t in $todoTasks) {
                $pBadge = switch ($t.priority.ToLower()) {
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
