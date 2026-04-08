# WU005_WUComponentHealth.ps1
# Scriptlet: WU005 - Component Store & System Integrity
# Context: System | Version: 1.3

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Component Store & System Integrity ==='
Write-Output ''
Write-Output '[i]   This scriptlet runs DISM operations and may take 30-60 seconds.'
Write-Output ''
$issueCount = 0
$warnCount  = 0
Write-Output '--- DISM Health Check ---'
$dismHealthDone = $false
try {
    $dismResult = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
    $healthState = "$($dismResult.ImageHealthState)"
    if ($healthState -eq 'Healthy') {
        Write-Output '[OK]  Component Store Health (Registry Flags)'
        Write-Output '       No component store corruption detected. Store is healthy.'
        Write-Output '       Note: This checks registry state only. CBS.log analysis (below)'
        Write-Output '       validates physical file integrity that may not be reflected here.'
    } elseif ($healthState -eq 'Repairable') {
        Write-Output '[!!]  Component Store Health (Registry Flags)'
        Write-Output '       The component store is REPAIRABLE. Corruption flags are set in the CBS registry.'
        Write-Output '       Run WU010 WUServicingRepair to execute DISM /RestoreHealth + SFC.'
        $issueCount++
    } elseif ($healthState -eq 'NonRepairable') {
        Write-Output '[!!]  Component Store Health (Registry Flags)'
        Write-Output '       Component store is NON-REPAIRABLE via standard DISM.'
        Write-Output '       An in-place repair upgrade may be required. Escalate to senior engineer.'
        $issueCount++
    } else {
        Write-Output '[!]   Component Store Health (Registry Flags)'
        Write-Output "       Unexpected health state: $healthState"
        Write-Output '       Run dism.exe /Online /Cleanup-Image /CheckHealth manually for details.'
        $warnCount++
    }
    $dismHealthDone = $true
} catch { }
if (-not $dismHealthDone) {
    try {
        $dismExeOutput = & dism.exe /Online /Cleanup-Image /CheckHealth /English 2>&1
        $dismExitCode = $LASTEXITCODE
        $dismText = ($dismExeOutput | Out-String).Trim()
        if ($dismExitCode -eq 0 -and $dismText -match 'No component store corruption detected') {
            Write-Output '[OK]  Component Store Health (Registry Flags)'
            Write-Output '       No component store corruption detected. Store is healthy.'
            Write-Output '       Note: This checks registry state only. CBS.log analysis (below)'
            Write-Output '       validates physical file integrity that may not be reflected here.'
        } elseif ($dismText -match 'component store is repairable') {
            Write-Output '[!!]  Component Store Health (Registry Flags)'
            Write-Output '       The component store is REPAIRABLE. Corruption flags are set.'
            Write-Output '       Run WU010 WUServicingRepair to execute DISM /RestoreHealth + SFC.'
            $issueCount++
        } else {
            Write-Output '[!]   Component Store Health (Registry Flags)'
            $showText = $dismText
            if ($showText.Length -gt 200) { $showText = $showText.Substring(0, 197) + '...' }
            Write-Output "       Exit code: $dismExitCode. Output: $showText"
            $warnCount++
        }
    } catch {
        Write-Output '[!]   Component Store Health'
        Write-Output "       Cannot run DISM health check: $($_.Exception.Message)"
        $warnCount++
    }
}
Write-Output ''
Write-Output '--- CBS.log Analysis ---'
$cbsLogPath = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\CBS\CBS.log'
$cbsTempPath = $null
$cbsLines = $null

# Read CBS.log once for both CBS analysis and SFC result parsing.
# Copy to temp first to bypass TrustedInstaller file locks during servicing.
if (Test-Path -Path $cbsLogPath) {
    try {
        $cbsTempPath = Join-Path -Path $env:TEMP -ChildPath "Indago_CBS_$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
        Copy-Item -Path $cbsLogPath -Destination $cbsTempPath -Force -ErrorAction Stop
        $cbsLines = @(Get-Content -Path $cbsTempPath -Tail 5000 -ErrorAction Stop)
    } catch {
        # Copy failed (rare exclusive lock); fall back to direct read
        try {
            $cbsLines = @(Get-Content -Path $cbsLogPath -Tail 5000 -ErrorAction Stop)
        } catch { }
    }
}

if ($null -ne $cbsLines -and $cbsLines.Count -gt 0) {
    try {
        $cbsTail = $cbsLines
        $criticalPatterns = @(
            @{ Code = '0x80073712'; Name = 'ERROR_SXS_COMPONENT_STORE_CORRUPT' },
            @{ Code = '0x800F081F'; Name = 'CBS_E_SOURCE_MISSING' },
            @{ Code = '0x800F0831'; Name = 'CBS_E_STORE_CORRUPTION' },
            @{ Code = '0x800736CC'; Name = 'ERROR_SXS_FILE_HASH_MISMATCH' }
        )
        $warningPatterns = @(
            @{ Code = '0x800F0823'; Name = 'CBS_E_NEW_SERVICING_STACK_REQUIRED' },
            @{ Code = '0x800F0982'; Name = 'PSFX_E_MATCHING_BINARY_MISSING' },
            @{ Code = '0x8007000D'; Name = 'ERROR_INVALID_DATA' },
            @{ Code = '0x80070020'; Name = 'ERROR_SHARING_VIOLATION' }
        )
        $criticalHits = [System.Collections.Generic.List[string]]::new()
        $warningHits  = [System.Collections.Generic.List[string]]::new()
        $textHits     = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $cbsTail) {
            $lineStr = "$line"
            $matched = $false
            foreach ($cp in $criticalPatterns) {
                if ($lineStr -match $cp.Code) {
                    $trimmed = $lineStr.Trim()
                    if ($trimmed.Length -gt 120) { $trimmed = $trimmed.Substring(0, 117) + '...' }
                    $null = $criticalHits.Add("$($cp.Code) ($($cp.Name)): $trimmed")
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                foreach ($wp in $warningPatterns) {
                    if ($lineStr -match $wp.Code) {
                        $trimmed = $lineStr.Trim()
                        if ($trimmed.Length -gt 120) { $trimmed = $trimmed.Substring(0, 117) + '...' }
                        $null = $warningHits.Add("$($wp.Code) ($($wp.Name)): $trimmed")
                        $matched = $true
                        break
                    }
                }
            }
            if (-not $matched) {
                if ($lineStr -match '(?<![a-zA-Z])[Ss]tore corruption') {
                    $trimmed = $lineStr.Trim()
                    if ($trimmed.Length -gt 120) { $trimmed = $trimmed.Substring(0, 117) + '...' }
                    $null = $textHits.Add("Store corruption: $trimmed")
                }
                elseif ($lineStr -match 'Exec:\s*Error') {
                    $trimmed = $lineStr.Trim()
                    if ($trimmed.Length -gt 120) { $trimmed = $trimmed.Substring(0, 117) + '...' }
                    $null = $textHits.Add("Exec Error: $trimmed")
                }
            }
        }
        $totalCritical = $criticalHits.Count + $textHits.Count
        $totalWarning  = $warningHits.Count
        if ($totalCritical -gt 0) {
            Write-Output "[!!]  CBS.log (Last 5000 Lines)"
            Write-Output "       $totalCritical critical corruption pattern(s) found."
            $shown = 0
            foreach ($hit in $criticalHits) {
                if ($shown -ge 3) { break }
                Write-Output "       $hit"
                $shown++
            }
            foreach ($hit in $textHits) {
                if ($shown -ge 3) { break }
                Write-Output "       $hit"
                $shown++
            }
            if (($criticalHits.Count + $textHits.Count) -gt 3) {
                $remaining = ($criticalHits.Count + $textHits.Count) - 3
                Write-Output "       ... and $remaining more. Run WU010 WUServicingRepair."
            }
            $issueCount++
        } elseif ($totalWarning -gt 0) {
            Write-Output "[!]   CBS.log (Last 5000 Lines)"
            Write-Output "       $totalWarning warning pattern(s) found (sharing violations, SSU issues)."
            $shown = 0
            foreach ($hit in $warningHits) {
                if ($shown -ge 3) { break }
                Write-Output "       $hit"
                $shown++
            }
            if ($warningHits.Count -gt 3) {
                $remaining = $warningHits.Count - 3
                Write-Output "       ... and $remaining more."
            }
            Write-Output '       These may indicate transient issues. If updates are failing, run WU010.'
            $warnCount++
        } else {
            Write-Output '[OK]  CBS.log (Last 5000 Lines)'
            Write-Output '       No corruption patterns found in recent CBS activity.'
        }
    } catch {
        Write-Output '[i]   CBS.log'
        Write-Output "       Cannot analyze CBS.log: $($_.Exception.Message)"
    }
} else {
    if (-not (Test-Path -Path $cbsLogPath)) {
        Write-Output '[i]   CBS.log'
        Write-Output "       CBS.log not found at $cbsLogPath."
        Write-Output '       This is unusual. The CBS log should always exist on Windows 10/11.'
    } else {
        Write-Output '[i]   CBS.log'
        Write-Output '       CBS.log exists but could not be read (file may be locked by TrustedInstaller).'
        Write-Output '       Re-run this check when no updates are being installed or staged.'
    }
}
Write-Output ''
Write-Output '--- Last SFC Result ---'
$sfcResultFound = $false
$sfcStatus = ''
$sfcDetail = ''
$sfcTimestamp = ''
if ($null -ne $cbsLines -and $cbsLines.Count -gt 0) {
    try {
        $sfcLines = $cbsLines
        for ($i = $sfcLines.Count - 1; $i -ge 0; $i--) {
            $lineStr = "$($sfcLines[$i])"
            if ($lineStr -match '\[SR\]') {
                if ($lineStr -match 'found corrupt files but was unable to fix') {
                    $sfcStatus = 'ISSUE'
                    $sfcDetail = 'SFC found UNFIXABLE corruption. Run WU010 WUServicingRepair.'
                    $sfcResultFound = $true
                }
                elseif ($lineStr -match 'could not perform the requested operation') {
                    $sfcStatus = 'WARN'
                    $sfcDetail = 'SFC could not run. Possible pending reboot or TrustedInstaller issue.'
                    $sfcResultFound = $true
                }
                elseif ($lineStr -match 'found corrupt files and successfully repaired') {
                    $sfcStatus = 'INFO'
                    $sfcDetail = 'SFC found and repaired corrupt files. Store had corruption but self-healed.'
                    $sfcResultFound = $true
                }
                elseif ($lineStr -match 'did not find any integrity violations') {
                    $sfcStatus = 'OK'
                    $sfcDetail = 'SFC found no integrity violations. All protected files match their manifests.'
                    $sfcResultFound = $true
                }
                if ($sfcResultFound) {
                    if ($lineStr -match '(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})') {
                        $sfcTimestamp = $Matches[1]
                    }
                    break
                }
            }
        }
    } catch { }
}
if ($sfcResultFound) {
    $tsStr = ''
    if ($sfcTimestamp.Length -gt 0) { $tsStr = " (last run: $sfcTimestamp)" }
    if ($sfcStatus -eq 'OK') {
        Write-Output '[OK]  System File Checker'
        Write-Output "       $sfcDetail$tsStr"
    } elseif ($sfcStatus -eq 'INFO') {
        Write-Output '[i]   System File Checker'
        Write-Output "       $sfcDetail$tsStr"
    } elseif ($sfcStatus -eq 'ISSUE') {
        Write-Output '[!!]  System File Checker'
        Write-Output "       $sfcDetail$tsStr"
        $issueCount++
    } else {
        Write-Output '[!]   System File Checker'
        Write-Output "       $sfcDetail$tsStr"
        $warnCount++
    }
} else {
    Write-Output '[i]   System File Checker'
    Write-Output '       No SFC result found in CBS.log (last 5000 lines).'
    Write-Output '       SFC has not been run recently, or the log has rolled over.'
    Write-Output '       This is informational -- if DISM reports healthy and no CBS'
    Write-Output '       errors found, the component store is likely intact.'
}
Write-Output ''
Write-Output '--- Component Store Size ---'
try {
    $analyzeOutput = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore /English 2>&1
    $analyzeExitCode = $LASTEXITCODE
    $analyzeText = ($analyzeOutput | Out-String)
    if ($analyzeExitCode -eq 0) {
        $actualSize = ''
        $reportedSize = ''
        $sharedSize = ''
        $backupsSize = ''
        $reclaimable = ''
        $cleanupRec = ''
        $lastCleanup = ''
        if ($analyzeText -match 'Windows Explorer Reported Size of Component Store\s*:\s*(.+)') { $reportedSize = $Matches[1].Trim() }
        if ($analyzeText -match 'Actual Size of Component Store\s*:\s*(.+)') { $actualSize = $Matches[1].Trim() }
        if ($analyzeText -match 'Shared with Windows\s*:\s*(.+)') { $sharedSize = $Matches[1].Trim() }
        if ($analyzeText -match 'Backups and Disabled Features\s*:\s*(.+)') { $backupsSize = $Matches[1].Trim() }
        if ($analyzeText -match 'Number of Reclaimable Packages\s*:\s*(\d+)') { $reclaimable = $Matches[1].Trim() }
        if ($analyzeText -match 'Component Store Cleanup Recommended\s*:\s*(\w+)') { $cleanupRec = $Matches[1].Trim() }
        if ($analyzeText -match 'Date of Last Cleanup\s*:\s*(.+)') { $lastCleanup = $Matches[1].Trim() }
        $cleanupNeeded = ($cleanupRec -eq 'Yes')
        if ($actualSize.Length -eq 0 -and $reportedSize.Length -eq 0) {
            # DISM exited 0 but output could not be parsed (unexpected format or /English not honored)
            Write-Output '[!]   Component Store Analysis'
            Write-Output '       DISM exited successfully but output could not be parsed.'
            Write-Output '       Run dism.exe /Online /Cleanup-Image /AnalyzeComponentStore manually.'
            $warnCount++
        } elseif ($cleanupNeeded) { Write-Output '[!]   Component Store Analysis' } else { Write-Output '[OK]  Component Store Analysis' }
        if ($actualSize.Length -gt 0 -and $reportedSize.Length -gt 0) { Write-Output "       Actual size: $actualSize (reported: $reportedSize due to hard links)." }
        elseif ($actualSize.Length -gt 0) { Write-Output "       Actual size: $actualSize." }
        if ($sharedSize.Length -gt 0 -and $backupsSize.Length -gt 0) { Write-Output "       Shared with Windows: $sharedSize. Backups/disabled: $backupsSize." }
        if ($reclaimable.Length -gt 0) { Write-Output "       Reclaimable packages: $reclaimable (superseded updates eligible for removal)." }
        if ($lastCleanup.Length -gt 0) { Write-Output "       Last cleanup: $lastCleanup." }
        if ($cleanupNeeded) {
            Write-Output '       Component Store Cleanup Recommended: Yes.'
            Write-Output '       What it does: removes superseded update components and old versions'
            Write-Output '       of replaced system files. Frees disk space in C:\Windows\WinSxS.'
            Write-Output '       Safety: read-only diagnostic + cleanup. No reboot required.'
            Write-Output '       Trade-off: previously installed updates can no longer be uninstalled.'
            Write-Output '       Run: DISM /Online /Cleanup-Image /StartComponentCleanup'
            $warnCount++
        } else { Write-Output '       Component Store Cleanup Recommended: No.' }
    } else {
        Write-Output '[!]   Component Store Analysis'
        $showText = $analyzeText.Trim()
        if ($showText.Length -gt 200) { $showText = $showText.Substring(0, 197) + '...' }
        Write-Output "       DISM /AnalyzeComponentStore failed (exit code: $analyzeExitCode)."
        Write-Output "       Output: $showText"
        $warnCount++
    }
} catch {
    Write-Output '[!]   Component Store Analysis'
    Write-Output "       Cannot run DISM /AnalyzeComponentStore: $($_.Exception.Message)"
    $warnCount++
}
Write-Output ''
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) { Write-Output 'RESULT: No issues detected. Component store and servicing stack appear healthy.' }
elseif ($issueCount -gt 0 -and $warnCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above." }
elseif ($issueCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above." }
else { Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above." }
Write-Output ''
Write-Output 'NEXT:   If corruption detected   -> run WU010 WUServicingRepair (DISM /RestoreHealth + SFC)'
Write-Output '        If component store large -> run: DISM /Online /Cleanup-Image /StartComponentCleanup'
Write-Output '        If SFC found unfixable   -> run WU010 WUServicingRepair for full repair chain'
Write-Output '        If clean                 -> issue is elsewhere; run WU006 WUEventTimeline'
Write-Output ''

# Clean up temp CBS.log copy
if ($null -ne $cbsTempPath -and (Test-Path -Path $cbsTempPath)) {
    Remove-Item -Path $cbsTempPath -Force -ErrorAction SilentlyContinue
}
