# WU001_WUQuickHealth.ps1
# Scriptlet: WU001 - Windows Update Quick Health Check
# Context: System | Version: 2.2

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$daysBack = if ($Param1) { [int]$Param1 } else { 30 }

# -- Check 1: Core WU Services --
$services = @(
    @{ Name = 'wuauserv'; Display = 'Windows Update' },
    @{ Name = 'BITS';     Display = 'Background Intelligent Transfer (BITS)' },
    @{ Name = 'CryptSvc'; Display = 'Cryptographic Services' },
    @{ Name = 'UsoSvc';   Display = 'Update Orchestrator' }
)
foreach ($svc in $services) {
    $s = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
    if ($null -eq $s) {
        $findings.Add([PSCustomObject]@{
            Check  = "$($svc.Display) ($($svc.Name))"
            Status = 'ISSUE'
            Detail = 'Service not found. This component may not be installed.'
        })
    } elseif ($s.State -eq 'Running') {
        $findings.Add([PSCustomObject]@{
            Check  = "$($svc.Display) ($($svc.Name))"
            Status = 'OK'
            Detail = "Running, start mode: $($s.StartMode). Operational."
        })
    } elseif ($s.StartMode -eq 'Disabled') {
        $findings.Add([PSCustomObject]@{
            Check  = "$($svc.Display) ($($svc.Name))"
            Status = 'ISSUE'
            Detail = "Disabled. Updates cannot function without this service. Run WU009 WUServiceReset."
        })
    } elseif ($s.StartMode -eq 'Auto') {
        $findings.Add([PSCustomObject]@{
            Check  = "$($svc.Display) ($($svc.Name))"
            Status = 'ISSUE'
            Detail = "Stopped but start mode is Auto -- should be running. Run WU009 WUServiceReset."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = "$($svc.Display) ($($svc.Name))"
            Status = 'OK'
            Detail = "Stopped, start mode: $($s.StartMode). This is expected -- service starts on demand when updates are needed."
        })
    }
}

# -- Check 2: System Drive Free Space --
$sysDrive = $env:SystemDrive
$disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"
if ($null -ne $disk) {
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($disk.Size / 1GB, 0)
    if ($freeGB -lt 5) {
        $findings.Add([PSCustomObject]@{
            Check  = "Disk Space ($sysDrive)"
            Status = 'ISSUE'
            Detail = "CRITICAL: Only $freeGB GB free of $totalGB GB. Even monthly cumulative updates may fail below 5 GB."
        })
    } elseif ($freeGB -lt 20) {
        $findings.Add([PSCustomObject]@{
            Check  = "Disk Space ($sysDrive)"
            Status = 'WARN'
            Detail = "$freeGB GB free of $totalGB GB. Feature updates need at least 20 GB. Monthly patches should still work."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = "Disk Space ($sysDrive)"
            Status = 'OK'
            Detail = "$freeGB GB free of $totalGB GB. Sufficient for all update types."
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Disk Space'
        Status = 'ERROR'
        Detail = "Could not query system drive $sysDrive."
    })
}

# -- Check 3: Pending Reboot --
$rebootReasons = [System.Collections.Generic.List[string]]::new()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $rebootReasons.Add('Windows Update has staged updates waiting for reboot')
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $rebootReasons.Add('Component servicing (CBS) requires reboot to finalize')
}
$pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($null -ne $pfro) {
    $nonEmpty = @($pfro | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -gt 0) {
        $rebootReasons.Add('Session Manager has pending file rename operations')
    }
}
if ($rebootReasons.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Pending Reboot'
        Status = 'ISSUE'
        Detail = "Reboot required. New updates will not install until this machine restarts. $($rebootReasons -join '; ')."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Pending Reboot'
        Status = 'OK'
        Detail = 'No reboot pending. Machine is clear to accept new updates.'
    })
}

# -- HRESULT lookup table --
$hresultMap = @{}
$hresultMap['0x80070643'] = 'WinRE partition too small or MSI installer failure. May need manual partition resize.'
$hresultMap['0x800F081F'] = 'Component store missing required files. Run WU005 WUComponentHealth.'
$hresultMap['0x80073712'] = 'Component store corruption detected. Run WU005 WUComponentHealth.'
$hresultMap['0x80244022'] = 'Update server returned HTTP 503 (unavailable). Run WU003 WUNetworkCheck.'
$hresultMap['0x8024401C'] = 'Connection to update server timed out. Run WU003 WUNetworkCheck.'
$hresultMap['0x8024002E'] = 'Windows Update is administratively disabled. Run WU002 WUPolicyAudit.'
$hresultMap['0x80070005'] = 'Access denied. Likely third-party AV or Tamper Protection blocking updates.'
$hresultMap['0x80240022'] = 'All updates in batch failed. Examine individual error codes.'
$hresultMap['0x80242014'] = 'Post-reboot finalization still pending. Reboot the machine.'
$hresultMap['0x800F0922'] = 'Safe OS phase failed. Usually WinRE partition or disk space issue.'
$hresultMap['0x80070002'] = 'Required file not found. Component store may need repair. Run WU005.'
$hresultMap['0x80080005'] = 'Server execution failed. Background service may have crashed. Run WU009.'
$hresultMap['0x8007000E'] = 'Out of memory. Close applications and retry.'
$hresultMap['0x80072EE7'] = 'Server name could not be resolved. DNS or network issue. Run WU003.'
$hresultMap['0x80072F8F'] = 'SSL/TLS certificate validation failed. Run WU004 WUTlsCertCheck.'
$hresultMap['0x80096004'] = 'Certificate trust validation failure. Run WU004 WUTlsCertCheck.'
$hresultMap['0x80244019'] = 'WSUS server rejected request (HTTP 503). WSUS may be overloaded.'
$hresultMap['0x800705B4'] = 'Operation timed out. Service may be hung. Run WU009 WUServiceReset.'
$hresultMap['0x80240017'] = 'Update not applicable to this system. Usually not a problem.'
$hresultMap['0x80070BC9'] = 'Reboot required before this update can install. Reboot and retry.'
$hresultMap['0x80240020'] = 'Windows Update agent is busy. Retry after a few minutes.'
$hresultMap['0x8024402F'] = 'Proxy or authentication issue. Check proxy config. Run WU003 WUNetworkCheck.'
$hresultMap['0xC1900101'] = 'Feature update rollback (driver or compatibility issue). Check SetupDiag output.'

# -- Check 4 & 6: WU History --
$lastSuccessDate = $null
$failureList = [System.Collections.Generic.List[PSCustomObject]]::new()
$failCount = 0
$successCount = 0
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        $max = if ($total -lt 200) { $total } else { 200 }
        $history = $searcher.QueryHistory(0, $max)
        $cutoff = (Get-Date).AddDays(-$daysBack)
        for ($i = 0; $i -lt $history.Count; $i++) {
            $e = $history.Item($i)
            if ($e.ResultCode -eq 2) {
                if ($null -eq $lastSuccessDate -or $e.Date -gt $lastSuccessDate) {
                    $lastSuccessDate = $e.Date
                }
                if ($e.Date -ge $cutoff) { $successCount++ }
            } elseif ($e.ResultCode -eq 3 -and $e.Date -ge $cutoff) {
                # ResultCode 3 = Succeeded with errors (partial success, not a failure)
                $successCount++
                if ($null -eq $lastSuccessDate -or $e.Date -gt $lastSuccessDate) {
                    $lastSuccessDate = $e.Date
                }
            } elseif ($e.ResultCode -ge 4 -and $e.Date -ge $cutoff) {
                $failCount++
                if ($failureList.Count -lt 5) {
                    $hr = '0x{0:X8}' -f ([uint32]$e.HResult)
                    $meaning = $hresultMap[$hr]
                    if ([string]::IsNullOrWhiteSpace($meaning)) {
                        $meaning = "Unknown error. Search $hr on learn.microsoft.com"
                    }
                    $titleRaw = $e.Title
                    if ([string]::IsNullOrEmpty($titleRaw)) { $titleRaw = '<no title>' }
                    $title = if ($titleRaw.Length -gt 80) { $titleRaw.Substring(0, 77) + '...' } else { $titleRaw }
                    $failureList.Add([PSCustomObject]@{
                        Date    = $e.Date.ToString('yyyy-MM-dd')
                        HR      = $hr
                        Title   = $title
                        Meaning = $meaning
                    })
                }
            }
        }
    }
    if ($failCount -gt 0) {
        $findings.Add([PSCustomObject]@{
            Check  = "Update Failures (last $daysBack days)"
            Status = 'ISSUE'
            Detail = "$failCount failed, $successCount succeeded. Top failures:"
        })
        foreach ($fl in $failureList) {
            $findings.Add([PSCustomObject]@{
                Check  = "  $($fl.HR) on $($fl.Date)"
                Status = 'INFO'
                Detail = "$($fl.Title) -- $($fl.Meaning)"
            })
        }
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = "Update History (last $daysBack days)"
            Status = 'OK'
            Detail = "No failed updates. $successCount update(s) succeeded."
        })
    }
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Update History'
        Status = 'ERROR'
        Detail = "Could not query WU history: $($_.Exception.Message)"
    })
}

# -- Check 5: SoftwareDistribution Folder Size --
$sdPath = Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution'
if (Test-Path -Path $sdPath) {
    try {
        $sdSize = (Get-ChildItem -Path $sdPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sdSize) { $sdSize = 0 }
        if ($sdSize -ge 1073741824) {
            $sdGB = [math]::Round($sdSize / 1GB, 2)
            $findings.Add([PSCustomObject]@{
                Check  = 'SoftwareDistribution Cache'
                Status = 'ISSUE'
                Detail = "$sdGB GB. Bloated cache suggests stuck or failed downloads. Run WU009 WUServiceReset to clear."
            })
        } else {
            $sdMB = [math]::Round($sdSize / 1MB, 0)
            $findings.Add([PSCustomObject]@{
                Check  = 'SoftwareDistribution Cache'
                Status = 'OK'
                Detail = "$sdMB MB. Cache size is normal."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'SoftwareDistribution Cache'
            Status = 'ERROR'
            Detail = "Could not measure folder: $($_.Exception.Message)"
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'SoftwareDistribution Cache'
        Status = 'ISSUE'
        Detail = "Folder not found at $sdPath. This should always exist. Run WU009 WUServiceReset."
    })
}

# -- Check 6: Last Successful Update --
if ($null -ne $lastSuccessDate) {
    $daysSince = [math]::Max(0, [math]::Floor(((Get-Date) - $lastSuccessDate).TotalDays))
    if ($daysSince -gt 60) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Last Successful Update'
            Status = 'ISSUE'
            Detail = "$daysSince days ago ($($lastSuccessDate.ToString('yyyy-MM-dd'))). Machine is significantly behind on patches."
        })
    } elseif ($daysSince -gt 30) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Last Successful Update'
            Status = 'WARN'
            Detail = "$daysSince days ago ($($lastSuccessDate.ToString('yyyy-MM-dd'))). Updates appear to have stalled."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Last Successful Update'
            Status = 'OK'
            Detail = "$daysSince days ago ($($lastSuccessDate.ToString('yyyy-MM-dd'))). Update cadence looks healthy."
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Last Successful Update'
        Status = 'ISSUE'
        Detail = 'No successful updates found in available history. Investigate immediately.'
    })
}

# -- Output --
Write-Output ''
Write-Output '=== Windows Update Quick Health ==='
Write-Output ''
$issueCount = @($findings | Where-Object { $_.Status -eq 'ISSUE' -or $_.Status -eq 'ERROR' }).Count
$warnCount = @($findings | Where-Object { $_.Status -eq 'WARN' }).Count
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
    Write-Output 'RESULT: No issues detected. Windows Update appears healthy.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] and [!] above."
}
Write-Output ''
Write-Output 'NEXT:   If services are stopped      -> run WU009 WUServiceReset'
Write-Output '        If policy issues suspected   -> run WU002 WUPolicyAudit'
Write-Output '        If network-related failures  -> run WU003 WUNetworkCheck'
Write-Output '        For deeper investigation     -> run scripts WU002-WU008 in order'
Write-Output ''
