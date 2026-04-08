# WU006_WUEventTimeline.ps1
# Scriptlet: WU006 - WU Event Log Timeline & HRESULT Deep Dive
# Context: System | Version: 1.3

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# Parameter: DaysBack (default 7)
# ============================================================
$daysBack = if ($Param1) { [int]$Param1 } else { 7 }
$startTime = (Get-Date).AddDays(-$daysBack)
$timelineLimit = 50

# ============================================================
# HRESULT Translation Map (25 entries)
# ============================================================
$hresultMap = @{
    '0x80072EFE' = @{ Msg = 'Connection interrupted -- server reset or dropped the connection mid-transfer.'; Action = 'Run WU003 WUNetworkCheck to diagnose connectivity.' }
    '0x80072EE7' = @{ Msg = 'DNS resolution failed -- server name could not be resolved.'; Action = 'Run WU003 WUNetworkCheck to diagnose DNS.' }
    '0x80072F8F' = @{ Msg = 'TLS/SSL certificate validation failed.'; Action = 'Run WU004 WUTlsCertCheck.' }
    '0x800B0109' = @{ Msg = 'Certificate chain error -- untrusted root or missing intermediate certificate.'; Action = 'Run WU004 WUTlsCertCheck.' }
    '0x80096004' = @{ Msg = 'Certificate trust failure.'; Action = 'Run WU004 WUTlsCertCheck.' }
    '0x80244010' = @{ Msg = 'Exceeded max server round trips -- WSUS overloaded or misconfigured.'; Action = 'Check WSUS server health and IIS application pool.' }
    '0x80244022' = @{ Msg = 'Update server returned HTTP 503 (service unavailable).'; Action = 'Check WSUS/CDN server health.' }
    '0x8024401C' = @{ Msg = 'Connection timed out waiting for update server response.'; Action = 'Run WU003 WUNetworkCheck.' }
    '0x80073712' = @{ Msg = 'Component store corruption -- WinSxS manifest or store inconsistency.'; Action = 'Run WU005 WUComponentHealth.' }
    '0x800F081F' = @{ Msg = 'Source files not found -- repair payload missing from local store and online.'; Action = 'Run WU005 WUComponentHealth.' }
    '0x800F0831' = @{ Msg = 'Component store corruption -- orphaned update manifest blocking dependency chain.'; Action = 'Run WU005 WUComponentHealth.' }
    '0x80070002' = @{ Msg = 'Required file not found -- corrupt store or missing payload.'; Action = 'Run WU005 WUComponentHealth.' }
    '0x80240024' = @{ Msg = 'Update not applicable to this system architecture or edition.'; Action = 'Informational -- usually not a problem.' }
    '0x80240017' = @{ Msg = 'Update not applicable to this system.'; Action = 'Informational -- usually not a problem.' }
    '0x80070643' = @{ Msg = 'MSI installer failure or WinRE recovery partition too small.'; Action = 'Check WinRE partition size. Manual resize may be needed.' }
    '0x800F0922' = @{ Msg = 'Safe OS phase failed -- WinRE partition issue or insufficient disk space.'; Action = 'Check WinRE partition and disk space.' }
    '0x80080005' = @{ Msg = 'Server execution failed -- COM/RPC infrastructure issue.'; Action = 'Run WU009 WUServiceReset.' }
    '0x8007000E' = @{ Msg = 'Out of memory during update operation.'; Action = 'Close applications and retry.' }
    '0x80070005' = @{ Msg = 'Access denied -- permission or security software blocking the operation.'; Action = 'Check third-party AV / Tamper Protection settings.' }
    '0x80070020' = @{ Msg = 'Sharing violation -- file locked by another process (commonly AV/EDR).'; Action = 'Check AV exclusions for WU paths.' }
    '0x800705B4' = @{ Msg = 'Operation timed out.'; Action = 'Run WU009 WUServiceReset.' }
    '0x80070BC9' = @{ Msg = 'Reboot required before this update can be installed.'; Action = 'Reboot the machine and retry.' }
    '0x8024002E' = @{ Msg = 'Windows Update administratively disabled by policy.'; Action = 'Run WU002 WUPolicyAudit.' }
    '0x80242014' = @{ Msg = 'Post-reboot finalization pending -- update is waiting for restart.'; Action = 'Reboot the machine.' }
    '0x80244019' = @{ Msg = 'WSUS server rejected the request (HTTP 503).'; Action = 'Check WSUS server health.' }
}

# ============================================================
# Event ID classification
# ============================================================
$wuFailureIds   = @(20, 25, 31)
$wuSuccessIds   = @(19, 26, 42)
$bitsFailureIds = @(60, 61, 64)
$bitsSuccessIds = @(4)
$scmEventIds    = @(7031, 7034, 7036, 7043)
$wuServiceNames = @('wuauserv', 'BITS', 'TrustedInstaller', 'UsoSvc', 'Windows Update', 'Background Intelligent Transfer', 'Windows Modules Installer')

# Dynamically add localized display names so SCM filtering works on non-English Windows
$localWUNames = @(Get-CimInstance Win32_Service -Filter "Name='wuauserv' OR Name='BITS' OR Name='TrustedInstaller' OR Name='UsoSvc'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
$searchNames = @($wuServiceNames) + @($localWUNames) | Select-Object -Unique

# ============================================================
# Collect events from all 3 sources
# ============================================================
$allEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

# Source 1: WindowsUpdateClient/Operational
$wuEventIds = @(19, 20, 21, 25, 26, 31, 41, 42, 43, 44)
try {
    $wuEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-WindowsUpdateClient/Operational'
        Id        = $wuEventIds
        StartTime = $startTime
    } -ErrorAction Stop)
    foreach ($evt in $wuEvents) {
        $msg = ''
        try { $msg = $evt.Message } catch { }
        if ($null -eq $msg) { $msg = '' }
        $shortMsg = if ($msg.Length -gt 200) { $msg.Substring(0, 197) + '...' } else { $msg }
        $shortMsg = $shortMsg -replace '[\r\n]+', ' '

        $evtType = 'Info'
        if ($wuFailureIds -contains $evt.Id) { $evtType = 'Failure' }
        elseif ($wuSuccessIds -contains $evt.Id) { $evtType = 'Success' }

        $allEvents.Add([PSCustomObject]@{
            Time    = $evt.TimeCreated
            Source  = 'WindowsUpdateClient'
            EventId = $evt.Id
            Type    = $evtType
            Message = $shortMsg
            RawMsg  = $msg
        })
    }
} catch { }

# Source 2: BITS-Client/Operational
$bitsEventIds = @(3, 4, 5, 59, 60, 64)
try {
    $bitsEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-BITS-Client/Operational'
        Id        = $bitsEventIds
        StartTime = $startTime
    } -ErrorAction Stop)
    foreach ($evt in $bitsEvents) {
        $msg = ''
        try { $msg = $evt.Message } catch { }
        if ($null -eq $msg) { $msg = '' }
        $shortMsg = if ($msg.Length -gt 200) { $msg.Substring(0, 197) + '...' } else { $msg }
        $shortMsg = $shortMsg -replace '[\r\n]+', ' '

        $evtType = 'Info'
        if ($bitsFailureIds -contains $evt.Id) { $evtType = 'Failure' }
        elseif ($bitsSuccessIds -contains $evt.Id) { $evtType = 'Success' }

        $allEvents.Add([PSCustomObject]@{
            Time    = $evt.TimeCreated
            Source  = 'BITS'
            EventId = $evt.Id
            Type    = $evtType
            Message = $shortMsg
            RawMsg  = $msg
        })
    }
} catch { }

# Source 3a: System log - WindowsUpdateClient events
try {
    $sysWuEvents = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
        StartTime    = $startTime
    } -ErrorAction Stop)
    foreach ($evt in $sysWuEvents) {
        $msg = ''
        try { $msg = $evt.Message } catch { }
        if ($null -eq $msg) { $msg = '' }
        $shortMsg = if ($msg.Length -gt 200) { $msg.Substring(0, 197) + '...' } else { $msg }
        $shortMsg = $shortMsg -replace '[\r\n]+', ' '

        $evtType = 'Info'
        if ($evt.Level -eq 1 -or $evt.Level -eq 2) { $evtType = 'Failure' }
        elseif ($wuSuccessIds -contains $evt.Id) { $evtType = 'Success' }

        $allEvents.Add([PSCustomObject]@{
            Time    = $evt.TimeCreated
            Source  = 'System-WUClient'
            EventId = $evt.Id
            Type    = $evtType
            Message = $shortMsg
            RawMsg  = $msg
        })
    }
} catch { }

# Source 3b: System log - Service Control Manager for WU services
try {
    $scmEvents = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Service Control Manager'
        Id           = $scmEventIds
        StartTime    = $startTime
    } -ErrorAction Stop)
    foreach ($evt in $scmEvents) {
        $msg = ''
        try { $msg = $evt.Message } catch { }
        if ($null -eq $msg) { $msg = '' }

        # Filter to WU-related services only
        $isWuService = $false
        foreach ($svcName in $searchNames) {
            if ($msg -match [regex]::Escape($svcName)) {
                $isWuService = $true
                break
            }
        }
        if (-not $isWuService) { continue }

        $shortMsg = if ($msg.Length -gt 200) { $msg.Substring(0, 197) + '...' } else { $msg }
        $shortMsg = $shortMsg -replace '[\r\n]+', ' '

        $evtType = 'Failure'
        if ($evt.Id -eq 7036) { $evtType = 'Info' }

        $allEvents.Add([PSCustomObject]@{
            Time    = $evt.TimeCreated
            Source  = 'SCM'
            EventId = $evt.Id
            Type    = $evtType
            Message = $shortMsg
            RawMsg  = $msg
        })
    }
} catch { }

# ============================================================
# Sort all events chronologically (newest first)
# ============================================================
$sortedEvents = $allEvents | Sort-Object -Property Time -Descending

$totalEvents   = $sortedEvents.Count
$failureEvents = @($sortedEvents | Where-Object { $_.Type -eq 'Failure' })
$successEvents = @($sortedEvents | Where-Object { $_.Type -eq 'Success' })
$infoEvents    = @($sortedEvents | Where-Object { $_.Type -eq 'Info' })
$failureCount  = $failureEvents.Count
$successCount  = $successEvents.Count
$infoCount     = $infoEvents.Count

# ============================================================
# Extract HRESULTs from failure events
# ============================================================
$hresultCounts = @{}
$hresultRegex = '0x[0-9A-Fa-f]{8}'

foreach ($evt in $failureEvents) {
    $rawMsg = $evt.RawMsg
    if ($null -eq $rawMsg -or $rawMsg.Length -eq 0) { continue }
    $matches2 = [regex]::Matches($rawMsg, $hresultRegex)
    $codesInEvent = @{}
    foreach ($m in $matches2) {
        $code = $m.Value.ToUpperInvariant() -replace '0X','0x'
        # Skip generic success/non-error codes
        if ($code -eq '0x00000000') { continue }
        $codesInEvent[$code] = $true
    }
    foreach ($code in $codesInEvent.Keys) {
        if (-not $hresultCounts.ContainsKey($code)) {
            $hresultCounts[$code] = 0
        }
        $hresultCounts[$code]++
    }
}

# Find most common error
$mostCommonCode = ''
$mostCommonCount = 0
foreach ($key in $hresultCounts.Keys) {
    if ($hresultCounts[$key] -gt $mostCommonCount) {
        $mostCommonCount = $hresultCounts[$key]
        $mostCommonCode = $key
    }
}

# ============================================================
# Check 1 -- Event Summary Statistics
# ============================================================
if ($totalEvents -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Event Overview'
        Status = 'OK'
        Detail = "No WU-related events found in the last $daysBack day(s). Either no update activity occurred, or event logs have been cleared."
    })
} else {
    $summaryLine = "$totalEvents events across all sources. $successCount success, $failureCount failure, $infoCount informational."
    if ($mostCommonCount -gt 0) {
        $summaryLine += "`n       Most common error: $mostCommonCode ($mostCommonCount occurrence(s))."
    }

    if ($failureCount -gt 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Event Overview'
            Status = 'ISSUE'
            Detail = $summaryLine
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Event Overview'
            Status = 'OK'
            Detail = $summaryLine
        })
    }
}

# ============================================================
# Output
# ============================================================
Write-Output ''
Write-Output '=== Windows Update Event Timeline ==='
Write-Output ''

# Summary
foreach ($f in $findings) {
    $icon = switch ($f.Status) {
        'OK'    { '[OK]  ' }
        'ISSUE' { '[!!]  ' }
        'WARN'  { '[!]   ' }
        'ERROR' { '[ERR] ' }
        'INFO'  { '[i]   ' }
        default { "[$($f.Status)] " }
    }
    Write-Output "$icon$($f.Check)"
    $detailLines = $f.Detail -split "`n"
    foreach ($dl in $detailLines) {
        Write-Output "       $dl"
    }
}

# ============================================================
# Timeline output (capped at 50)
# ============================================================
if ($totalEvents -gt 0) {
    Write-Output ''
    if ($totalEvents -gt $timelineLimit) {
        Write-Output "--- Timeline ($timelineLimit Most Recent of $totalEvents) ---"
    } else {
        Write-Output "--- Timeline (All $totalEvents Events) ---"
    }

    $displayEvents = if ($totalEvents -gt $timelineLimit) {
        $sortedEvents | Select-Object -First $timelineLimit
    } else {
        $sortedEvents
    }

    foreach ($evt in $displayEvents) {
        $ts = if ($evt.Time) { $evt.Time.ToString('yyyy-MM-dd HH:mm') } else { '????-??-?? ??:??' }
        $src = $evt.Source
        $eid = $evt.EventId

        # Pad source to align columns
        $srcPad = $src.PadRight(20)

        # Type icon
        $typeIcon = switch ($evt.Type) {
            'Failure' { '[!!]' }
            'Success' { '[OK]' }
            'Info'    { '[i] ' }
            default   { '    ' }
        }

        # Truncate message for single-line display
        $dispMsg = $evt.Message
        if ($dispMsg -and $dispMsg.Length -gt 120) {
            $dispMsg = $dispMsg.Substring(0, 117) + '...'
        }

        Write-Output "$ts  $typeIcon  [$srcPad] $eid : $dispMsg"
    }
}

# ============================================================
# HRESULT Summary
# ============================================================
if ($hresultCounts.Count -gt 0) {
    Write-Output ''
    Write-Output '--- HRESULT Summary ---'

    # Sort by count descending
    $sortedCodes = $hresultCounts.GetEnumerator() | Sort-Object -Property Value -Descending

    foreach ($entry in $sortedCodes) {
        $code = $entry.Key
        $count = $entry.Value

        if ($hresultMap.ContainsKey($code)) {
            $translation = $hresultMap[$code]
            $msg = $translation.Msg
            $action = $translation.Action

            # Determine severity based on code
            $codeIcon = '[!!]  '
            if ($code -eq '0x80240024' -or $code -eq '0x80240017') {
                $codeIcon = '[i]   '
            }

            Write-Output "$codeIcon$code  ($count occurrence(s))"
            Write-Output "       $msg"
            Write-Output "       -> $action"
        } else {
            Write-Output "[!]   $code  ($count occurrence(s))"
            Write-Output "       Unknown HRESULT. Search: https://learn.microsoft.com/search/?terms=$code"
            Write-Output '       -> Investigate this error code or escalate to senior engineer.'
        }
    }
}

# ============================================================
# Result and NEXT footer
# ============================================================
Write-Output ''
$uniqueErrors = $hresultCounts.Count

if ($totalEvents -eq 0) {
    Write-Output 'RESULT: No WU events found. Event logs may have been cleared, or no update activity in this window.'
} elseif ($failureCount -eq 0) {
    Write-Output 'RESULT: No failure events detected. Windows Update activity looks healthy.'
} else {
    Write-Output "RESULT: $uniqueErrors unique error(s) found across $failureCount failure event(s). Review HRESULT details above."
}

Write-Output ''
Write-Output 'NEXT:   Address the most common HRESULT listed above.'
Write-Output '        If network errors (0x8007xxxx)  -> run WU003 WUNetworkCheck'
Write-Output '        If cert errors (0x800B/0x8009)  -> run WU004 WUTlsCertCheck'
Write-Output '        If store corruption (0x800F)    -> run WU005 WUComponentHealth'
Write-Output '        If service errors (0x80080005)  -> run WU009 WUServiceReset'
Write-Output '        If no errors found              -> issue may be policy (WU002) or environmental (WU007)'
Write-Output ''
