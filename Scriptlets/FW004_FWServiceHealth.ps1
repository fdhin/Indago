# FW004_FWServiceHealth.ps1
# Scriptlet: FW004 - Service Dependencies & WFP Health
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Firewall Service Dependencies & WFP Health ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0


# ---------------------------------------------------------------
# Check 1: Service Dependency Chain
# ---------------------------------------------------------------
Write-Output '--- Service Dependency Chain ---'

$chainServices = @(
    @{ Name = 'RpcSs';  Display = 'RpcSs (Remote Procedure Call)';      Role = 'Foundation for COM/DCOM and all RPC traffic' },
    @{ Name = 'BFE';    Display = 'BFE (Base Filtering Engine)';         Role = 'User-mode WFP orchestrator. Depends on RpcSs.' },
    @{ Name = 'MpsSvc'; Display = 'MpsSvc (Windows Defender Firewall)';  Role = 'Translates profiles/policies into WFP filters. Depends on BFE.' }
)

$chainHealthy = $true

foreach ($svcDef in $chainServices) {
    $svcName = $svcDef.Name
    $svcDisplay = $svcDef.Display
    $svcRole = $svcDef.Role

    $svc = $null
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
    } catch { }

    if ($null -eq $svc) {
        Write-Output "[!!]  $svcDisplay"
        Write-Output '       Service NOT FOUND. Critical system component missing.'
        Write-Output "       Role: $svcRole"
        $issueCount++
        $chainHealthy = $false
        continue
    }

    $status = "$($svc.Status)"
    $startType = "$($svc.StartType)"

    # Get exit code from Win32_Service
    $exitCode = 0
    try {
        $cimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop
        if ($null -ne $cimSvc) {
            $exitCode = $cimSvc.ExitCode
        }
    } catch { }

    $exitStr = "Exit code: $exitCode."
    if ($exitCode -ne 0) {
        $exitStr = "Exit code: $exitCode (NON-ZERO -- unclean shutdown)."
    }

    if ($status -eq 'Running' -and $startType -eq 'Automatic') {
        Write-Output "[OK]  $svcDisplay"
        Write-Output "       Running, start type: Automatic. $exitStr"
    } elseif ($status -eq 'Running') {
        Write-Output "[!]   $svcDisplay"
        Write-Output "       Running, but start type: $startType."
        Write-Output '       May not survive reboot. Set to Automatic for reliability.'
        Write-Output "       $exitStr"
        $warnCount++
    } elseif ($status -eq 'Stopped' -and $startType -eq 'Disabled') {
        Write-Output "[!!]  $svcDisplay"
        Write-Output "       STOPPED and DISABLED. All dependent services are also dead."
        Write-Output "       Role: $svcRole"
        Write-Output "       $exitStr"
        $issueCount++
        $chainHealthy = $false
    } elseif ($status -eq 'Stopped') {
        Write-Output "[!!]  $svcDisplay"
        Write-Output "       STOPPED (start type: $startType). Should be running."
        Write-Output "       Role: $svcRole"
        Write-Output "       $exitStr"
        $issueCount++
        $chainHealthy = $false
    } else {
        # StartPending, StopPending, etc.
        Write-Output "[!!]  $svcDisplay"
        Write-Output "       Status: $status. Service stuck in transitional state."
        Write-Output "       Start type: $startType. $exitStr"
        Write-Output '       May require a reboot to clear the stuck state.'
        $issueCount++
        $chainHealthy = $false
    }

    if ($exitCode -ne 0 -and $status -eq 'Running') {
        Write-Output "[!]   Previous shutdown was unclean (exit code $exitCode)."
        $warnCount++
    }
}

# Chain cascade explanation
if (-not $chainHealthy) {
    Write-Output ''
    # Check which service is the root cause
    $rpcSvc = $null
    $bfeSvc = $null
    try { $rpcSvc = Get-Service -Name 'RpcSs' -ErrorAction Stop } catch { }
    try { $bfeSvc = Get-Service -Name 'BFE' -ErrorAction Stop } catch { }

    if ($null -eq $rpcSvc -or $rpcSvc.Status -ne 'Running') {
        Write-Output '[!!]  CASCADE: RpcSs is down.'
        Write-Output '       RpcSs -> BFE -> MpsSvc. The entire chain is broken.'
        Write-Output '       All firewall management APIs, netsh, and PowerShell cmdlets will fail.'
    } elseif ($null -eq $bfeSvc -or $bfeSvc.Status -ne 'Running') {
        Write-Output '[!!]  CASCADE: BFE is down but RpcSs is running.'
        Write-Output '       BFE -> MpsSvc. Firewall cannot communicate with WFP.'
        Write-Output '       IPsec management also fails when BFE is stopped.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: WFP State
# ---------------------------------------------------------------
Write-Output '--- WFP State ---'


$wfpTempFile = Join-Path $env:ProgramData 'Indago\Logs\wfpstate_check.xml'

try {
    # Ensure directory exists
    $wfpDir = Split-Path $wfpTempFile -Parent
    if (-not (Test-Path $wfpDir)) {
        $null = New-Item -Path $wfpDir -ItemType Directory -Force -ErrorAction Stop
    }

    # Remove old file if exists
    if (Test-Path $wfpTempFile) {
        Remove-Item $wfpTempFile -Force -ErrorAction SilentlyContinue
    }

    $wfpResult = & netsh.exe wfp show state file="$wfpTempFile" 2>&1
    $wfpExitCode = $LASTEXITCODE

    if ($wfpExitCode -eq 0 -and (Test-Path $wfpTempFile)) {
        $wfpFileInfo = Get-Item $wfpTempFile -ErrorAction Stop
        $wfpSizeKB = [math]::Round($wfpFileInfo.Length / 1024, 0)

        if ($wfpSizeKB -gt 1) {
            Write-Output '[OK]  Windows Filtering Platform'
            Write-Output "       WFP engine is responsive. State file generated ($wfpSizeKB KB)."

        } else {
            Write-Output '[!]   Windows Filtering Platform'
            Write-Output "       WFP state file is very small ($wfpSizeKB KB). Engine may be degraded."
            $warnCount++
        }

        # Clean up
        Remove-Item $wfpTempFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output '[!!]  Windows Filtering Platform'
        Write-Output '       netsh wfp show state FAILED.'
        if ($null -ne $wfpResult) {
            $resultStr = "$wfpResult"
            if ($resultStr.Length -gt 120) { $resultStr = $resultStr.Substring(0, 117) + '...' }
            Write-Output "       Output: $resultStr"
        }
        Write-Output '       BFE may be down or WFP infrastructure is broken.'
        $issueCount++
    }
} catch {
    Write-Output '[!]   Windows Filtering Platform'
    Write-Output "       Cannot check WFP state: $($_.Exception.Message)"
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Firewall Log Configuration & Recent Activity
# ---------------------------------------------------------------
Write-Output '--- Firewall Log Configuration ---'

$logEnabled = $false
$logFilePath = ''

try {
    $fwProfiles = Get-NetFirewallProfile -ErrorAction Stop
    foreach ($prof in $fwProfiles) {
        $profName = "$($prof.Name)"
        $logBlocked = $prof.LogBlocked
        $logAllowed = $prof.LogAllowed
        $logFile = "$($prof.LogFileName)"
        $logMaxSize = $prof.LogMaxSizeKilobytes

        if ($logBlocked -eq 'True' -or "$logBlocked" -eq 'True') {
            Write-Output "[OK]  $profName Profile Log"
            Write-Output "       LogBlocked: True. Drops are being recorded."
            if ($logAllowed -eq 'True' -or "$logAllowed" -eq 'True') {
                Write-Output "       LogAllowed: True (high volume)."
            }
            $logEnabled = $true
            if ($logFile.Length -gt 0) { $logFilePath = $logFile }
        } else {
            Write-Output "[!]   $profName Profile Log"
            Write-Output '       LogBlocked: False. LogAllowed: False.'
            Write-Output '       Firewall drops are NOT being logged. Enable for troubleshooting:'
            Write-Output "       Set-NetFirewallProfile -Name $profName -LogBlocked True"
            $warnCount++
        }

        if ($null -ne $logMaxSize -and $logMaxSize -gt 0 -and $logMaxSize -le 4096) {
            Write-Output "[i]   Log max size: $logMaxSize KB (default 4 MB). Increase to 16 MB:"
            Write-Output '       Set-NetFirewallProfile -All -LogMaxSizeKilobytes 16384'
        }
    }
} catch {
    Write-Output '[!]   Cannot query firewall profiles for log configuration.'
    Write-Output "       Error: $($_.Exception.Message)"
    $warnCount++
}

# 3b: Log file health and recent activity
if ($logEnabled -and $logFilePath.Length -gt 0) {
    # Resolve environment variables in path
    $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($logFilePath)

    if (Test-Path $resolvedPath) {
        $logFileInfo = Get-Item $resolvedPath -ErrorAction SilentlyContinue
        if ($null -ne $logFileInfo) {
            $logSizeKB = [math]::Round($logFileInfo.Length / 1024, 0)
            Write-Output "[OK]  Log File: $resolvedPath"
            Write-Output "       Size: $logSizeKB KB."

            if ($logSizeKB -ge 4000) {
                Write-Output '[!]   Log file near default 4 MB limit. May be rolling over rapidly.'
                Write-Output '       Increase LogMaxSizeKilobytes to at least 20480 (20 MB) for enterprise.'
                $warnCount++
            }

            # Read tail for recent activity
            try {
                $tailLines = Get-Content -Path $resolvedPath -Tail 50 -ErrorAction Stop
                $dropLines = New-Object System.Collections.Generic.List[string]
                $lostLines = New-Object System.Collections.Generic.List[string]

                foreach ($tl in $tailLines) {
                    if ($tl -match '\sDROP\s') {
                        $null = $dropLines.Add($tl)
                    }
                    if ($tl -match 'INFO-EVENTS-LOST') {
                        $null = $lostLines.Add($tl)
                    }
                }

                if ($lostLines.Count -gt 0) {
                    Write-Output "[!!]  INFO-EVENTS-LOST: $($lostLines.Count) entries found in recent log."
                    Write-Output '       The firewall is dropping telemetry -- under extreme network load,'
                    Write-Output '       active DoS attack, or severe hardware exhaustion.'
                    $issueCount++
                }

                if ($dropLines.Count -gt 0) {
                    $showDrops = [math]::Min($dropLines.Count, 5)
                    Write-Output "[i]   Recent DROP entries: $($dropLines.Count) in last 50 lines."
                    $startIdx = $dropLines.Count - $showDrops
                    for ($d = $startIdx; $d -lt $dropLines.Count; $d++) {
                        $dropLine = $dropLines[$d]
                        if ($dropLine.Length -gt 120) { $dropLine = $dropLine.Substring(0, 117) + '...' }
                        Write-Output "       $dropLine"
                    }
                } else {
                    Write-Output '[i]   No DROP entries in last 50 lines of log.'
                }
            } catch {
                Write-Output '[!]   Cannot read log file tail.'
                Write-Output "       Error: $($_.Exception.Message)"
                $warnCount++
            }
        }
    } else {
        Write-Output "[!!]  Log File: NOT FOUND"
        Write-Output "       Path: $resolvedPath"
        Write-Output '       Logging is configured but the log file does not exist.'
        $issueCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Service Security Descriptor (SDDL) Validation
# ---------------------------------------------------------------
Write-Output '--- Service Security Descriptor ---'

try {
    $sddlOutput = & sc.exe sdshow MpsSvc 2>&1
    $sddlStr = ''
    foreach ($sddlLine in $sddlOutput) {
        $lineStr = "$sddlLine".Trim()
        if ($lineStr -match '^D:') {
            $sddlStr = $lineStr
            break
        }
    }

    if ($sddlStr.Length -gt 0) {
        $hasSY = $sddlStr -match '\(A[^)]*;;;SY\)'
        $hasBA = $sddlStr -match '\(A[^)]*;;;BA\)'

        if ($hasSY -and $hasBA) {
            Write-Output '[OK]  MpsSvc SDDL'
            Write-Output '       Both SY (SYSTEM) and BA (Administrators) ACEs are present.'
            Write-Output '       Service permissions are intact.'
        } else {
            Write-Output '[!!]  MpsSvc SDDL -- TAMPERED'
            if (-not $hasSY) {
                Write-Output '       MISSING: SY (LocalSystem) ACE. SYSTEM cannot manage the service.'
            }
            if (-not $hasBA) {
                Write-Output '       MISSING: BA (Built-in Administrators) ACE. Admins cannot manage the service.'
            }
            Write-Output '       This is a known malware tactic (ZeroAccess, optimizer scripts).'
            Write-Output '       The service will silently fail to start with Access Denied.'
            Write-Output '       Run FW006 FWRemediation to reset the service descriptor.'
            $issueCount++
        }
    } else {
        Write-Output '[!]   MpsSvc SDDL'
        Write-Output '       Cannot parse SDDL output from sc.exe sdshow MpsSvc.'
        $warnCount++
    }
} catch {
    Write-Output '[!]   Cannot retrieve MpsSvc security descriptor.'
    Write-Output "       Error: $($_.Exception.Message)"
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Firewall Event Log Errors
# ---------------------------------------------------------------
Write-Output '--- Firewall Event Log ---'

$cutoff = (Get-Date).AddHours(-24)
$eventFound = $false

# 5a: WFAS operational log
$wfasLogName = 'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall'
$wfasEventIds = @(2003)  # Profile could not be applied

try {
    $wfasEvents = Get-WinEvent -FilterHashtable @{
        LogName = $wfasLogName
        Id = $wfasEventIds
        StartTime = $cutoff
    } -MaxEvents 10 -ErrorAction Stop

    if ($null -ne $wfasEvents -and @($wfasEvents).Count -gt 0) {
        $evtArray = @($wfasEvents)
        Write-Output "[!!]  WFAS Event Log: $($evtArray.Count) error event(s) in last 24h"
        $showCount = [math]::Min($evtArray.Count, 5)
        for ($e = 0; $e -lt $showCount; $e++) {
            $evt = $evtArray[$e]
            $evtTime = $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            $evtMsg = "$($evt.Message)"
            if ($evtMsg.Length -gt 100) { $evtMsg = $evtMsg.Substring(0, 97) + '...' }
            Write-Output "       [$evtTime] ID $($evt.Id): $evtMsg"
        }
        $issueCount++
        $eventFound = $true
    }
} catch {
    # No matching events or log not accessible -- not an error
}

# 5b: System log -- firewall service failure events
$sysEventIds = @(5027, 5028, 5030, 5035, 5037)
$sysEventMap = @{
    5027 = 'MpsSvc unable to retrieve security policy from local storage'
    5028 = 'MpsSvc unable to parse security policy'
    5030 = 'Windows Firewall Service failed to start'
    5035 = 'Windows Firewall Driver failed to start'
    5037 = 'Windows Firewall Driver detected critical runtime error'
}

try {
    $sysEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Id = $sysEventIds
        StartTime = $cutoff
    } -MaxEvents 10 -ErrorAction Stop

    if ($null -ne $sysEvents -and @($sysEvents).Count -gt 0) {
        $sEvtArray = @($sysEvents)
        Write-Output "[!!]  System Log: $($sEvtArray.Count) firewall service error(s) in last 24h"
        $showCount = [math]::Min($sEvtArray.Count, 5)
        for ($e = 0; $e -lt $showCount; $e++) {
            $evt = $sEvtArray[$e]
            $evtTime = $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            $evtId = $evt.Id
            $evtDesc = ''

            if ($sysEventMap.ContainsKey($evtId)) {
                $evtDesc = $sysEventMap[$evtId]
            } else {
                $evtDesc = "$($evt.Message)"
                if ($evtDesc.Length -gt 80) { $evtDesc = $evtDesc.Substring(0, 77) + '...' }
            }
            Write-Output "       [$evtTime] ID $evtId -- $evtDesc"
        }
        $issueCount++
        $eventFound = $true
    }
} catch {
    # No matching events or log not accessible -- not an error
}

if (-not $eventFound) {
    Write-Output '[OK]  No Errors (Last 24h)'
    Write-Output '       No firewall service failure events found in System or WFAS logs.'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. Firewall service infrastructure is healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If BFE or RpcSs stopped     -> restart the dependency chain (run FW006 FWRemediation)'
Write-Output '        If service descriptor tampered -> run FW006 FWRemediation to reset'
Write-Output '        If WFP degraded             -> may require reboot or deeper investigation'
Write-Output '        If all clean                -> run FW005 FWRuleDiagnostic to check for rule corruption'
Write-Output ''
