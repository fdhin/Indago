# DEF002_DEFDefinitionHealth.ps1
# Scriptlet: DEF002 - Defender Definition & Signature Health
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Defender Definition & Signature Health ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Check 1: Definition Age Analysis (hourly precision)
# ---------------------------------------------------------------
Write-Output '--- Definition Age ---'
$mpStatus = $null
$mpOK     = $false
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    if ($null -ne $mpStatus) { $mpOK = $true }
} catch { }

if (-not $mpOK) {
    Write-Output '[!!]  Defender Status Unavailable'
    Write-Output '       Get-MpComputerStatus returned no data. WMI provider may be unregistered.'
    Write-Output '       On Server 2022 this is a known issue. Run: Register-CimProvider to restore.'
    Write-Output '       Remaining checks that depend on Defender status will be skipped.'
    $issueCount++
} else {
    $nowUtc = [DateTime]::UtcNow

    # --- Antivirus Signatures ---
    $avAge       = $mpStatus.AntivirusSignatureAge
    $avUpdated   = $mpStatus.AntivirusSignatureLastUpdated
    if ($avAge -eq 65535) {
        Write-Output '[!!]  Antivirus Signatures'
        Write-Output '       NEVER UPDATED. Definitions have not been downloaded since OS installation.'
        Write-Output '       This is a critical failure. The update pipeline is completely broken.'
        $issueCount++
    } else {
        $avHours   = -1
        $avDateStr = 'unknown'
        if ($null -ne $avUpdated -and $avUpdated -ne [datetime]::MinValue) {
            $avHours   = [Math]::Round(($nowUtc - $avUpdated.ToUniversalTime()).TotalHours, 1)
            $avDateStr = $avUpdated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
        }
        if ($avHours -gt 48) {
            Write-Output '[!!]  Antivirus Signatures'
            Write-Output "       $avHours hours old (last updated: $avDateStr). Definitions are critically stale."
            Write-Output '       Run checks below to identify why updates are failing.'
            $issueCount++
        } elseif ($avHours -gt 24) {
            Write-Output '[!]   Antivirus Signatures'
            Write-Output "       $avHours hours old (last updated: $avDateStr). Definitions are behind."
            $warnCount++
        } elseif ($avHours -ge 0) {
            Write-Output '[OK]  Antivirus Signatures'
            Write-Output "       $avHours hours old (last updated: $avDateStr). Definitions are current."
        } else {
            Write-Output '[i]   Antivirus Signatures'
            Write-Output "       Age: $avAge day(s). Unable to calculate hourly precision (timestamp unavailable)."
        }
    }

    # --- Antispyware Signatures ---
    $asAge     = $mpStatus.AntispywareSignatureAge
    $asUpdated = $mpStatus.AntispywareSignatureLastUpdated
    if ($asAge -eq 65535) {
        Write-Output '[!!]  Antispyware Signatures'
        Write-Output '       NEVER UPDATED since OS installation.'
        $issueCount++
    } else {
        $asHours   = -1
        $asDateStr = 'unknown'
        if ($null -ne $asUpdated -and $asUpdated -ne [datetime]::MinValue) {
            $asHours   = [Math]::Round(($nowUtc - $asUpdated.ToUniversalTime()).TotalHours, 1)
            $asDateStr = $asUpdated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
        }
        if ($asHours -gt 48) {
            Write-Output '[!!]  Antispyware Signatures'
            Write-Output "       $asHours hours old (last updated: $asDateStr). Critically stale."
            $issueCount++
        } elseif ($asHours -gt 24) {
            Write-Output '[!]   Antispyware Signatures'
            Write-Output "       $asHours hours old (last updated: $asDateStr). Behind."
            $warnCount++
        } elseif ($asHours -ge 0) {
            Write-Output '[OK]  Antispyware Signatures'
            Write-Output "       $asHours hours old (last updated: $asDateStr). Current."
        } else {
            Write-Output '[i]   Antispyware Signatures'
            Write-Output "       Age: $asAge day(s). Hourly precision unavailable."
        }
    }

    # --- NIS Signatures ---
    $nisAge     = $mpStatus.NISSignatureAge
    $nisUpdated = $mpStatus.NISSignatureLastUpdated
    if ($nisAge -eq 65535) {
        Write-Output '[!!]  NIS (Network Inspection) Signatures'
        Write-Output '       NEVER UPDATED since OS installation.'
        $issueCount++
    } else {
        $nisHours   = -1
        $nisDateStr = 'unknown'
        if ($null -ne $nisUpdated -and $nisUpdated -ne [datetime]::MinValue) {
            $nisHours   = [Math]::Round(($nowUtc - $nisUpdated.ToUniversalTime()).TotalHours, 1)
            $nisDateStr = $nisUpdated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
        }
        if ($nisHours -gt 48) {
            Write-Output '[!!]  NIS (Network Inspection) Signatures'
            Write-Output "       $nisHours hours old (last updated: $nisDateStr). Critically stale."
            $issueCount++
        } elseif ($nisHours -gt 24) {
            Write-Output '[!]   NIS (Network Inspection) Signatures'
            Write-Output "       $nisHours hours old (last updated: $nisDateStr). Behind."
            $warnCount++
        } elseif ($nisHours -ge 0) {
            Write-Output '[OK]  NIS (Network Inspection) Signatures'
            Write-Output "       $nisHours hours old (last updated: $nisDateStr). Current."
        } else {
            Write-Output '[i]   NIS (Network Inspection) Signatures'
            Write-Output "       Age: $nisAge day(s). Hourly precision unavailable."
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: Update Source Configuration
# ---------------------------------------------------------------
Write-Output '--- Update Source Configuration ---'

$sigUpdPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates'
$sigUpdReg  = $null
try { $sigUpdReg = Get-ItemProperty -Path $sigUpdPath -ErrorAction Stop } catch { }

$fallbackOrder = $null
if ($null -ne $sigUpdReg) {
    $fallbackOrder = $sigUpdReg.FallbackOrder
}

$sourceConfigured = $false
if (-not [string]::IsNullOrWhiteSpace($fallbackOrder)) {
    $sourceConfigured = $true
    $sources = $fallbackOrder -split '\|'
    $decoded = @()
    foreach ($s in $sources) {
        $s = $s.Trim()
        switch ($s) {
            'InternalDefinitionUpdateServer' { $decoded += 'WSUS/SCCM' }
            'MicrosoftUpdateServer'          { $decoded += 'Microsoft Update' }
            'MMPC'                           { $decoded += 'Microsoft Malware Protection Center (ADL)' }
            'FileShares'                     { $decoded += 'File Share (UNC)' }
            default                          { $decoded += $s }
        }
    }
    $decodedStr = $decoded -join ' -> '

    $hasMSFallback = ($fallbackOrder -match 'MicrosoftUpdateServer' -or $fallbackOrder -match 'MMPC')
    if ($hasMSFallback) {
        Write-Output '[OK]  Signature Update Source (GPO)'
        Write-Output "       FallbackOrder: $decodedStr."
        Write-Output '       Microsoft CDN is included as a fallback. Update path has redundancy.'
    } else {
        Write-Output '[!]   Signature Update Source (GPO)'
        Write-Output "       FallbackOrder: $decodedStr."
        Write-Output '       No Microsoft CDN fallback. If WSUS does not approve Defender definitions,'
        Write-Output '       this machine will never get updates. Add MicrosoftUpdateServer or MMPC to the fallback order.'
        $warnCount++
    }

    # File share source
    $fileShareSrc = $sigUpdReg.DefinitionUpdateFileSharesSources
    if (-not [string]::IsNullOrWhiteSpace($fileShareSrc)) {
        Write-Output "[i]   File Share Source: $fileShareSrc"
    }
} else {
    Write-Output '[OK]  Signature Update Source (GPO)'
    Write-Output '       FallbackOrder not configured by policy. OS default behavior applies'
    Write-Output '       (Microsoft Update with automatic fallback to MMPC).'
}

# ForceUpdateFromMU
if ($null -ne $sigUpdReg) {
    $forceFromMU = $sigUpdReg.ForceUpdateFromMU
    if ($null -ne $forceFromMU) {
        if ($forceFromMU -eq 1) {
            Write-Output '[i]   ForceUpdateFromMU: Enabled. Definitions can be pulled from Microsoft Update even in WSUS environments.'
        } else {
            Write-Output '[i]   ForceUpdateFromMU: Disabled (0). Strict WSUS-only for definition updates.'
        }
    }
}

# Update interval and catchup
if ($null -ne $sigUpdReg) {
    $interval = $sigUpdReg.SignatureUpdateInterval
    $catchup  = $sigUpdReg.SignatureUpdateCatchupInterval
    $battery  = $sigUpdReg.DisableScheduledSignatureUpdateOnBattery

    $parts = @()
    if ($null -ne $interval) {
        if ($interval -eq 0) {
            Write-Output '[!!]  Signature Update Interval'
            Write-Output '       Set to 0 -- signature polling is COMPLETELY DISABLED by policy.'
            Write-Output '       Definitions will never auto-update. This is the most common cause of stale definitions.'
            $issueCount++
        } else {
            $parts += "Update check every $interval hour(s)"
        }
    }
    if ($null -ne $catchup) {
        $parts += "catch-up after $catchup day(s) of missed updates"
    }
    if ($parts.Count -gt 0) {
        Write-Output "[i]   Update Schedule: $($parts -join '. ')."
    }

    if ($null -ne $battery -and $battery -eq 1) {
        Write-Output '[!]   Battery Policy'
        Write-Output '       DisableScheduledSignatureUpdateOnBattery = 1. Updates are blocked while on battery.'
        Write-Output '       Laptops may fall out of definition compliance over weekends or remote work.'
        $warnCount++
    }
}

# Co-Management sabotage check
$coMgmtPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$coMgmtReg  = $null
try { $coMgmtReg = Get-ItemProperty -Path $coMgmtPath -ErrorAction Stop } catch { }
if ($null -ne $coMgmtReg) {
    $setPolicyDriven = $coMgmtReg.SetPolicyDrivenUpdateSourceForOtherUpdates
    if ($null -ne $setPolicyDriven -and $setPolicyDriven -eq 1) {
        Write-Output '[!]   Co-Management Update Source Override'
        Write-Output '       SetPolicyDrivenUpdateSourceForOtherUpdates = 1.'
        Write-Output '       Co-Management is redirecting Defender updates away from WSUS to the cloud.'
        Write-Output '       If the corporate firewall blocks Microsoft CDN endpoints, definitions will fail'
        Write-Output '       with 0x8024402C errors despite local WSUS being correctly configured.'
        $warnCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Update Source Connectivity
# ---------------------------------------------------------------
Write-Output '--- Update Source Connectivity ---'

$cdnEndpoints = @(
    @{ Host = 'definitionupdates.microsoft.com'; Desc = 'Primary CDN for Security Intelligence updates' },
    @{ Host = 'go.microsoft.com';                Desc = 'Alternate Download Location (ADL) for cumulative catch-up updates' }
)

foreach ($ep in $cdnEndpoints) {
    $reachable = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($ep.Host, 443, $null, $null)
        $waited = $result.AsyncWaitHandle.WaitOne(3000, $false)
        if ($waited -and $tcp.Connected) {
            $reachable = $true
        }
        $tcp.Close()
    } catch { }

    if ($reachable) {
        Write-Output "[OK]  $($ep.Host):443 -- Reachable."
        Write-Output "       $($ep.Desc)."
    } else {
        $icon = if ($ep.Host -eq 'definitionupdates.microsoft.com') { '[!!]' } else { '[!] ' }
        Write-Output "$icon  $($ep.Host):443 -- UNREACHABLE (3s timeout)."
        Write-Output "       $($ep.Desc)."
        Write-Output '       Definitions cannot be downloaded from this endpoint. Check firewall/proxy rules.'
        if ($ep.Host -eq 'definitionupdates.microsoft.com') { $issueCount++ } else { $warnCount++ }
    }
}

# Helpful WSUS reference (not duplicating WU002's check)
if ($sourceConfigured -and $fallbackOrder -match 'InternalDefinitionUpdateServer') {
    Write-Output '[i]   WSUS/SCCM is in the fallback order.'
    Write-Output '       To verify WSUS reachability, run WU002 WUPolicyAudit (includes WSUS TCP check).'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Recent Update Failure Events (last 48h)
# ---------------------------------------------------------------
Write-Output '--- Recent Update Events (last 48h) ---'

$lookbackHours = 48
$startTime     = (Get-Date).AddHours(-$lookbackHours)

# HRESULT translation table
$hresultMap = @{
    '0x8024002E' = 'WU_E_WU_DISABLED -- Windows Update service disabled or access blocked by policy'
    '0x8024402C' = 'WU_E_PT_WINHTTP_NAME_NOT_RESOLVED -- DNS failure for update server'
    '0x80072EE7' = 'ERROR_INTERNET_NAME_NOT_RESOLVED -- DNS failure for Microsoft CDN endpoints'
    '0x80072EFD' = 'ERROR_INTERNET_CANNOT_CONNECT -- Connection timed out to update server'
    '0x80240022' = 'WU_E_ALL_UPDATES_FAILED -- Signature payload corrupted in transit'
    '0x8050800C' = 'ERR_MP_BAD_INPUT_DATA -- Downloaded definitions incompatible with current engine version'
    '0x80508020' = 'ERR_MP_BAD_CONFIGURATION -- Internal engine config error, needs service restart'
    '0x800106BA' = 'RPC server unavailable -- Defender service crashed or MpCmdRun.exe missing'
    '0x80070643' = 'ERROR_INSTALL_FAILURE -- MSI/extraction failure during signature injection'
}

$eventLogName = 'Microsoft-Windows-Windows Defender/Operational'
$failEvents   = $null
$succEvents   = $null

try {
    $failEvents = Get-WinEvent -FilterHashtable @{
        LogName   = $eventLogName
        Id        = 2001, 2003
        StartTime = $startTime
    } -ErrorAction Stop
} catch { }

try {
    $succEvents = Get-WinEvent -FilterHashtable @{
        LogName   = $eventLogName
        Id        = 2000
        StartTime = $startTime
    } -ErrorAction Stop
} catch { }

$failCount = 0
if ($null -ne $failEvents) { $failCount = @($failEvents).Count }

if ($failCount -gt 0) {
    $latestFail = @($failEvents)[0]
    $failTimeStr = $latestFail.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $failId      = $latestFail.Id

    # Extract HRESULT from event message
    $failMsg     = $latestFail.Message
    $hresultCode = ''
    $hresultDesc = ''
    if ($failMsg -match '0x[0-9A-Fa-f]{8}') {
        $hresultCode = $Matches[0].ToUpper()
        # Normalize to match our table keys (with lowercase x)
        $lookupKey = '0x' + $hresultCode.Substring(2)
        if ($hresultMap.ContainsKey($lookupKey)) {
            $hresultDesc = $hresultMap[$lookupKey]
        }
    }

    if ($failCount -gt 5) {
        Write-Output '[!!]  Persistent Update Failures'
        Write-Output "       $failCount signature update failures in the last ${lookbackHours}h. Update pipeline is broken."
    } else {
        Write-Output '[!!]  Signature Update Failure Detected'
        Write-Output "       $failCount failure(s) in the last ${lookbackHours}h."
    }

    $eventTypeStr = if ($failId -eq 2001) { 'Signature update failed' } else { 'Engine update failed' }
    Write-Output "       Most recent (Event $failId): $eventTypeStr at $failTimeStr."

    if (-not [string]::IsNullOrWhiteSpace($hresultCode)) {
        if (-not [string]::IsNullOrWhiteSpace($hresultDesc)) {
            Write-Output "       Error: $hresultCode -- $hresultDesc."
        } else {
            Write-Output "       Error: $hresultCode (not in known HRESULT table)."
        }
    }
    $issueCount++
} else {
    Write-Output '[OK]  No signature update failures in the last 48 hours.'
}

# Report last success
if ($null -ne $succEvents -and @($succEvents).Count -gt 0) {
    $latestSucc    = @($succEvents)[0]
    $succTimeStr   = $latestSucc.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    Write-Output "[i]   Last successful update: $succTimeStr (Event 2000)."
} else {
    if ($mpOK) {
        $avAge2 = $mpStatus.AntivirusSignatureAge
        if ($avAge2 -gt 2) {
            Write-Output '[!]   No successful signature updates found in the last 48h event log.'
            Write-Output '       Combined with stale definitions, the update pipeline may be completely blocked.'
            $warnCount++
        } else {
            Write-Output '[i]   No Event 2000 (success) found in the 48h window, but definitions are recent.'
            Write-Output '       Updates may have occurred before the lookback window.'
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Scheduled Task Health
# ---------------------------------------------------------------
Write-Output '--- Scheduled Tasks ---'

$taskPath  = '\Microsoft\Windows\Windows Defender\'
$taskNames = @(
    'Windows Defender Scheduled Scan',
    'Windows Defender Cache Maintenance',
    'Windows Defender Cleanup',
    'Windows Defender Verification'
)

foreach ($taskName in $taskNames) {
    $task     = $null
    $taskInfo = $null
    try {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    } catch { }

    if ($null -eq $task) {
        Write-Output "[!!]  $taskName"
        Write-Output '       MISSING. Task does not exist in Task Scheduler.'
        Write-Output '       This commonly happens after in-place OS upgrades or Sysprep imaging.'
        Write-Output '       Run DEF008 DEFRemediation to recreate Defender scheduled tasks.'
        $issueCount++
        continue
    }

    $state = $task.State
    if ($state -ne 'Ready' -and $state -ne 'Running') {
        Write-Output "[!]   $taskName"
        Write-Output "       State: $state. Task is disabled. Automatic maintenance will not run."
        $warnCount++
        continue
    }

    # Get last run result
    try {
        $taskInfo = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    } catch { }

    $lastResult = 'unknown'
    $resultVerdict = '[OK]'
    $resultDetail  = ''

    if ($null -ne $taskInfo) {
        $lastResult = $taskInfo.LastTaskResult

        if ($lastResult -eq 0) {
            $resultDetail = 'Last result: 0 (success).'
        } elseif ($lastResult -eq 2) {
            $resultVerdict = '[!!]'
            $resultDetail  = 'Last result: 0x2 (ERROR_FILE_NOT_FOUND). MpCmdRun.exe may be missing or task XML path is corrupt.'
            $issueCount++
        } elseif ($lastResult -eq 1) {
            $resultVerdict = '[!] '
            $resultDetail  = "Last result: 0x1 (generic error). Task ran but encountered an issue."
            $warnCount++
        } elseif ($lastResult -eq 267009) {
            # 0x00041301 = Task is currently running
            $resultDetail = 'Currently running.'
        } elseif ($lastResult -eq 267011) {
            # 0x00041303 = Task has not yet run
            $resultDetail = 'Task has never run on this machine.'
        } else {
            $hexResult = '0x' + ([Convert]::ToString($lastResult, 16)).ToUpper()
            $resultVerdict = '[!] '
            $resultDetail  = "Last result: $hexResult ($lastResult). Non-zero exit code -- investigate."
            $warnCount++
        }
    } else {
        $resultDetail = 'Unable to retrieve task run info.'
    }

    Write-Output "$resultVerdict  $taskName"
    Write-Output "       Enabled. $resultDetail"
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. Definition update pipeline is healthy.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Definition updates are working but review the flagged items."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Definition updates need attention."
}

Write-Output ''
Write-Output 'NEXT:   If update source unreachable      -> check network/proxy (see WU003 WUNetworkCheck)'
Write-Output '        If WSUS blocking definitions      -> approve Defender definitions on WSUS or add MMPC fallback'
Write-Output '        If scheduled tasks missing         -> run DEF008 DEFRemediation to recreate'
Write-Output '        If connectivity OK but still fail  -> run DEF006 DEFPlatformVersion (platform may be too old)'
Write-Output '        If running WSUS                    -> run WU002 WUPolicyAudit to verify WSUS reachability'
