# DEF007_DEFEventAnalysis.ps1
# Scriptlet: DEF007 - Defender Event Log & Threat History Analysis
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== Defender Event Log & Threat History Analysis ==='

# ============================================================
# Parameter handling
# ============================================================
$daysBack = 7
if ($Param1) {
    $parsed = 0
    if ([int]::TryParse($Param1, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 90) {
        $daysBack = $parsed
    }
}

$cutoffTime = (Get-Date).AddDays(-$daysBack)
$cutoffMs = [long]([Math]::Abs((New-TimeSpan -Start (Get-Date) -End $cutoffTime).TotalMilliseconds))

Write-Output "[i]   Time Window: last $daysBack day(s)"
Write-Output "       Cutoff: $($cutoffTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output ''

# ============================================================
# HRESULT Translation Map
# ============================================================
$hresultMap = @{
    '0x80508023' = @{ Name = 'ERR_MP_THREAT_NOT_FOUND'; Meaning = 'Threat resolved before engine could act (ghost state/race condition).'; Route = '' }
    '0x80508019' = @{ Name = 'ERR_MP_NOT_FOUND'; Meaning = 'Internal engine rollback or failure -- corrupted signature merge.'; Route = 'Run DEF006 DEFPlatformVersion' }
    '0x80070005' = @{ Name = 'E_ACCESSDENIED'; Meaning = 'Access denied -- Tamper Protection blocked or permissions issue.'; Route = 'Run DEF004 DEFRealtimeProtection' }
    '0x800106ba' = @{ Name = 'RPC_S_SERVER_UNAVAILABLE'; Meaning = 'WinDefend service crashed or hung -- RPC pipe severed.'; Route = 'Run DEF001 DEFStatusTriage' }
    '0x80508007' = @{ Name = 'ERR_MP_NO_MEMORY'; Meaning = 'Memory exhaustion during scan or definition load.'; Route = 'Check system resources' }
    '0x80501001' = @{ Name = 'ERROR_MP_ACTIONS_FAILED'; Meaning = 'Remediation action failed -- engine could not quarantine/remove.'; Route = 'Run full scan or offline scan' }
    '0x80508014' = @{ Name = 'ERROR_MP_RESTORE_FAILED'; Meaning = 'Quarantine restore failed -- file corrupted or policy-blocked.'; Route = '' }
    '0x80508017' = @{ Name = 'ERROR_MP_REMOVE_FAILED'; Meaning = 'Threat removal failed -- file locked by malware.'; Route = 'Run offline scan (Start-MpWDOScan)' }
    '0x8050A003' = @{ Name = 'SCAN_ABORTED'; Meaning = 'Scan aborted -- resource conflict or timeout.'; Route = 'Retry scan' }
    '0x80508026' = @{ Name = 'ENGINE_UPDATE_FAILED'; Meaning = 'Engine update failed.'; Route = 'Run DEF006 DEFPlatformVersion' }
}

# Collected HRESULTs from events
$observedHresults = @{}

# ============================================================
# Helper: Extract HRESULTs from event message
# ============================================================
function Extract-HResults {
    param([string]$Message)
    $matches2 = [regex]::Matches($Message, '0x[0-9A-Fa-f]{8}')
    $results = @()
    foreach ($m in $matches2) {
        $code = $m.Value.ToLower()
        # Normalize: uppercase hex after 0x
        $code = '0x' + $code.Substring(2).ToUpper()
        if ($results -notcontains $code) {
            $results += $code
        }
    }
    return $results
}

# ============================================================
# Section 1: Protection State Timeline
# ============================================================
Write-Output '--- Protection State Timeline ---'

$protectionEventIds = @(1000, 1001, 1002, 1005, 1150, 2000, 2001, 2002, 5007)
$protectionEvents = @()

try {
    $xpathFilter = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs] and ($(($protectionEventIds | ForEach-Object { "EventID=$_" }) -join ' or '))]]"
    $protectionEvents = @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -FilterXPath $xpathFilter -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Protection Events'
            Status = 'INFO'
            Detail = "No protection events found in the last $daysBack day(s)."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Protection Events'
            Status = 'WARN'
            Detail = "Failed to query Defender Operational log: $($_.Exception.Message)"
        })
    }
}

# Categorize protection events
$scanStarted = @($protectionEvents | Where-Object { $_.Id -eq 1000 })
$scanCompleted = @($protectionEvents | Where-Object { $_.Id -eq 1001 })
$scanCancelled = @($protectionEvents | Where-Object { $_.Id -eq 1002 })
$scanFailed = @($protectionEvents | Where-Object { $_.Id -eq 1005 })
$serviceHealthy = @($protectionEvents | Where-Object { $_.Id -eq 1150 })
$defUpdateStarted = @($protectionEvents | Where-Object { $_.Id -eq 2000 })
$defUpdateSucceeded = @($protectionEvents | Where-Object { $_.Id -eq 2001 })
$defUpdateFailed = @($protectionEvents | Where-Object { $_.Id -eq 2002 })
$configChanged = @($protectionEvents | Where-Object { $_.Id -eq 5007 })

# Summary statistics
$totalProtEvents = $protectionEvents.Count
$findings.Add([PSCustomObject]@{
    Check  = 'Protection Event Summary'
    Status = 'INFO'
    Detail = "$totalProtEvents protection event(s) in the last $daysBack day(s): $($scanStarted.Count) scan start, $($scanCompleted.Count) scan complete, $($scanCancelled.Count) scan cancelled, $($scanFailed.Count) scan failed, $($defUpdateSucceeded.Count) def update OK, $($defUpdateFailed.Count) def update fail, $($configChanged.Count) config change, $($serviceHealthy.Count) health heartbeat."
})

# Scan failures
if ($scanFailed.Count -gt 0) {
    foreach ($evt in $scanFailed) {
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = '' } }
        $codes = Extract-HResults -Message $msg
        foreach ($c in $codes) { $observedHresults[$c] = $true }
        $findings.Add([PSCustomObject]@{
            Check  = "Scan Failed (Event 1005)"
            Status = 'ISSUE'
            Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- Scan failed. $( if ($codes.Count -gt 0) { 'Error: ' + ($codes -join ', ') } else { 'No HRESULT extracted.' } )"
        })
    }
}

# Scan cancellations
if ($scanCancelled.Count -gt 0) {
    if ($scanCancelled.Count -ge 3) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Scan Cancellations'
            Status = 'WARN'
            Detail = "$($scanCancelled.Count) scan(s) cancelled in the last $daysBack day(s). Pattern of aborted scans may indicate resource contention, third-party AV conflict, or user interruption."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Scan Cancellations'
            Status = 'INFO'
            Detail = "$($scanCancelled.Count) scan(s) cancelled in the last $daysBack day(s)."
        })
    }
}

# Definition update failures
if ($defUpdateFailed.Count -gt 0) {
    foreach ($evt in $defUpdateFailed) {
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = '' } }
        $codes = Extract-HResults -Message $msg
        foreach ($c in $codes) { $observedHresults[$c] = $true }
        $findings.Add([PSCustomObject]@{
            Check  = "Definition Update Failed (Event 2002)"
            Status = 'ISSUE'
            Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- Definition update failed. $( if ($codes.Count -gt 0) { 'Error: ' + ($codes -join ', ') } else { 'No HRESULT extracted.' } )"
        })
    }
} elseif ($defUpdateSucceeded.Count -gt 0) {
    $lastSuccess = $defUpdateSucceeded[0]
    $findings.Add([PSCustomObject]@{
        Check  = 'Definition Updates'
        Status = 'OK'
        Detail = "$($defUpdateSucceeded.Count) successful update(s). Last: $($lastSuccess.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')). No failures."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Definition Updates'
        Status = 'WARN'
        Detail = "No definition update events found in the last $daysBack day(s). Definitions may be stale."
    })
}

# Configuration changes (Event 5007)
if ($configChanged.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Configuration Changes (Event 5007)'
        Status = 'WARN'
        Detail = "$($configChanged.Count) configuration change(s) detected in the last $daysBack day(s). Review to determine if protection was intentionally or maliciously modified."
    })
    # Show up to 5 most recent changes
    $showCount = [Math]::Min($configChanged.Count, 5)
    for ($i = 0; $i -lt $showCount; $i++) {
        $evt = $configChanged[$i]
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = 'No detail available' } }
        # Truncate long messages
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        $findings.Add([PSCustomObject]@{
            Check  = "  Config Change $($i + 1)"
            Status = 'INFO'
            Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- $msg"
        })
    }
}

# Service health
if ($serviceHealthy.Count -gt 0) {
    $lastHealth = $serviceHealthy[0]
    $findings.Add([PSCustomObject]@{
        Check  = 'Service Health Heartbeat (Event 1150)'
        Status = 'OK'
        Detail = "$($serviceHealthy.Count) heartbeat(s). Last: $($lastHealth.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')). Engine and platform confirmed operational."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Service Health Heartbeat'
        Status = 'WARN'
        Detail = "No Event 1150 heartbeats in the last $daysBack day(s). Defender engine may not be running or log may be cleared."
    })
}

# ============================================================
# Section 2: Threat Activity
# ============================================================
Write-Output ''
Write-Output '--- Threat Activity ---'

$threatEventIds = @(1006, 1007, 1008, 1009, 1011, 1116, 1117, 1118, 1119)
$threatEvents = @()

try {
    $xpathFilter2 = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs] and ($(($threatEventIds | ForEach-Object { "EventID=$_" }) -join ' or '))]]"
    $threatEvents = @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -FilterXPath $xpathFilter2 -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Threat Events'
            Status = 'OK'
            Detail = "No threat activity events in the last $daysBack day(s). No malware detected."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Threat Events'
            Status = 'WARN'
            Detail = "Failed to query threat events: $($_.Exception.Message)"
        })
    }
}

# ThreatStatusID decode table
$threatStatusMap = @{
    0   = @{ Label = 'Unknown';           Verdict = 'WARN' }
    1   = @{ Label = 'Detected';          Verdict = 'WARN' }
    2   = @{ Label = 'Cleaned';           Verdict = 'OK' }
    3   = @{ Label = 'Quarantined';       Verdict = 'OK' }
    4   = @{ Label = 'Removed';           Verdict = 'OK' }
    5   = @{ Label = 'Allowed';           Verdict = 'WARN' }
    6   = @{ Label = 'Blocked';           Verdict = 'OK' }
    102 = @{ Label = 'Quarantine Failed'; Verdict = 'ISSUE' }
    103 = @{ Label = 'Remove Failed';     Verdict = 'ISSUE' }
    104 = @{ Label = 'Allow Failed';      Verdict = 'WARN' }
    105 = @{ Label = 'Abandoned';         Verdict = 'WARN' }
    107 = @{ Label = 'Blocked Failed';    Verdict = 'ISSUE' }
}

# AdditionalActionsBitMask decode
$actionBitMap = @{
    4     = 'Full Scan Required'
    8     = 'Reboot Required'
    16    = 'Manual Steps Required'
    32768 = 'Offline Scan Required'
}

if ($threatEvents.Count -gt 0) {
    # Categorize
    $detections = @($threatEvents | Where-Object { $_.Id -eq 1006 -or $_.Id -eq 1116 })
    $actionOk = @($threatEvents | Where-Object { $_.Id -eq 1007 -or $_.Id -eq 1117 })
    $actionFailed = @($threatEvents | Where-Object { $_.Id -eq 1008 -or $_.Id -eq 1118 -or $_.Id -eq 1119 })
    $quarRestore = @($threatEvents | Where-Object { $_.Id -eq 1009 })
    $quarDelete = @($threatEvents | Where-Object { $_.Id -eq 1011 })

    $findings.Add([PSCustomObject]@{
        Check  = 'Threat Event Summary'
        Status = if ($actionFailed.Count -gt 0) { 'ISSUE' } elseif ($detections.Count -gt 0) { 'WARN' } else { 'INFO' }
        Detail = "$($threatEvents.Count) threat event(s): $($detections.Count) detection(s), $($actionOk.Count) remediated, $($actionFailed.Count) action failed, $($quarRestore.Count) quarantine restore, $($quarDelete.Count) quarantine delete."
    })

    # Report detections (up to 10 most recent)
    $showDetections = [Math]::Min($detections.Count, 10)
    for ($i = 0; $i -lt $showDetections; $i++) {
        $evt = $detections[$i]
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = '' } }

        # Try to extract threat name from message
        $threatName = 'Unknown'
        if ($msg -match 'Name:\s*(.+?)[\r\n]') {
            $threatName = $Matches[1].Trim()
        } elseif ($msg -match 'threat\s+name[:\s]+([^\r\n]+)') {
            $threatName = $Matches[1].Trim()
        }

        # Try to extract severity
        $severity = 'Unknown'
        if ($msg -match 'Severity:\s*(.+?)[\r\n]') {
            $severity = $Matches[1].Trim()
        }

        $codes = Extract-HResults -Message $msg
        foreach ($c in $codes) { $observedHresults[$c] = $true }

        $findings.Add([PSCustomObject]@{
            Check  = "  Detection ($($evt.Id))"
            Status = 'WARN'
            Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- Threat: $threatName | Severity: $severity"
        })
    }

    # Report action failures (critical)
    if ($actionFailed.Count -gt 0) {
        foreach ($evt in $actionFailed) {
            $msg = $evt.Message
            if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = '' } }
            $codes = Extract-HResults -Message $msg
            foreach ($c in $codes) { $observedHresults[$c] = $true }

            $threatName = 'Unknown'
            if ($msg -match 'Name:\s*(.+?)[\r\n]') {
                $threatName = $Matches[1].Trim()
            }

            # Try to extract status ID
            $statusDetail = ''
            if ($msg -match 'Status:\s*(\d+)') {
                $statusId = [int]$Matches[1]
                if ($threatStatusMap.ContainsKey($statusId)) {
                    $statusDetail = " | Status: $($threatStatusMap[$statusId].Label)"
                } else {
                    $statusDetail = " | StatusID: $statusId"
                }
            }

            # Try to extract additional actions
            $actionsDetail = ''
            if ($msg -match 'Additional Actions?:?\s*(\d+)') {
                $actionBits = [int]$Matches[1]
                $actionsList = @()
                foreach ($bit in $actionBitMap.Keys) {
                    if (($actionBits -band $bit) -ne 0) {
                        $actionsList += $actionBitMap[$bit]
                    }
                }
                if ($actionsList.Count -gt 0) {
                    $actionsDetail = " | Actions: $($actionsList -join ', ')"
                }
            }

            $findings.Add([PSCustomObject]@{
                Check  = "  Action FAILED ($($evt.Id))"
                Status = 'ISSUE'
                Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- Threat: $threatName$statusDetail$actionsDetail. $( if ($codes.Count -gt 0) { 'Error: ' + ($codes -join ', ') } else { '' } )"
            })
        }

        $findings.Add([PSCustomObject]@{
            Check  = 'Unresolved Threat Warning'
            Status = 'ISSUE'
            Detail = "$($actionFailed.Count) threat(s) could not be remediated. Engine is in degraded state. Manual intervention required."
        })
    }
}

# ============================================================
# Section 2b: Security Center Events (Application Log)
# ============================================================
Write-Output ''
Write-Output '--- Security Center Events ---'

$secCenterEvents = @()
try {
    $xpathSC = "*[System[Provider[@Name='SecurityCenter'] and TimeCreated[timediff(@SystemTime) <= $cutoffMs] and (EventID=15 or EventID=16 or EventID=17)]]"
    $secCenterEvents = @(Get-WinEvent -LogName 'Application' -FilterXPath $xpathSC -ErrorAction Stop)
} catch {
    if (-not ($_.Exception.Message -match 'No events were found')) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Security Center Events'
            Status = 'INFO'
            Detail = "Could not query Security Center events from Application log: $($_.Exception.Message)"
        })
    }
}

if ($secCenterEvents.Count -gt 0) {
    $evt15 = @($secCenterEvents | Where-Object { $_.Id -eq 15 })
    $evt16 = @($secCenterEvents | Where-Object { $_.Id -eq 16 })
    $evt17 = @($secCenterEvents | Where-Object { $_.Id -eq 17 })

    if ($evt16.Count -gt 0 -or $evt17.Count -gt 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Security Center Errors'
            Status = 'WARN'
            Detail = "$($secCenterEvents.Count) SecurityCenter event(s): $($evt15.Count) state change(s), $($evt16.Count) status update error(s), $($evt17.Count) validation failure(s). Status update errors often indicate ghost AV registrations. Validation failures (DC040780) indicate WMI sync issues."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Security Center Events'
            Status = 'INFO'
            Detail = "$($secCenterEvents.Count) SecurityCenter event(s) found. $($evt15.Count) state change(s). No errors detected."
        })
    }

    # Show up to 5 most recent error events
    $errorEvents = @($secCenterEvents | Where-Object { $_.Id -eq 16 -or $_.Id -eq 17 })
    $showSC = [Math]::Min($errorEvents.Count, 5)
    for ($i = 0; $i -lt $showSC; $i++) {
        $evt = $errorEvents[$i]
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { $msg = 'No detail' } }
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        $findings.Add([PSCustomObject]@{
            Check  = "  SC Event $($evt.Id)"
            Status = 'WARN'
            Detail = "$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) -- $msg"
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Security Center Events'
        Status = 'OK'
        Detail = "No SecurityCenter error events in the last $daysBack day(s)."
    })
}

# ============================================================
# Section 2c: WHC Log (Windows Health Center, if available)
# ============================================================
$whcEvents = @()
try {
    $xpathWHC = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs]]]"
    $whcEvents = @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/WHC' -FilterXPath $xpathWHC -MaxEvents 20 -ErrorAction Stop)
} catch {
    # WHC channel may not exist on all builds -- graceful skip
}

if ($whcEvents.Count -gt 0) {
    Write-Output ''
    Write-Output '--- Windows Health Center ---'
    $findings.Add([PSCustomObject]@{
        Check  = 'WHC Events'
        Status = 'INFO'
        Detail = "$($whcEvents.Count) event(s) found in Defender WHC log (health assessments and compliance telemetry)."
    })

    # Extract any HRESULTs
    foreach ($evt in $whcEvents) {
        $msg = $evt.Message
        if (-not $msg) { try { $msg = $evt.FormatDescription() } catch { continue } }
        $codes = Extract-HResults -Message $msg
        foreach ($c in $codes) { $observedHresults[$c] = $true }
    }
}

# ============================================================
# Section 3: HRESULT Error Code Summary
# ============================================================
Write-Output ''
Write-Output '--- Error Code Summary ---'

if ($observedHresults.Keys.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Error Codes Observed'
        Status = 'WARN'
        Detail = "$($observedHresults.Keys.Count) unique HRESULT code(s) extracted from events."
    })

    foreach ($code in ($observedHresults.Keys | Sort-Object)) {
        if ($hresultMap.ContainsKey($code)) {
            $entry = $hresultMap[$code]
            $routeStr = ''
            if ($entry.Route) { $routeStr = " --> $($entry.Route)" }
            $findings.Add([PSCustomObject]@{
                Check  = "  $code ($($entry.Name))"
                Status = 'WARN'
                Detail = "$($entry.Meaning)$routeStr"
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "  $code"
                Status = 'INFO'
                Detail = "Unknown HRESULT. Not in the embedded translation table. Search Microsoft documentation for this code."
            })
        }
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Error Codes'
        Status = 'OK'
        Detail = 'No HRESULT error codes extracted from events. No known error conditions.'
    })
}

# ============================================================
# Output
# ============================================================
Write-Output ''
Write-Output '--- Summary ---'

$issueCount = @($findings | Where-Object { $_.Status -eq 'ISSUE' -or $_.Status -eq 'ERROR' }).Count
$warnCount  = @($findings | Where-Object { $_.Status -eq 'WARN' }).Count

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
    Write-Output "       $($f.Detail)"
}

Write-Output ''
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected in Defender event timeline. Protection state healthy.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] above."
}

Write-Output ''
Write-Output 'NEXT:   If active threats unresolved  -> run a full scan: Start-MpScan -ScanType FullScan'
Write-Output '        If definition rollback         -> force update: Update-MpSignature'
Write-Output '        If platform/engine errors      -> run DEF006 DEFPlatformVersion'
Write-Output '        If access denied errors        -> run DEF004 DEFRealtimeProtection (Tamper Protection)'
Write-Output '        If service crashed             -> run DEF001 DEFStatusTriage'
Write-Output '        Escalate timeline to security team if threats were detected.'
Write-Output ''
