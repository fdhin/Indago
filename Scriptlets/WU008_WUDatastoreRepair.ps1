# WU008_WUDatastoreRepair.ps1
# Scriptlet: WU008 - WU Database & Datastore Repair
# Context: System | Version: 1.2

$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== Windows Update Database & Datastore Repair ==='

# ============================================================
# Step 0 -- Pre-Remediation State Capture
# ============================================================
Write-Output ''
Write-Output '--- Step 0: Capturing Pre-Remediation State ---'

$logDir = 'C:\ProgramData\Indago\Logs'
if (-not (Test-Path $logDir)) {
    $null = New-Item -Path $logDir -ItemType Directory -Force
}

$preState = @{
    Timestamp = $ts
}

# DataStore.edb state
$dsPath = Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\DataStore\DataStore.edb'
$dsLogsPath = Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution\DataStore\Logs'

try {
    if (Test-Path $dsPath) {
        $dsFile = Get-Item -Path $dsPath -ErrorAction Stop
        $preState.DataStoreExists = $true
        $preState.DataStoreSizeMB = [math]::Round($dsFile.Length / 1MB, 2)
        $preState.DataStoreLastModified = $dsFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    } else {
        $preState.DataStoreExists = $false
        $preState.DataStoreSizeMB = 0
        $preState.DataStoreLastModified = 'N/A'
    }
} catch {
    $preState.DataStoreError = $_.Exception.Message
}

# ESE transaction log count
try {
    if (Test-Path $dsLogsPath) {
        $logFiles = @(Get-ChildItem -Path $dsLogsPath -Filter '*.log' -ErrorAction SilentlyContinue)
        $preState.ESELogFileCount = $logFiles.Count
    } else {
        $preState.ESELogFileCount = 0
    }
} catch {
    $preState.ESELogFileCount = -1
}

# BITS jobs
try {
    $bitsJobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
    $preState.BitsJobCount = $bitsJobs.Count
    $errorJobs = @($bitsJobs | Where-Object { $_.JobState -eq 'Error' -or $_.JobState -eq 'TransientError' })
    $preState.BitsErrorJobCount = $errorJobs.Count
} catch {
    $preState.BitsJobCount = 0
    $preState.BitsErrorJobCount = 0
    $preState.BitsQueryError = $_.Exception.Message
}

# pending.xml
$pendingXmlPath = Join-Path -Path $env:SystemRoot -ChildPath 'WinSxS\pending.xml'
try {
    if (Test-Path $pendingXmlPath) {
        $pxFile = Get-Item -Path $pendingXmlPath -ErrorAction Stop
        $preState.PendingXmlExists = $true
        $preState.PendingXmlSizeKB = [math]::Round($pxFile.Length / 1KB, 2)
        $preState.PendingXmlLastModified = $pxFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $preState.PendingXmlAgeDays = [math]::Round(((Get-Date) - $pxFile.LastWriteTime).TotalDays, 1)
    } else {
        $preState.PendingXmlExists = $false
    }
} catch {
    $preState.PendingXmlError = $_.Exception.Message
}

# Service states
$svcNames = @('wuauserv', 'BITS', 'CryptSvc', 'UsoSvc')
$svcStates = @{}
foreach ($sn in $svcNames) {
    try {
        $svc = Get-Service -Name $sn -ErrorAction Stop
        $svcStates[$sn] = $svc.Status.ToString()
    } catch {
        $svcStates[$sn] = 'NotFound'
    }
}
$preState.Services = $svcStates

# Service security descriptors (for advisory audit)
$sddlCapture = @{}
foreach ($sn in @('wuauserv', 'BITS', 'CryptSvc')) {
    try {
        $scOutput = & sc.exe sdshow $sn 2>&1
        $sddlString = ($scOutput | Where-Object { $_ -match '^D:' }) -join ''
        if ($sddlString) {
            $sddlCapture[$sn] = $sddlString.Trim()
        } else {
            $sddlCapture[$sn] = 'Could not parse'
        }
    } catch {
        $sddlCapture[$sn] = "Error: $($_.Exception.Message)"
    }
}
$preState.ServiceSDDL = $sddlCapture

# Save pre-state
$preStatePath = Join-Path -Path $logDir -ChildPath "WU008_PreState_$ts.json"
try {
    $preState | ConvertTo-Json -Depth 5 | Out-File -FilePath $preStatePath -Encoding ascii -Force
    $findings.Add([PSCustomObject]@{
        Check  = 'Pre-Remediation State'
        Status = 'OK'
        Detail = "Pre-state saved to $preStatePath"
    })
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Pre-Remediation State'
        Status = 'WARN'
        Detail = "Could not save pre-state: $($_.Exception.Message)"
    })
}

# ============================================================
# Step 1 -- DataStore.edb Integrity Check & Repair
# ============================================================
Write-Output ''
Write-Output '--- Step 1: DataStore.edb Integrity Check ---'

$dsNeedsRepair = $false
$dsRepairReason = ''

if (-not (Test-Path $dsPath)) {
    # DataStore.edb is missing -- WU agent will recreate it on next scan
    $findings.Add([PSCustomObject]@{
        Check  = 'DataStore.edb: Existence'
        Status = 'INFO'
        Detail = "DataStore.edb not found at $dsPath. The WU agent will recreate it automatically on the next scan. This is not an error."
    })
} else {
    $dsFile = Get-Item -Path $dsPath -ErrorAction SilentlyContinue

    # Check 1: File size
    if ($dsFile) {
        $dsSizeMB = [math]::Round($dsFile.Length / 1MB, 2)

        if ($dsSizeMB -gt 1500) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore.edb: Size'
                Status = 'ISSUE'
                Detail = "DataStore.edb is $dsSizeMB MB. Over 1500 MB indicates severe corruption or orphaned transaction accumulation. Marking for rebuild."
            })
            $dsNeedsRepair = $true
            $dsRepairReason = "Size: $dsSizeMB MB (>1500 MB threshold)"
        } elseif ($dsSizeMB -gt 800) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore.edb: Size'
                Status = 'WARN'
                Detail = "DataStore.edb is $dsSizeMB MB. Over 800 MB is large for a healthy database. Modern Windows 10/11 cumulative updates can grow the catalog to 400-800 MB normally, but beyond 800 MB may indicate stale metadata accumulation."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore.edb: Size'
                Status = 'OK'
                Detail = "DataStore.edb is $dsSizeMB MB. Within normal range."
            })
        }

        # Check 2: Last modified date
        $dsAgeDays = [math]::Round(((Get-Date) - $dsFile.LastWriteTime).TotalDays, 1)
        if ($dsAgeDays -gt 30) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore.edb: Freshness'
                Status = 'WARN'
                Detail = "DataStore.edb last modified $dsAgeDays days ago ($($dsFile.LastWriteTime.ToString('yyyy-MM-dd'))). If the system has pending updates, the WU agent is not writing to this database. This suggests a stuck scan or service failure."
            })
            # Only auto-repair if the file is also bloated
            if ($dsSizeMB -gt 800) {
                $dsNeedsRepair = $true
                $dsRepairReason = "Stale ($dsAgeDays days) + oversized ($dsSizeMB MB)"
            }
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore.edb: Freshness'
                Status = 'OK'
                Detail = "DataStore.edb last modified $dsAgeDays day(s) ago. Database is actively used."
            })
        }
    }

    # Check 3: ESE transaction logs
    if (Test-Path $dsLogsPath) {
        $logFiles = @(Get-ChildItem -Path $dsLogsPath -Filter '*.log' -ErrorAction SilentlyContinue)
        $logCount = $logFiles.Count

        if ($logCount -gt 50) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore: ESE Logs'
                Status = 'ISSUE'
                Detail = "$logCount ESE transaction log files found in DataStore\Logs\. Normal is 0-5. This many logs means the database engine cannot commit transactions and is stuck in a recovery/replay loop. Marking for rebuild."
            })
            $dsNeedsRepair = $true
            $dsRepairReason = "ESE log accumulation: $logCount files"
        } elseif ($logCount -gt 10) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore: ESE Logs'
                Status = 'WARN'
                Detail = "$logCount ESE transaction log files found. Normal is 0-5. Some log accumulation detected but not critical."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore: ESE Logs'
                Status = 'OK'
                Detail = "$logCount ESE transaction log file(s) found. Healthy."
            })
        }
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'DataStore: ESE Logs'
            Status = 'INFO'
            Detail = "DataStore Logs directory not found. The WU agent will recreate it on next scan."
        })
    }
}

# Repair if needed: stop services, rename DataStore.edb, clear ESE logs, restart
if ($dsNeedsRepair) {
    Write-Output ''
    Write-Output '--- Step 1b: DataStore.edb Rebuild ---'

    $findings.Add([PSCustomObject]@{
        Check  = 'DataStore Rebuild: Reason'
        Status = 'INFO'
        Detail = "Initiating rebuild. Trigger: $dsRepairReason"
    })

    # Stop wuauserv and BITS (required to release the database lock)
    $stoppedServices = [System.Collections.Generic.List[string]]::new()
    foreach ($svcToStop in @('UsoSvc', 'wuauserv', 'BITS', 'CryptSvc')) {
        try {
            $svc = Get-Service -Name $svcToStop -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $svcToStop -Force -ErrorAction Stop
                Start-Sleep -Seconds 2
                $stoppedServices.Add($svcToStop)
                $findings.Add([PSCustomObject]@{
                    Check  = "DataStore Rebuild: Stop $svcToStop"
                    Status = 'OK'
                    Detail = "$svcToStop stopped successfully."
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = "DataStore Rebuild: Stop $svcToStop"
                    Status = 'INFO'
                    Detail = "$svcToStop was already stopped."
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = "DataStore Rebuild: Stop $svcToStop"
                Status = 'WARN'
                Detail = "Could not stop $svcToStop : $($_.Exception.Message). DataStore rename may fail if the file is locked."
            })
        }
    }

    # Rename DataStore.edb
    $dsRenamed = $false
    if (Test-Path $dsPath) {
        $bakName = "DataStore.edb.bak_$ts"
        $bakPath = Join-Path -Path (Split-Path $dsPath) -ChildPath $bakName
        try {
            Rename-Item -Path $dsPath -NewName $bakName -Force -ErrorAction Stop
            $dsRenamed = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore Rebuild: Rename'
                Status = 'OK'
                Detail = "DataStore.edb renamed to $bakName. A fresh database will be created on next WU scan."
            })
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore Rebuild: Rename'
                Status = 'ISSUE'
                Detail = "Could not rename DataStore.edb: $($_.Exception.Message). The file may still be locked. Try stopping all WU-related services manually, then re-run."
            })
        }
    }

    # Clear ESE transaction logs -- ONLY if DataStore.edb was successfully renamed.
    # If the rename failed, ESE logs are needed for database recovery.
    if ($dsRenamed -and (Test-Path $dsLogsPath)) {
        $eseLogFiles = @(Get-ChildItem -Path $dsLogsPath -Filter '*.log' -ErrorAction SilentlyContinue)
        $clearedCount = 0
        foreach ($lf in $eseLogFiles) {
            try {
                $logBakName = "$($lf.Name).bak_$ts"
                Rename-Item -Path $lf.FullName -NewName $logBakName -Force -ErrorAction Stop
                $clearedCount++
            } catch {
                # silently skip -- not critical if some logs can't be renamed
            }
        }
        if ($clearedCount -gt 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'DataStore Rebuild: ESE Logs'
                Status = 'OK'
                Detail = "$clearedCount ESE log file(s) renamed to .bak. Clean transaction logs will be created on next scan."
            })
        }
    } elseif (-not $dsRenamed -and (Test-Path $dsLogsPath)) {
        $findings.Add([PSCustomObject]@{
            Check  = 'DataStore Rebuild: ESE Logs'
            Status = 'INFO'
            Detail = 'ESE transaction logs preserved. The database rename failed, so logs are needed for potential recovery.'
        })
    }

    # Restart stopped services in dependency order (reverse of stop order)
    # Stop order: UsoSvc, wuauserv, BITS, CryptSvc
    # Start order: CryptSvc, BITS, wuauserv, UsoSvc
    $restartOrder = @('CryptSvc', 'BITS', 'wuauserv', 'UsoSvc')
    foreach ($svcToStart in $restartOrder) {
        if ($stoppedServices -notcontains $svcToStart) { continue }
        try {
            Start-Service -Name $svcToStart -ErrorAction Stop
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name $svcToStart -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                $findings.Add([PSCustomObject]@{
                    Check  = "DataStore Rebuild: Start $svcToStart"
                    Status = 'OK'
                    Detail = "$svcToStart restarted successfully."
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = "DataStore Rebuild: Start $svcToStart"
                    Status = 'WARN'
                    Detail = "$svcToStart status is $($svc.Status) after restart attempt."
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = "DataStore Rebuild: Start $svcToStart"
                Status = 'WARN'
                Detail = "Could not restart $svcToStart : $($_.Exception.Message). It should auto-start on next trigger."
            })
        }
    }

    $findings.Add([PSCustomObject]@{
        Check  = 'DataStore Rebuild: Summary'
        Status = 'OK'
        Detail = 'DataStore rebuild initiated. The next WU scan will take longer (full resync vs delta). Run WU001 WUQuickHealth after the scan completes to verify.'
    })
} else {
    if (Test-Path $dsPath) {
        $findings.Add([PSCustomObject]@{
            Check  = 'DataStore: Verdict'
            Status = 'OK'
            Detail = 'DataStore.edb passed all integrity checks. No rebuild needed.'
        })
    }
}

# ============================================================
# Step 2 -- Full COM Re-registration (17 DLLs)
# ============================================================
Write-Output ''
Write-Output '--- Step 2: COM DLL Re-registration ---'

# Vision spec: full 17-DLL superset (WU009 has 8 of these)
$dllList = @(
    'wuaueng.dll'     # WUA engine
    'wuapi.dll'       # WUA API
    'wups.dll'        # WU proxy stub
    'wups2.dll'       # WU proxy stub 2
    'wuwebv.dll'      # WU web viewer
    'wucltux.dll'     # WU client UX
    'wudriver.dll'    # WU driver
    'atl.dll'         # Active Template Library
    'urlmon.dll'      # URL moniker (HTTP/BITS)
    'mshtml.dll'      # HTML rendering engine
    'msxml.dll'       # XML parser (legacy)
    'msxml3.dll'      # XML parser v3
    'msxml6.dll'      # XML parser v6
    'jscript.dll'     # JScript engine
    'scrrun.dll'      # Script runtime
    'shdocvw.dll'     # Shell doc object viewer
    'softpub.dll'     # Software publishing trust (Authenticode)
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
            Status = 'INFO'
            Detail = "$dll not found in System32. Skipped. This DLL may not be present on this OS edition."
        })
    } else {
        try {
            $null = & regsvr32.exe /s $dllPath 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dllSuccessCount++
            } else {
                $dllFailCount++
                $findings.Add([PSCustomObject]@{
                    Check  = "DLL: $dll"
                    Status = 'WARN'
                    Detail = "regsvr32 returned exit code $LASTEXITCODE for $dll. Registration may have failed. This DLL may not support self-registration."
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
}

# Summary for DLL registration
if ($dllFailCount -eq 0 -and $dllSkipCount -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'OK'
        Detail = "All $dllSuccessCount of $($dllList.Count) DLLs re-registered successfully."
    })
} elseif ($dllFailCount -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'OK'
        Detail = "$dllSuccessCount DLL(s) re-registered. $dllSkipCount DLL(s) not found (skipped -- normal for some OS editions)."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'COM DLL Registration'
        Status = 'WARN'
        Detail = "$dllSuccessCount succeeded, $dllFailCount failed, $dllSkipCount skipped. Failed DLLs are listed above. Failures in msxml.dll or shdocvw.dll are often benign on modern Windows."
    })
}

# ============================================================
# Step 3 -- Security Descriptor Audit (Advisory Only)
# ============================================================
Write-Output ''
Write-Output '--- Step 3: Service Security Descriptor Audit ---'

# Default Windows SDDL for WU-related services.
# We compare the current SDDL to the known defaults and report discrepancies.
# We do NOT overwrite -- enterprise environments customize these via GPO.
$defaultSDDL = @{
    'wuauserv' = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
    'BITS'     = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
    'CryptSvc' = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
}

foreach ($svcName in @('wuauserv', 'BITS', 'CryptSvc')) {
    $currentSDDL = $null
    try {
        $scOutput = & sc.exe sdshow $svcName 2>&1
        # sc.exe sdshow outputs the SDDL on a line starting with D:
        $currentSDDL = ($scOutput | Where-Object { $_ -match '^D:' }) -join ''
        if ($currentSDDL) {
            $currentSDDL = $currentSDDL.Trim()
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = "SDDL: $svcName"
            Status = 'WARN'
            Detail = "Could not query security descriptor for $svcName : $($_.Exception.Message)"
        })
        continue
    }

    if (-not $currentSDDL) {
        $findings.Add([PSCustomObject]@{
            Check  = "SDDL: $svcName"
            Status = 'WARN'
            Detail = "Could not parse SDDL output for $svcName. sc.exe may require elevation or the service name may be incorrect."
        })
        continue
    }

    $expectedSDDL = $defaultSDDL[$svcName]

    if ($currentSDDL -eq $expectedSDDL) {
        $findings.Add([PSCustomObject]@{
            Check  = "SDDL: $svcName"
            Status = 'OK'
            Detail = "Security descriptor matches Windows default."
        })
    } else {
        # Check if the current SDDL is a superset (contains the defaults plus extra ACEs)
        # The default ACEs should still be present even in customized configs
        # ACE format: (AceType;AceFlags;Rights;ObjectGuid;InheritObjectGuid;AccountSid)
        # Use [^)]+ to match any flags/rights, not just empty AceFlags (A;;)
        # GPOs may add inheritance flags like CI/OI making the ACE (A;CI;...;;;SY)
        $hasSystemACE = $currentSDDL -match '\(A;[^)]+;SY\)'
        $hasAdminACE  = $currentSDDL -match '\(A;[^)]+;BA\)'

        if ($hasSystemACE -and $hasAdminACE) {
            $findings.Add([PSCustomObject]@{
                Check  = "SDDL: $svcName"
                Status = 'INFO'
                Detail = "Security descriptor has been customized (differs from Windows default) but still grants SYSTEM and Administrators access. This is likely intentional (GPO, monitoring agent, or SCCM). Current: $currentSDDL"
            })
        } else {
            # Missing SYSTEM or Admin ACE -- this is a real problem
            $missingACEs = @()
            if (-not $hasSystemACE) { $missingACEs += 'SYSTEM (SY)' }
            if (-not $hasAdminACE)  { $missingACEs += 'Administrators (BA)' }

            $findings.Add([PSCustomObject]@{
                Check  = "SDDL: $svcName"
                Status = 'ISSUE'
                Detail = "Security descriptor is missing critical ACE(s): $($missingACEs -join ', '). This may prevent the service from starting or accepting requests. Malware or an aggressive optimizer may have corrupted the DACL. To reset to defaults, run: sc.exe sdset $svcName $expectedSDDL"
            })
        }
    }
}

# ============================================================
# Step 4 -- Stuck BITS Job Cleanup
# ============================================================
Write-Output ''
Write-Output '--- Step 4: BITS Job Cleanup ---'

try {
    $bitsJobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)

    if ($bitsJobs.Count -eq 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'BITS Jobs'
            Status = 'OK'
            Detail = 'No BITS jobs found. Download queue is clean.'
        })
    } else {
        $errorJobs      = @($bitsJobs | Where-Object { $_.JobState -eq 'Error' })
        $transientJobs  = @($bitsJobs | Where-Object { $_.JobState -eq 'TransientError' })
        $suspendedJobs  = @($bitsJobs | Where-Object { $_.JobState -eq 'Suspended' })
        $activeJobs     = @($bitsJobs | Where-Object { $_.JobState -eq 'Transferring' -or $_.JobState -eq 'Queued' -or $_.JobState -eq 'Connecting' })

        $findings.Add([PSCustomObject]@{
            Check  = 'BITS Jobs: Inventory'
            Status = 'INFO'
            Detail = "$($bitsJobs.Count) total BITS job(s). Error: $($errorJobs.Count). TransientError: $($transientJobs.Count). Suspended: $($suspendedJobs.Count). Active: $($activeJobs.Count)."
        })

        # Cancel Error and TransientError jobs
        $cancelledCount = 0
        foreach ($job in ($errorJobs + $transientJobs)) {
            try {
                $jobName = if ($job.DisplayName) { $job.DisplayName } else { '[unnamed]' }
                $jobOwner = if ($job.OwnerAccount) { $job.OwnerAccount } else { 'Unknown' }
                Remove-BitsTransfer -BitsJob $job -ErrorAction Stop
                $cancelledCount++
                $findings.Add([PSCustomObject]@{
                    Check  = "BITS Cancel: $jobName"
                    Status = 'OK'
                    Detail = "Cancelled $($job.JobState) job. Owner: $jobOwner."
                })
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BITS Cancel'
                    Status = 'WARN'
                    Detail = "Could not cancel BITS job: $($_.Exception.Message)"
                })
            }
        }

        # Cancel suspended jobs older than 7 days
        $staleSuspendedCount = 0
        foreach ($job in $suspendedJobs) {
            $jobAgeDays = 0
            try {
                if ($job.CreationTime) {
                    $jobAgeDays = [math]::Round(((Get-Date) - $job.CreationTime).TotalDays, 1)
                }
            } catch { }

            if ($jobAgeDays -gt 7) {
                try {
                    $jobName = if ($job.DisplayName) { $job.DisplayName } else { '[unnamed]' }
                    Remove-BitsTransfer -BitsJob $job -ErrorAction Stop
                    $staleSuspendedCount++
                    $findings.Add([PSCustomObject]@{
                        Check  = "BITS Cancel: Stale suspended"
                        Status = 'OK'
                        Detail = "Cancelled suspended job '$jobName' (age: $jobAgeDays days). Jobs suspended >7 days are abandoned."
                    })
                } catch {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'BITS Cancel: Stale suspended'
                        Status = 'WARN'
                        Detail = "Could not cancel stale suspended job: $($_.Exception.Message)"
                    })
                }
            }
        }

        $totalCancelled = $cancelledCount + $staleSuspendedCount
        if ($totalCancelled -gt 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'BITS Cleanup Summary'
                Status = 'OK'
                Detail = "$totalCancelled stuck/stale BITS job(s) cancelled. The WU agent will re-queue downloads on next scan."
            })
        } elseif ($errorJobs.Count -eq 0 -and $transientJobs.Count -eq 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'BITS Cleanup Summary'
                Status = 'OK'
                Detail = 'No stuck BITS jobs to cancel. All jobs are healthy or active.'
            })
        }
    }
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match 'not recognized\b|CommandNotFoundException') {
        $findings.Add([PSCustomObject]@{
            Check  = 'BITS Jobs'
            Status = 'WARN'
            Detail = "Get-BitsTransfer cmdlet not available. BitsTransfer module may not be loaded. BITS jobs cannot be audited. Run: Import-Module BitsTransfer"
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'BITS Jobs'
            Status = 'WARN'
            Detail = "Could not enumerate BITS jobs: $errMsg"
        })
    }
}

# ============================================================
# Step 5 -- Stale pending.xml Cleanup
# ============================================================
Write-Output ''
Write-Output '--- Step 5: Stale pending.xml Check ---'

if (Test-Path $pendingXmlPath) {
    try {
        $pxFile = Get-Item -Path $pendingXmlPath -ErrorAction Stop
        $pxAgeDays = [math]::Round(((Get-Date) - $pxFile.LastWriteTime).TotalDays, 1)
        $pxSizeKB = [math]::Round($pxFile.Length / 1KB, 2)

        if ($pxAgeDays -gt 7) {
            # Stale -- rename to .bak per vision spec
            $pxBakName = "pending.xml.bak_$ts"
            try {
                # WinSxS files are owned by TrustedInstaller with only RX for Administrators.
                # Must take ownership and grant Full Control before rename is possible.
                $null = & takeown.exe /f $pendingXmlPath /a 2>&1
                $null = & icacls.exe $pendingXmlPath /grant 'Administrators:F' /q 2>&1
                Rename-Item -Path $pendingXmlPath -NewName $pxBakName -Force -ErrorAction Stop
                $findings.Add([PSCustomObject]@{
                    Check  = 'pending.xml'
                    Status = 'OK'
                    Detail = "Stale pending.xml found ($pxAgeDays days old, $pxSizeKB KB). Took ownership, granted Administrators Full Control, renamed to $pxBakName. The servicing stack was holding onto an obsolete pending operation. CBS will recreate if needed."
                })
            } catch {
                # Rename failed -- restore TrustedInstaller ownership so the file
                # is not left in a broken permissions state.
                if (Test-Path $pendingXmlPath) {
                    $null = & icacls.exe $pendingXmlPath /setowner 'NT SERVICE\TrustedInstaller' /q 2>&1
                }
                $findings.Add([PSCustomObject]@{
                    Check  = 'pending.xml'
                    Status = 'ISSUE'
                    Detail = "Stale pending.xml found ($pxAgeDays days old) but could not rename after takeown/icacls attempt: $($_.Exception.Message). TrustedInstaller ownership restored. The file may be actively locked during a servicing operation. A reboot may be required before retrying."
                })
            }
        } else {
            # Exists but recent -- this is normal during active servicing
            $findings.Add([PSCustomObject]@{
                Check  = 'pending.xml'
                Status = 'INFO'
                Detail = "pending.xml exists ($pxAgeDays days old, $pxSizeKB KB). This is normal during active servicing operations. No action taken -- the file is still fresh (<7 days)."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'pending.xml'
            Status = 'WARN'
            Detail = "Could not inspect pending.xml: $($_.Exception.Message)"
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'pending.xml'
        Status = 'OK'
        Detail = 'No pending.xml found in WinSxS. No stale servicing operations pending.'
    })
}

# ============================================================
# Step 6 -- Post-Remediation Verification
# ============================================================
Write-Output ''
Write-Output '--- Step 6: Post-Remediation Verification ---'

# Re-check DataStore.edb
if (Test-Path $dsPath) {
    try {
        $postDs = Get-Item -Path $dsPath -ErrorAction Stop
        $postDsSizeMB = [math]::Round($postDs.Length / 1MB, 2)
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: DataStore.edb'
            Status = 'OK'
            Detail = "DataStore.edb present. Size: $postDsSizeMB MB."
        })
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: DataStore.edb'
            Status = 'WARN'
            Detail = "Could not query DataStore.edb: $($_.Exception.Message)"
        })
    }
} else {
    # If we renamed it, it's expected to be missing until the next WU scan recreates it
    if ($dsNeedsRepair) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: DataStore.edb'
            Status = 'OK'
            Detail = 'DataStore.edb was renamed for rebuild. A fresh database will be created on the next WU scan.'
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: DataStore.edb'
            Status = 'INFO'
            Detail = 'DataStore.edb not present. Will be recreated on next WU scan.'
        })
    }
}

# Re-check services
foreach ($svcName in @('wuauserv', 'BITS', 'CryptSvc', 'UsoSvc')) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            $findings.Add([PSCustomObject]@{
                Check  = "Verify: $svcName"
                Status = 'OK'
                Detail = "$svcName is running."
            })
        } else {
            # wuauserv and UsoSvc often run on-demand (Trigger Start), so Stopped is acceptable
            if ($svcName -eq 'wuauserv' -or $svcName -eq 'UsoSvc') {
                $findings.Add([PSCustomObject]@{
                    Check  = "Verify: $svcName"
                    Status = 'INFO'
                    Detail = "$svcName status: $($svc.Status). This service uses trigger-start and may not be running continuously. It will start on next WU event."
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = "Verify: $svcName"
                    Status = 'WARN'
                    Detail = "$svcName status: $($svc.Status). Expected: Running."
                })
            }
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = "Verify: $svcName"
            Status = 'WARN'
            Detail = "$svcName service not found."
        })
    }
}

# Check for pending reboot
# CBS RebootPending and WU RebootRequired are registry SUBKEYS (directories),
# not property values. Their mere existence signals a pending reboot.
$rebootPending = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $rebootPending = $true
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $rebootPending = $true
}

if ($rebootPending) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Reboot Status'
        Status = 'WARN'
        Detail = 'A reboot is pending on this system. Some changes may not take full effect until the machine is restarted.'
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
    Write-Output 'RESULT: Datastore repair completed successfully. All steps passed.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: Datastore repair completed with $warnCount warning(s). Review items marked [!] above."
} else {
    Write-Output "RESULT: Datastore repair completed with $issueCount issue(s) and $warnCount warning(s). Review items marked [!!] above."
}

Write-Output ''
Write-Output "NEXT:   Pre-remediation state saved to $preStatePath"
Write-Output '        Run WU001 WUQuickHealth to verify the fix.'
Write-Output '        If issues persist -> run WU010 WUServicingRepair (nuclear option).'
Write-Output ''
