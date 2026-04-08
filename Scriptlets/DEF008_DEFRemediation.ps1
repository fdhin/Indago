# DEF008_DEFRemediation.ps1
# Scriptlet: DEF008 - Defender Remediation & Recovery
# Context: System | Version: 1.1

$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== Defender Remediation & Recovery ==='

# ============================================================
# Step 0 -- Parameter Parsing & Mode Selection
# ============================================================
$mode = if ($Param1) { $Param1.Trim() } else { 'Auto' }
$validModes = @('Auto', 'UpdateOnly', 'CleanupOnly', 'Full')
if ($validModes -notcontains $mode) {
    Write-Output ''
    Write-Output "[ERR] Invalid mode '$mode'. Valid modes: Auto, UpdateOnly, CleanupOnly, Full."
    Write-Output '       Defaulting to Auto.'
    $mode = 'Auto'
}

# Define which steps run in each mode
$doUpdate      = ($mode -eq 'Auto' -or $mode -eq 'UpdateOnly' -or $mode -eq 'Full')
$doCleanGhosts = ($mode -eq 'Auto' -or $mode -eq 'CleanupOnly' -or $mode -eq 'Full')
$doClearCache  = ($mode -eq 'Full')
$doEnableRtp   = ($mode -eq 'Auto' -or $mode -eq 'Full')
$doRemoveKeys  = ($mode -eq 'Auto' -or $mode -eq 'CleanupOnly' -or $mode -eq 'Full')
$doResetPrefs  = ($mode -eq 'Full')
$doRestart     = ($mode -eq 'Auto' -or $mode -eq 'Full')
$doQuickScan   = ($mode -eq 'Full')
$doIntuneSync  = ($mode -eq 'Auto' -or $mode -eq 'Full')

Write-Output ''
Write-Output "Mode: $mode"

# ============================================================
# Step 1 -- Export Pre-Remediation State (all modes)
# ============================================================
Write-Output ''
Write-Output '--- Step 1: Capturing Pre-Remediation State ---'

$logDir = 'C:\ProgramData\Indago\Logs'
if (-not (Test-Path $logDir)) {
    $null = New-Item -Path $logDir -ItemType Directory -Force
}

$preState = @{
    Timestamp = $ts
    Mode      = $mode
    Services  = @()
}

# Capture service states
foreach ($svcName in @('WinDefend', 'WdNisSvc', 'Sense')) {
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

# Capture MpComputerStatus
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $preState.RealTimeProtectionEnabled = $mpStatus.RealTimeProtectionEnabled
    $preState.AntivirusEnabled          = $mpStatus.AntivirusEnabled
    $preState.AMServiceEnabled          = $mpStatus.AMServiceEnabled
    $preState.AntispywareEnabled        = $mpStatus.AntispywareEnabled
    $preState.AntivirusSignatureAge     = $mpStatus.AntivirusSignatureAge
    $preState.NISEnabled                = $mpStatus.NISEnabled
    $preState.DefenderMode              = if ($mpStatus.AMRunningMode) { $mpStatus.AMRunningMode.ToString() } else { 'Unknown' }
} catch {
    $preState.MpComputerStatusError = $_.Exception.Message
}

# Capture MpPreference (selected fields)
try {
    $mpPref = Get-MpPreference -ErrorAction Stop
    $preState.DisableRealtimeMonitoring = $mpPref.DisableRealtimeMonitoring
    $preState.ExclusionPathCount        = if ($mpPref.ExclusionPath) { @($mpPref.ExclusionPath).Count } else { 0 }
    $preState.ExclusionExtensionCount   = if ($mpPref.ExclusionExtension) { @($mpPref.ExclusionExtension).Count } else { 0 }
    $preState.ExclusionProcessCount     = if ($mpPref.ExclusionProcess) { @($mpPref.ExclusionProcess).Count } else { 0 }
} catch {
    $preState.MpPreferenceError = $_.Exception.Message
}

# Save pre-state to JSON
$preStatePath = Join-Path -Path $logDir -ChildPath "DEF008_PreState_$ts.json"
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
        Detail = "Could not save pre-state: $($_.Exception.Message). Continuing."
    })
}

# ============================================================
# Step 2 -- Force Signature Update
# ============================================================
if ($doUpdate) {
    Write-Output ''
    Write-Output '--- Step 2: Forcing Signature Update ---'

    $updateSources = @(
        @{ Name = 'MicrosoftUpdateServer'; Desc = 'Microsoft Update (WU/CDN)' },
        @{ Name = 'MMPC';                  Desc = 'Microsoft Malware Protection Center (direct cloud)' },
        @{ Name = 'InternalDefinitionUpdateServer'; Desc = 'WSUS / internal server' },
        @{ Name = 'FileShares';            Desc = 'Network file share (if configured)' }
    )

    $updateSuccess = $false
    foreach ($src in $updateSources) {
        try {
            Update-MpSignature -UpdateSource $src.Name -ErrorAction Stop
            $updateSuccess = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'Signature Update'
                Status = 'OK'
                Detail = "Definitions updated successfully via $($src.Desc)."
            })
            break
        } catch {
            # This source failed, try next
        }
    }

    if (-not $updateSuccess) {
        # All sources failed -- try with no source specified (let Defender choose)
        try {
            Update-MpSignature -ErrorAction Stop
            $updateSuccess = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'Signature Update'
                Status = 'OK'
                Detail = 'Definitions updated successfully via default automatic source.'
            })
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = 'Signature Update'
                Status = 'ISSUE'
                Detail = "All signature update sources failed. Last error: $($_.Exception.Message). Check network connectivity and proxy settings. Run DEF002 DEFDefinitionHealth for diagnostics."
            })
        }
    }

    # Check signature age after update attempt
    if ($updateSuccess) {
        try {
            $postSigAge = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureAge
            if ($postSigAge -le 1) {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Signature Age (post-update)'
                    Status = 'OK'
                    Detail = "Signatures are $postSigAge day(s) old. Current."
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Signature Age (post-update)'
                    Status = 'WARN'
                    Detail = "Signatures are still $postSigAge day(s) old after update. Update may not have fully applied."
                })
            }
        } catch { }
    }
}

# ============================================================
# Step 3 -- Remove Ghost Third-Party AV Registrations
# ============================================================
if ($doCleanGhosts) {
    Write-Output ''
    Write-Output '--- Step 3: Cleaning Ghost AV Registrations ---'

    try {
        $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
        $ghostCount = 0
        $liveCount = 0
        $failCount = 0

        foreach ($av in $avProducts) {
            if ($av.displayName -eq 'Windows Defender') { continue }

            $exePath = $av.pathToSignedProductExe
            $exeExists = $false
            if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                # SecurityCenter2 paths may contain literal quotes around
                # the path string. Strip them to avoid false ghost detection.
                $cleanPath = $exePath.Trim('"').Trim("'")
                $exeExists = Test-Path -Path $cleanPath -ErrorAction SilentlyContinue
            }

            if ($exeExists) {
                # Live product -- do not touch
                $liveCount++
                $findings.Add([PSCustomObject]@{
                    Check  = "AV: $($av.displayName)"
                    Status = 'INFO'
                    Detail = "Live third-party AV detected. Executable exists at $exePath. Uninstall this product manually if it is no longer needed."
                })
            } else {
                # Ghost registration -- executable missing, safe to remove
                $ghostCount++
                try {
                    Remove-CimInstance -InputObject $av -ErrorAction Stop
                    $findings.Add([PSCustomObject]@{
                        Check  = "Ghost AV: $($av.displayName)"
                        Status = 'OK'
                        Detail = "Removed orphaned SecurityCenter2 registration. Product executable not found at $exePath. Defender should exit passive mode."
                    })
                } catch {
                    $failCount++
                    $findings.Add([PSCustomObject]@{
                        Check  = "Ghost AV: $($av.displayName)"
                        Status = 'WARN'
                        Detail = "Failed to remove ghost registration: $($_.Exception.Message). A reboot may help, or manually delete via WMI."
                    })
                }
            }
        }

        if ($ghostCount -eq 0 -and $liveCount -eq 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Ghost AV Cleanup'
                Status = 'OK'
                Detail = 'No third-party AV registrations found. Defender is the sole registered provider.'
            })
        } elseif ($ghostCount -eq 0 -and $liveCount -gt 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Ghost AV Cleanup'
                Status = 'INFO'
                Detail = "$liveCount active third-party AV product(s) found. No ghosts to remove. If Defender should be primary, uninstall the third-party AV first."
            })
        }
    } catch {
        # SecurityCenter2 not available (likely a Server OS)
        $findings.Add([PSCustomObject]@{
            Check  = 'Ghost AV Cleanup'
            Status = 'INFO'
            Detail = "SecurityCenter2 namespace not available (common on Server OS). Ghost registration check skipped."
        })
    }
}

# ============================================================
# Step 4 -- Clear Defender Dynamic Signatures Cache (Full only)
# ============================================================
if ($doClearCache) {
    Write-Output ''
    Write-Output '--- Step 4: Clearing Dynamic Signatures Cache ---'

    # Locate MpCmdRun.exe -- platform directory first, then inbox
    $mpCmdRunPath = $null
    $platformDir = 'C:\ProgramData\Microsoft\Windows Defender\Platform'
    if (Test-Path $platformDir) {
        $latestPlatform = Get-ChildItem -Path $platformDir -Directory -ErrorAction SilentlyContinue |
                          Sort-Object Name -Descending |
                          Select-Object -First 1
        if ($null -ne $latestPlatform) {
            $candidate = Join-Path -Path $latestPlatform.FullName -ChildPath 'MpCmdRun.exe'
            if (Test-Path $candidate) {
                $mpCmdRunPath = $candidate
            }
        }
    }
    if ($null -eq $mpCmdRunPath) {
        $candidate = Join-Path -Path $env:ProgramFiles -ChildPath 'Windows Defender\MpCmdRun.exe'
        if (Test-Path $candidate) {
            $mpCmdRunPath = $candidate
        }
    }

    if ($null -ne $mpCmdRunPath) {
        try {
            $cacheResult = & $mpCmdRunPath -removedefinitions -dynamicsignatures 2>&1
            $cacheText = ($cacheResult | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Cache Clear (Dynamic Signatures)'
                    Status = 'OK'
                    Detail = "Dynamic signatures cache cleared via MpCmdRun.exe. Output: $cacheText"
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Cache Clear (Dynamic Signatures)'
                    Status = 'WARN'
                    Detail = "MpCmdRun.exe returned exit code $LASTEXITCODE. Output: $cacheText"
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = 'Cache Clear (Dynamic Signatures)'
                Status = 'WARN'
                Detail = "Error running MpCmdRun.exe: $($_.Exception.Message)"
            })
        }
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Cache Clear (Dynamic Signatures)'
            Status = 'WARN'
            Detail = 'MpCmdRun.exe not found in Platform directory or inbox path. Cache clear skipped.'
        })
    }
}

# ============================================================
# Step 5 -- Re-enable Real-Time Protection
# ============================================================
if ($doEnableRtp) {
    Write-Output ''
    Write-Output '--- Step 5: Re-enabling Real-Time Protection ---'

    $rtpAlreadyOn = $false
    try {
        $currentRtp = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled
        if ($currentRtp -eq $true) {
            $rtpAlreadyOn = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'Real-Time Protection'
                Status = 'OK'
                Detail = 'RTP is already enabled. No action needed.'
            })
        }
    } catch { }

    if (-not $rtpAlreadyOn) {
        # Check Tamper Protection state
        $tamperVal = $null
        try {
            $tamperVal = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -ErrorAction Stop).TamperProtection
        } catch { }

        if ($tamperVal -eq 5) {
            # Tamper Protection is ON. TP blocks DISABLING security features
            # but allows ENABLING them. RTP enablement should succeed.
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Start-Sleep -Seconds 2
                $postRtp = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled
                if ($postRtp -eq $true) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Real-Time Protection'
                        Status = 'OK'
                        Detail = 'RTP re-enabled successfully (Tamper Protection active -- enablement is allowed by TP).'
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Real-Time Protection'
                        Status = 'ISSUE'
                        Detail = 'RTP could not be re-enabled despite Tamper Protection allowing enablement. A cloud policy or deeper engine issue may be overriding the local setting. Check Intune/MDE compliance policy or run DEF005 DEFPolicyConflict.'
                    })
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Real-Time Protection'
                    Status = 'ISSUE'
                    Detail = "RTP re-enable failed: $($_.Exception.Message). This is unexpected -- Tamper Protection should allow enablement. Check Defender engine health or run DEF004."
                })
            }
        } else {
            # Tamper Protection is OFF or unknown -- standard attempt
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Start-Sleep -Seconds 2
                $postRtp = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled
                if ($postRtp -eq $true) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Real-Time Protection'
                        Status = 'OK'
                        Detail = 'RTP re-enabled successfully.'
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Real-Time Protection'
                        Status = 'WARN'
                        Detail = 'RTP enablement command accepted but RTP still reports disabled. A GPO or MDM policy may be overriding it. Run DEF005 DEFPolicyConflict.'
                    })
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Real-Time Protection'
                    Status = 'ISSUE'
                    Detail = "RTP re-enable failed: $($_.Exception.Message). Run DEF004 DEFRealtimeProtection for diagnostics."
                })
            }
        }
    }
}

# ============================================================
# Step 6 -- Remove Legacy Override Registry Keys
# ============================================================
if ($doRemoveKeys) {
    Write-Output ''
    Write-Output '--- Step 6: Removing Legacy Override Registry Keys ---'

    # Determine if machine is domain-joined
    $isDomainJoined = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $isDomainJoined = $cs.PartOfDomain
    } catch { }

    # Check if a legitimate third-party AV is actively running
    $hasLiveThirdPartyAV = $false
    try {
        $avCheck = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        foreach ($avItem in $avCheck) {
            if ($avItem.displayName -ne 'Windows Defender') {
                $avExe = $avItem.pathToSignedProductExe
                if (-not [string]::IsNullOrWhiteSpace($avExe)) {
                    $cleanAvExe = $avExe.Trim('"').Trim("'")
                    if (Test-Path $cleanAvExe -ErrorAction SilentlyContinue) {
                        $hasLiveThirdPartyAV = $true
                        break
                    }
                }
            }
        }
    } catch { }

    $keysToCheck = @(
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
            Name  = 'DisableAntiSpyware'
            Desc  = 'Disables Defender engine entirely'
            Guard = 'domain'
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
            Name  = 'DisableAntiVirus'
            Desc  = 'Disables Defender antivirus protection'
            Guard = 'domain'
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
            Name  = 'DisableRealtimeMonitoring'
            Desc  = 'Disables real-time monitoring via policy'
            Guard = 'domain'
        },
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
            Name  = 'ForceDefenderPassiveMode'
            Desc  = 'Forces Defender into passive mode'
            Guard = 'thirdpartyav'
        }
    )

    foreach ($key in $keysToCheck) {
        if (-not (Test-Path $key.Path)) { continue }

        $val = $null
        try {
            $val = (Get-ItemProperty -Path $key.Path -Name $key.Name -ErrorAction Stop).$($key.Name)
        } catch { continue }

        if ($null -eq $val) { continue }
        if ($val -ne 1) { continue }

        # Key exists and is set to 1 -- evaluate safety
        if ($key.Guard -eq 'domain' -and $isDomainJoined) {
            $findings.Add([PSCustomObject]@{
                Check  = "Registry: $($key.Name)"
                Status = 'WARN'
                Detail = "$($key.Desc). Value is 1 under Policies hive. Machine is domain-joined -- this is likely managed by GPO. Do NOT remove without verifying the GPO. Coordinate with the domain admin."
            })
        } elseif ($key.Guard -eq 'thirdpartyav' -and $hasLiveThirdPartyAV) {
            $findings.Add([PSCustomObject]@{
                Check  = "Registry: $($key.Name)"
                Status = 'INFO'
                Detail = "$($key.Desc). Value is 1 but a live third-party AV is installed. Defender should stay passive. Not removing."
            })
        } else {
            # Safe to remove
            try {
                Remove-ItemProperty -Path $key.Path -Name $key.Name -Force -ErrorAction Stop
                $findings.Add([PSCustomObject]@{
                    Check  = "Registry: $($key.Name)"
                    Status = 'OK'
                    Detail = "$($key.Desc). Removed stale override (was set to 1). Defender should re-activate."
                })
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = "Registry: $($key.Name)"
                    Status = 'WARN'
                    Detail = "Failed to remove $($key.Name): $($_.Exception.Message). Tamper Protection may be blocking the change."
                })
            }
        }
    }
}

# ============================================================
# Step 7 -- Reset Dangerous Exclusions (Full mode only)
# ============================================================
if ($doResetPrefs) {
    Write-Output ''
    Write-Output '--- Step 7: Auditing and Removing Dangerous Exclusions ---'

    # Check Tamper Protection status -- cloud-managed TP blocks local
    # Remove-MpPreference calls. Warn upfront if exclusion removal will fail.
    $tpBlocksExclusions = $false
    try {
        $tpVal7 = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -ErrorAction Stop).TamperProtection
        if ($tpVal7 -eq 5) {
            $tpBlocksExclusions = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'Exclusion Audit (Tamper Protection)'
                Status = 'INFO'
                Detail = 'Tamper Protection is active. If cloud-managed (Intune/MDE), local Remove-MpPreference calls may be blocked. Exclusions must be managed via the Intune portal in that case. Attempting removal anyway.'
            })
        }
    } catch { }

    # Dangerous path patterns -- security first
    $dangerousPathPatterns = @(
        'C:\',
        'D:\',
        'E:\',
        'C:\Windows',
        'C:\Windows\System32',
        'C:\Windows\SysWOW64',
        'C:\Windows\Temp',
        'C:\Users',
        'C:\ProgramData',
        'C:\Temp'
    )

    # Dangerous extension patterns
    $dangerousExtensions = @(
        '.exe', '.dll', '.sys', '.bat', '.cmd', '.ps1',
        '.vbs', '.js', '.wsf', '.scr', '.com', '.msi',
        '.hta', '.cpl', '.inf', '.reg'
    )

    # Dangerous process patterns
    $dangerousProcessPatterns = @(
        '*',
        '*.*'
    )

    $removedCount = 0

    try {
        $pref = Get-MpPreference -ErrorAction Stop

        # Audit exclusion paths
        if ($pref.ExclusionPath) {
            foreach ($exPath in @($pref.ExclusionPath)) {
                $normalized = $exPath.TrimEnd('\').TrimEnd('/')
                $isDangerous = $false
                foreach ($dp in $dangerousPathPatterns) {
                    if ($normalized -ieq $dp.TrimEnd('\')) {
                        $isDangerous = $true
                        break
                    }
                }
                # Also flag single-letter drive roots like F:\, G:\, etc.
                if ($normalized -match '^[A-Z]:$') {
                    $isDangerous = $true
                }

                if ($isDangerous) {
                    try {
                        Remove-MpPreference -ExclusionPath $exPath -ErrorAction Stop
                        $removedCount++
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Path: $exPath"
                            Status = 'OK'
                            Detail = "DANGEROUS exclusion removed. This path excluded critical system directories from scanning."
                        })
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Path: $exPath"
                            Status = 'WARN'
                            Detail = "Failed to remove dangerous exclusion: $($_.Exception.Message)"
                        })
                    }
                }
            }
        }

        # Audit exclusion extensions
        if ($pref.ExclusionExtension) {
            foreach ($exExt in @($pref.ExclusionExtension)) {
                $normalizedExt = $exExt.TrimStart('.')
                $isDangerous = $false
                foreach ($de in $dangerousExtensions) {
                    if ($normalizedExt -ieq $de.TrimStart('.')) {
                        $isDangerous = $true
                        break
                    }
                }
                # Also catch wildcard extensions
                if ($exExt -eq '*' -or $exExt -eq '*.*') {
                    $isDangerous = $true
                }

                if ($isDangerous) {
                    try {
                        Remove-MpPreference -ExclusionExtension $exExt -ErrorAction Stop
                        $removedCount++
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Extension: $exExt"
                            Status = 'OK'
                            Detail = "DANGEROUS extension exclusion removed. Excluding executable file types from scanning is a critical security risk."
                        })
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Extension: $exExt"
                            Status = 'WARN'
                            Detail = "Failed to remove dangerous extension exclusion: $($_.Exception.Message)"
                        })
                    }
                }
            }
        }

        # Audit exclusion processes
        if ($pref.ExclusionProcess) {
            foreach ($exProc in @($pref.ExclusionProcess)) {
                $isDangerous = $false
                foreach ($dpp in $dangerousProcessPatterns) {
                    if ($exProc -eq $dpp) {
                        $isDangerous = $true
                        break
                    }
                }

                if ($isDangerous) {
                    try {
                        Remove-MpPreference -ExclusionProcess $exProc -ErrorAction Stop
                        $removedCount++
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Process: $exProc"
                            Status = 'OK'
                            Detail = "DANGEROUS wildcard process exclusion removed. This effectively disabled process scanning."
                        })
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = "Exclusion Process: $exProc"
                            Status = 'WARN'
                            Detail = "Failed to remove dangerous process exclusion: $($_.Exception.Message)"
                        })
                    }
                }
            }
        }

        if ($removedCount -eq 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Exclusion Audit'
                Status = 'OK'
                Detail = 'No dangerous exclusion patterns found. Existing exclusions appear safe.'
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Exclusion Audit Summary'
                Status = 'OK'
                Detail = "$removedCount dangerous exclusion(s) removed. Run DEF004 DEFRealtimeProtection to review remaining exclusions."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Exclusion Audit'
            Status = 'WARN'
            Detail = "Could not query preferences: $($_.Exception.Message). Exclusion audit skipped."
        })
    }
}

# ============================================================
# Step 8 -- Restart Services
# ============================================================
if ($doRestart) {
    Write-Output ''
    Write-Output '--- Step 8: Restarting Defender Services ---'

    # WinDefend (MsMpEng.exe) runs as a Protected Process Light (PPL).
    # Even SYSTEM cannot stop it -- Stop-Service always returns Access Denied
    # on a healthy machine. Only WdNisSvc can be restarted locally.
    # A reboot is the only supported method to restart the Defender engine.

    # WdNisSvc -- Network Inspection Service (can be restarted)
    try {
        $nisSvc = Get-Service -Name 'WdNisSvc' -ErrorAction Stop
        try {
            if ($nisSvc.Status -eq 'Running') {
                Stop-Service -Name 'WdNisSvc' -Force -ErrorAction Stop
                Start-Sleep -Seconds 3
            }
            Start-Service -Name 'WdNisSvc' -ErrorAction Stop
            Start-Sleep -Seconds 2
            $nisSvc.Refresh()
            if ($nisSvc.Status -eq 'Running') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Restart: WdNisSvc'
                    Status = 'OK'
                    Detail = 'WdNisSvc (Network Inspection) restarted successfully. Status: Running.'
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Restart: WdNisSvc'
                    Status = 'WARN'
                    Detail = "WdNisSvc restart completed but status is $($nisSvc.Status). It may still be initializing."
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = 'Restart: WdNisSvc'
                Status = 'WARN'
                Detail = "Could not restart WdNisSvc -- $($_.Exception.Message)."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Restart: WdNisSvc'
            Status = 'INFO'
            Detail = 'WdNisSvc service not found. Skipping.'
        })
    }

    # WinDefend -- PPL-protected, cannot be restarted locally
    $findings.Add([PSCustomObject]@{
        Check  = 'Restart: WinDefend'
        Status = 'INFO'
        Detail = 'WinDefend (MsMpEng.exe) is a Protected Process Light (PPL). It cannot be stopped or restarted locally, even as SYSTEM. If the Defender engine needs a restart, reboot the machine.'
    })
}

# ============================================================
# Step 9 -- Trigger Quick Scan (Full mode only)
# ============================================================
if ($doQuickScan) {
    Write-Output ''
    Write-Output '--- Step 9: Triggering Quick Scan ---'

    try {
        Start-MpScan -ScanType QuickScan -ErrorAction Stop
        $findings.Add([PSCustomObject]@{
            Check  = 'Quick Scan'
            Status = 'OK'
            Detail = 'Quick scan initiated (runs asynchronously in background). This validates the engine is operational.'
        })
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Quick Scan'
            Status = 'WARN'
            Detail = "Failed to start quick scan: $($_.Exception.Message). The engine may not be fully operational yet."
        })
    }
}

# ============================================================
# Step 10 -- Force Intune Sync
# ============================================================
if ($doIntuneSync) {
    Write-Output ''
    Write-Output '--- Step 10: Triggering Intune Sync ---'

    $syncAttempted = $false
    try {
        # Filter to OMADM sync tasks only. Triggering all EnterpriseMgmt
        # tasks (enrollment retries, cert renewals) simultaneously can
        # cause the MDM client to throttle or throw COM errors.
        $mdmTasks = Get-ScheduledTask -ErrorAction Stop |
                    Where-Object { $_.TaskPath -like '*EnterpriseMgmt*' -and $_.TaskName -match 'OMA' }

        if ($null -ne $mdmTasks -and @($mdmTasks).Count -gt 0) {
            foreach ($task in @($mdmTasks)) {
                try {
                    Start-ScheduledTask -InputObject $task -ErrorAction Stop
                    $syncAttempted = $true
                } catch { }
            }

            if ($syncAttempted) {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Intune Sync'
                    Status = 'OK'
                    Detail = 'MDM sync tasks triggered. Compliance signal may take up to 15 minutes to update in the Intune portal.'
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Intune Sync'
                    Status = 'WARN'
                    Detail = 'MDM sync tasks found but none could be started. Check scheduled task permissions.'
                })
            }
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Intune Sync'
                Status = 'INFO'
                Detail = 'No EnterpriseMgmt scheduled tasks found. Device may not be MDM-enrolled. Intune sync skipped.'
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Intune Sync'
            Status = 'INFO'
            Detail = "Could not query scheduled tasks: $($_.Exception.Message). Intune sync skipped."
        })
    }
}

# ============================================================
# Step 11 -- Post-Remediation Verification (all modes)
# ============================================================
Write-Output ''
Write-Output '--- Step 11: Post-Remediation Verification ---'

# Service states
foreach ($svcName in @('WinDefend', 'WdNisSvc')) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            $findings.Add([PSCustomObject]@{
                Check  = "Verify: $svcName"
                Status = 'OK'
                Detail = "$svcName is running."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Verify: $svcName"
                Status = 'WARN'
                Detail = "$svcName status: $($svc.Status). Expected: Running."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = "Verify: $svcName"
            Status = 'WARN'
            Detail = "$svcName service not found."
        })
    }
}

# MpComputerStatus post-check
try {
    $postStatus = Get-MpComputerStatus -ErrorAction Stop

    # RTP
    if ($postStatus.RealTimeProtectionEnabled -eq $true) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Real-Time Protection'
            Status = 'OK'
            Detail = 'RTP is enabled. Defender is actively protecting the endpoint.'
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Real-Time Protection'
            Status = 'ISSUE'
            Detail = 'RTP is still disabled after remediation. A cloud policy, GPO, or Tamper Protection conflict may be overriding local settings. Run DEF004 and DEF005 for root cause.'
        })
    }

    # AM Service
    if ($postStatus.AMServiceEnabled -eq $true) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Antimalware Service'
            Status = 'OK'
            Detail = 'Antimalware service is enabled and operational.'
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Antimalware Service'
            Status = 'ISSUE'
            Detail = 'Antimalware service is not enabled. Defender engine may have failed to initialize.'
        })
    }

    # Signature age
    $sigAge = $postStatus.AntivirusSignatureAge
    if ($sigAge -le 3) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Signature Age'
            Status = 'OK'
            Detail = "Signatures are $sigAge day(s) old. Acceptable."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Signature Age'
            Status = 'WARN'
            Detail = "Signatures are $sigAge day(s) old. Still stale. Run DEF002 DEFDefinitionHealth for diagnostics."
        })
    }

    # Running mode
    $runMode = if ($postStatus.AMRunningMode) { $postStatus.AMRunningMode.ToString() } else { 'Unknown' }
    $preMode = if ($preState.DefenderMode) { $preState.DefenderMode } else { 'Unknown' }
    if ($runMode -match 'Normal|Active') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Defender Mode'
            Status = 'OK'
            Detail = "Defender is in $runMode mode. Was: $preMode."
        })
    } elseif ($runMode -match 'Passive') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Defender Mode'
            Status = 'WARN'
            Detail = "Defender is still in Passive mode (was: $preMode). A third-party AV may still be registered or a policy is forcing passive mode."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: Defender Mode'
            Status = 'INFO'
            Detail = "Defender running mode: $runMode (was: $preMode)."
        })
    }
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Verify: MpComputerStatus'
        Status = 'WARN'
        Detail = "Could not query post-remediation status: $($_.Exception.Message)"
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
    Write-Output "RESULT: Remediation ($mode mode) completed successfully. All steps passed."
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: Remediation ($mode mode) completed with $warnCount warning(s). Review items marked [!] above."
} else {
    Write-Output "RESULT: Remediation ($mode mode) completed with $issueCount issue(s) and $warnCount warning(s). Review items marked [!!] above."
}

Write-Output ''
Write-Output "NEXT:   Pre-remediation state saved to $preStatePath"
Write-Output '        Run DEF001 DEFStatusTriage to verify the fix.'
Write-Output '        If compliance still failing -> check Intune compliance policy config'
Write-Output '        (the issue may be policy-side, not endpoint-side).'
Write-Output ''
