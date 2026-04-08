# WU009_WUServiceReset.ps1
# Scriptlet: WU009 - WU Service & Dependency Reset
# Context: System | Version: 1.1

$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== Windows Update Service & Dependency Reset ==='

# ============================================================
# Pre-Remediation State Capture
# ============================================================
Write-Output ''
Write-Output '--- Capturing Pre-Remediation State ---'

$logDir = 'C:\ProgramData\Indago\Logs'
if (-not (Test-Path $logDir)) {
    $null = New-Item -Path $logDir -ItemType Directory -Force
}

# Services to manage (ordered: dependents first for stop, reversed for start)
$serviceNames = @('UsoSvc', 'wuauserv', 'BITS', 'CryptSvc', 'AppIDSvc')

$preState = @{
    Timestamp = $ts
    Services  = @()
    SoftwareDistributionSizeMB = $null
    Catroot2SizeMB             = $null
}

foreach ($svcName in $serviceNames) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        $preState.Services += @{
            Name      = $svcName
            Status    = $svc.Status.ToString()
            StartType = $svc.StartType.ToString()
        }
    } catch {
        $preState.Services += @{
            Name      = $svcName
            Status    = 'NotFound'
            StartType = 'Unknown'
        }
    }
}

# Capture cache folder sizes
$sdPath = Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution'
$crPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\catroot2'

if (Test-Path $sdPath) {
    try {
        $sdSize = (Get-ChildItem -Path $sdPath -Recurse -File -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sdSize) { $sdSize = 0 }
        $preState.SoftwareDistributionSizeMB = [math]::Round($sdSize / 1MB, 1)
    } catch { }
}
if (Test-Path $crPath) {
    try {
        $crSize = (Get-ChildItem -Path $crPath -Recurse -File -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
        if ($null -eq $crSize) { $crSize = 0 }
        $preState.Catroot2SizeMB = [math]::Round($crSize / 1MB, 1)
    } catch { }
}

# Save pre-state to JSON
$preStatePath = Join-Path -Path $logDir -ChildPath "WU009_PreState_$ts.json"
try {
    $preState | ConvertTo-Json -Depth 5 | Out-File -FilePath $preStatePath -Encoding UTF8 -Force
    $findings.Add([PSCustomObject]@{
        Check  = 'Pre-State Capture'
        Status = 'OK'
        Detail = "Pre-remediation state saved to $preStatePath"
    })
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Pre-State Capture'
        Status = 'WARN'
        Detail = "Could not save pre-state: $($_.Exception.Message). Continuing with remediation."
    })
}

# ============================================================
# Step 1 -- Stop Services
# ============================================================
Write-Output ''
Write-Output '--- Step 1: Stopping Services ---'

$stopResults = @{}

foreach ($svcName in $serviceNames) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = "Stop: $svcName"
            Status = 'INFO'
            Detail = "$svcName service not found on this system. Skipping."
        })
        $stopResults[$svcName] = 'NotFound'
        continue
    }

    if ($svc.Status -eq 'Stopped') {
        $findings.Add([PSCustomObject]@{
            Check  = "Stop: $svcName"
            Status = 'OK'
            Detail = "$svcName was already stopped. No action needed."
        })
        $stopResults[$svcName] = 'AlreadyStopped'
        continue
    }

    # Attempt graceful stop
    try {
        Stop-Service -Name $svcName -Force -ErrorAction Stop
        # Verify it stopped
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') {
            $findings.Add([PSCustomObject]@{
                Check  = "Stop: $svcName"
                Status = 'OK'
                Detail = "$svcName stopped successfully."
            })
            $stopResults[$svcName] = 'Stopped'
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Stop: $svcName"
                Status = 'WARN'
                Detail = "$svcName stop requested but service reports status: $($svc.Status). Proceeding."
            })
            $stopResults[$svcName] = 'Uncertain'
        }
    } catch {
        # Stop failed -- report with guidance
        $findings.Add([PSCustomObject]@{
            Check  = "Stop: $svcName"
            Status = 'ISSUE'
            Detail = "Failed to stop $svcName -- $($_.Exception.Message). Cache rename may fail if this service holds a file lock."
        })
        $stopResults[$svcName] = 'Failed'
    }
}

# Brief pause to let service handles release
Start-Sleep -Seconds 2

# Clear BITS download queue files
# Corrupt qmgr*.dat files persist across BITS restarts and cause recurring
# download failures. BITS regenerates them cleanly on next service start.
$bitsQueuePath = Join-Path $env:ALLUSERSPROFILE 'Microsoft\Network\Downloader'
if (Test-Path $bitsQueuePath) {
    $qmgrFiles = @(Get-ChildItem -Path $bitsQueuePath -Filter 'qmgr*.dat' -ErrorAction SilentlyContinue)
    if ($qmgrFiles.Count -gt 0) {
        $removedCount = 0
        foreach ($qf in $qmgrFiles) {
            try {
                Remove-Item -Path $qf.FullName -Force -ErrorAction Stop
                $removedCount++
            } catch { }
        }
        if ($removedCount -gt 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'BITS Queue Cleanup'
                Status = 'OK'
                Detail = "Cleared $removedCount BITS queue file(s) from $bitsQueuePath. BITS will rebuild its download queue on restart."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'BITS Queue Cleanup'
                Status = 'WARN'
                Detail = "Found $($qmgrFiles.Count) BITS queue file(s) but could not remove them. BITS service may still hold a lock."
            })
        }
    }
}

# ============================================================
# Step 2 -- Rename Cache Directories
# ============================================================
Write-Output ''
Write-Output '--- Step 2: Renaming Cache Directories ---'

$sdRenamed = $false
$crRenamed = $false

# 2a -- SoftwareDistribution
$sdBakName = "SoftwareDistribution.bak.$ts"
if (Test-Path $sdPath) {
    $sdSizeMB = $preState.SoftwareDistributionSizeMB
    if ($null -eq $sdSizeMB) { $sdSizeMB = '?' }
    try {
        Rename-Item -Path $sdPath -NewName $sdBakName -Force -ErrorAction Stop
        $sdRenamed = $true
        $findings.Add([PSCustomObject]@{
            Check  = 'Rename: SoftwareDistribution'
            Status = 'OK'
            Detail = "Renamed to $sdBakName ($sdSizeMB MB). Windows Update will recreate this folder on next scan."
        })
    } catch {
        $errMsg = $_.Exception.Message
        $findings.Add([PSCustomObject]@{
            Check  = 'Rename: SoftwareDistribution'
            Status = 'ISSUE'
            Detail = "Failed to rename SoftwareDistribution -- $errMsg"
        })

        # Identify likely locking processes
        $lockInfo = [System.Collections.Generic.List[string]]::new()
        foreach ($sn in $serviceNames) {
            try {
                $lockSvc = Get-Service -Name $sn -ErrorAction Stop
                if ($lockSvc.Status -ne 'Stopped') {
                    # Get the PID of the service process
                    $cimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$sn'" -ErrorAction SilentlyContinue
                    if ($null -ne $cimSvc -and $cimSvc.ProcessId -gt 0) {
                        $null = $lockInfo.Add("$sn (PID $($cimSvc.ProcessId)) is still running. Kill with: taskkill /F /PID $($cimSvc.ProcessId)")
                    } else {
                        $null = $lockInfo.Add("$sn is still running (could not resolve PID)")
                    }
                }
            } catch { }
        }

        if ($lockInfo.Count -gt 0) {
            foreach ($li in $lockInfo) {
                $findings.Add([PSCustomObject]@{
                    Check  = '  Lock candidate'
                    Status = 'INFO'
                    Detail = $li
                })
            }
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = '  Lock candidate'
                Status = 'INFO'
                Detail = 'All target services appear stopped. Lock may be held by another process (e.g. antivirus). Use Process Explorer or handle.exe to identify.'
            })
        }
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Rename: SoftwareDistribution'
        Status = 'WARN'
        Detail = "SoftwareDistribution folder not found at $sdPath. This is unusual but not fatal -- Windows Update will recreate it."
    })
}

# 2b -- catroot2
$crBakName = "catroot2.bak.$ts"
if (Test-Path $crPath) {
    $crSizeMB = $preState.Catroot2SizeMB
    if ($null -eq $crSizeMB) { $crSizeMB = '?' }
    try {
        Rename-Item -Path $crPath -NewName $crBakName -Force -ErrorAction Stop
        $crRenamed = $true
        $findings.Add([PSCustomObject]@{
            Check  = 'Rename: catroot2'
            Status = 'OK'
            Detail = "Renamed to $crBakName ($crSizeMB MB). CryptSvc will rebuild trust database on restart."
        })
    } catch {
        $errMsg = $_.Exception.Message
        $findings.Add([PSCustomObject]@{
            Check  = 'Rename: catroot2'
            Status = 'ISSUE'
            Detail = "Failed to rename catroot2 -- $errMsg"
        })

        # Check if CryptSvc is still running
        try {
            $cryptSvc = Get-Service -Name 'CryptSvc' -ErrorAction Stop
            if ($cryptSvc.Status -ne 'Stopped') {
                $cimCrypt = Get-CimInstance -ClassName Win32_Service -Filter "Name='CryptSvc'" -ErrorAction SilentlyContinue
                if ($null -ne $cimCrypt -and $cimCrypt.ProcessId -gt 0) {
                    $findings.Add([PSCustomObject]@{
                        Check  = '  Lock candidate'
                        Status = 'INFO'
                        Detail = "CryptSvc (PID $($cimCrypt.ProcessId)) is still running. Kill with: taskkill /F /PID $($cimCrypt.ProcessId)"
                    })
                }
            }
        } catch { }
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Rename: catroot2'
        Status = 'WARN'
        Detail = "catroot2 folder not found at $crPath. CryptSvc will recreate it on restart."
    })
}

# ============================================================
# Step 3 -- Re-register COM DLLs
# ============================================================
Write-Output ''
Write-Output '--- Step 3: Re-registering COM DLLs ---'

$dllList = @(
    'wuaueng.dll'
    'wuapi.dll'
    'wups.dll'
    'wups2.dll'
    'wuwebv.dll'
    'atl.dll'
    'urlmon.dll'
    'mshtml.dll'
)

$dllSuccessCount = 0
$dllFailCount = 0
$dllSkipCount = 0

foreach ($dll in $dllList) {
    $dllPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\$dll"
    if (-not (Test-Path $dllPath)) {
        $dllSkipCount++
        $findings.Add([PSCustomObject]@{
            Check  = "DLL: $dll"
            Status = 'WARN'
            Detail = "File not found at $dllPath. Skipping registration."
        })
        continue
    }

    try {
        $regResult = & regsvr32.exe /s $dllPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            $dllSuccessCount++
        } else {
            $dllFailCount++
            $findings.Add([PSCustomObject]@{
                Check  = "DLL: $dll"
                Status = 'WARN'
                Detail = "regsvr32 returned exit code $LASTEXITCODE for $dll. Registration may have failed."
            })
        }
    } catch {
        $dllFailCount++
        $findings.Add([PSCustomObject]@{
            Check  = "DLL: $dll"
            Status = 'WARN'
            Detail = "Error running regsvr32 for $dll -- $($_.Exception.Message)"
        })
    }
}

# Summary for DLL registration
if ($dllFailCount -eq 0 -and $dllSkipCount -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'OK'
        Detail = "All $dllSuccessCount DLLs re-registered successfully."
    })
} elseif ($dllFailCount -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'OK'
        Detail = "$dllSuccessCount DLL(s) re-registered. $dllSkipCount DLL(s) not found (skipped)."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'WARN'
        Detail = "$dllSuccessCount succeeded, $dllFailCount failed, $dllSkipCount skipped. Failed DLLs are listed above. If failures persist, run WU008 WUDatastoreRepair for a full COM re-registration."
    })
}

# ============================================================
# Step 4 -- Reset Winsock
# ============================================================
Write-Output ''
Write-Output '--- Step 4: Resetting Winsock ---'

$winsockResetDone = $false
try {
    $winsockOutput = & netsh winsock reset 2>&1
    $winsockText = ($winsockOutput | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        $winsockResetDone = $true
        $findings.Add([PSCustomObject]@{
            Check  = 'Winsock Reset'
            Status = 'OK'
            Detail = "Winsock catalog reset completed. Output: $winsockText"
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Winsock Reset'
            Status = 'WARN'
            Detail = "netsh winsock reset returned exit code $LASTEXITCODE. Output: $winsockText"
        })
    }
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Winsock Reset'
        Status = 'WARN'
        Detail = "Error executing netsh winsock reset -- $($_.Exception.Message)"
    })
}

# ============================================================
# Step 5 -- Restart Services
# ============================================================
Write-Output ''
Write-Output '--- Step 5: Restarting Services ---'

# Start in reverse order (dependencies first)
$startOrder = @('AppIDSvc', 'CryptSvc', 'BITS', 'wuauserv', 'UsoSvc')

foreach ($svcName in $startOrder) {
    # Skip services we never touched
    if ($stopResults.ContainsKey($svcName) -and $stopResults[$svcName] -eq 'NotFound') {
        continue
    }

    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
    } catch {
        continue
    }

    # Check the original start type -- do not start Disabled services
    $origEntry = $preState.Services | Where-Object { $_.Name -eq $svcName }
    if ($null -ne $origEntry -and $origEntry.StartType -eq 'Disabled') {
        $findings.Add([PSCustomObject]@{
            Check  = "Start: $svcName"
            Status = 'INFO'
            Detail = "$svcName was Disabled before remediation. Not starting it -- original state preserved. If this service should be enabled, set it to Manual first."
        })
        continue
    }

    # For Manual-start services, attempt to start but accept Stopped as OK
    $isManualStart = ($null -ne $origEntry -and $origEntry.StartType -eq 'Manual')

    if ($svc.Status -eq 'Running') {
        $findings.Add([PSCustomObject]@{
            Check  = "Start: $svcName"
            Status = 'OK'
            Detail = "$svcName is already running."
        })
        continue
    }

    try {
        Start-Service -Name $svcName -ErrorAction Stop
        Start-Sleep -Seconds 1
        $svc.Refresh()

        if ($svc.Status -eq 'Running') {
            $findings.Add([PSCustomObject]@{
                Check  = "Start: $svcName"
                Status = 'OK'
                Detail = "$svcName started successfully. Status: Running."
            })
        } elseif ($isManualStart) {
            $findings.Add([PSCustomObject]@{
                Check  = "Start: $svcName"
                Status = 'OK'
                Detail = "$svcName start type is Manual -- it may stop itself when idle. Current status: $($svc.Status). This is normal."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Start: $svcName"
                Status = 'WARN'
                Detail = "$svcName started but reports status: $($svc.Status). It may still be initializing."
            })
        }
    } catch {
        if ($isManualStart) {
            $findings.Add([PSCustomObject]@{
                Check  = "Start: $svcName"
                Status = 'INFO'
                Detail = "$svcName (Manual start) did not start -- $($_.Exception.Message). This service starts on demand, so this may be normal."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Start: $svcName"
                Status = 'ISSUE'
                Detail = "Failed to start $svcName -- $($_.Exception.Message). Run WU001 WUQuickHealth to assess impact."
            })
        }
    }
}

# ============================================================
# Step 6 -- Post-Remediation Verification
# ============================================================
Write-Output ''
Write-Output '--- Step 6: Verification ---'

# 6a -- Check that SoftwareDistribution was recreated or still exists as .bak
if ($sdRenamed) {
    $sdBakPath = Join-Path -Path $env:SystemRoot -ChildPath $sdBakName
    if (Test-Path $sdBakPath) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: SoftwareDistribution.bak'
            Status = 'OK'
            Detail = "Backup folder exists at $sdBakPath. Can be safely deleted after confirming WU works."
        })
    }
    # Check if a new SoftwareDistribution was created
    if (Test-Path $sdPath) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: New SoftwareDistribution'
            Status = 'OK'
            Detail = 'New SoftwareDistribution folder was auto-created by the WU engine. Cache rebuild is underway.'
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: New SoftwareDistribution'
            Status = 'INFO'
            Detail = 'New SoftwareDistribution folder has not been created yet. It will be created on the next WU scan cycle.'
        })
    }
}

# 6b -- catroot2 verification
if ($crRenamed) {
    $crBakPath = Join-Path -Path (Join-Path -Path $env:SystemRoot -ChildPath 'System32') -ChildPath $crBakName
    if (Test-Path $crBakPath) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: catroot2.bak'
            Status = 'OK'
            Detail = "Backup folder exists at $crBakPath. Can be safely deleted after confirming WU works."
        })
    }
}

# 6c -- Reboot advisory
$rebootNeeded = $false
if ($winsockResetDone) {
    $rebootNeeded = $true
}
# Check CBS reboot pending
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $rebootNeeded = $true
}

if ($rebootNeeded) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Reboot Advisory'
        Status = 'INFO'
        Detail = 'A reboot is recommended to finalize the Winsock reset and allow WU to fully reinitialize. Schedule a reboot at the earliest convenience.'
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
    Write-Output 'RESULT: Service reset completed successfully. All steps passed.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: Service reset completed with $warnCount warning(s). Review items marked [!] above."
} else {
    Write-Output "RESULT: Service reset completed with $issueCount issue(s) and $warnCount warning(s). Review items marked [!!] above."
}

Write-Output ''
Write-Output 'NEXT:   Run WU001 WUQuickHealth to verify services are healthy after reset.'
Write-Output '        If issues persist -> run WU008 WUDatastoreRepair for deeper repair.'
Write-Output ''
