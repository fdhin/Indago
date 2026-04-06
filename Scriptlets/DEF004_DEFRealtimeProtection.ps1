# DEF004_DEFRealtimeProtection.ps1
# Scriptlet: DEF004 - Real-Time Protection & Tamper Protection Diagnostics
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Real-Time Protection & Tamper Protection Diagnostics ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Helper: Read registry value safely
# ---------------------------------------------------------------
function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $Name)) {
            return $item.$Name
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------
# Check 1: Real-Time Protection State Deep Dive
# ---------------------------------------------------------------
Write-Output '--- Real-Time Protection State ---'

$mpStatus = $null
$statusOK = $false
try {
    $mpStatus = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpComputerStatus -ErrorAction Stop
    if ($null -ne $mpStatus) { $statusOK = $true }
} catch { }

if (-not $statusOK) {
    Write-Output '[ERR] Cannot Query Defender Status'
    Write-Output '       Get-MpComputerStatus / CIM query failed.'
    Write-Output '       The Defender WMI provider may be unregistered or WinDefend is not installed.'
    Write-Output '       Run DEF001 DEFStatusTriage to check service health first.'
    $issueCount++
} else {
    $rtpEnabled   = $mpStatus.RealTimeProtectionEnabled
    $onAccess     = $mpStatus.OnAccessProtectionEnabled
    $behavior     = $mpStatus.BehaviorMonitorEnabled
    $ioav         = $mpStatus.IoavProtectionEnabled
    $scanDir      = $mpStatus.RealTimeScanDirection

    $subComponents = @(
        @{ Name = 'RealTimeProtection'; Value = $rtpEnabled; Display = 'Real-Time Protection' }
        @{ Name = 'OnAccessProtection'; Value = $onAccess;   Display = 'On-Access Protection' }
        @{ Name = 'BehaviorMonitor';    Value = $behavior;   Display = 'Behavior Monitoring' }
        @{ Name = 'IoavProtection';     Value = $ioav;       Display = 'IOAV Protection (downloads)' }
    )

    $allEnabled = $true
    foreach ($sc in $subComponents) {
        if ($sc.Value -ne $true) { $allEnabled = $false }
    }

    if ($allEnabled) {
        $dirDesc = switch ([int]$scanDir) {
            0 { 'Both incoming and outgoing' }
            1 { 'Incoming only' }
            2 { 'Outgoing only' }
            default { "Unknown ($scanDir)" }
        }
        Write-Output '[OK]  Real-Time Protection: Enabled'
        Write-Output '       All sub-components active: RTP, OnAccess, BehaviorMonitor, IOAV.'
        Write-Output "       Scan direction: $dirDesc."
        if ([int]$scanDir -ne 0) {
            Write-Output '[!]   Scan Direction: Partial'
            Write-Output "       RealTimeScanDirection = $scanDir. Only scanning in one direction."
            Write-Output '       Set to 0 (both) for full protection.'
            $warnCount++
        }
    } else {
        # Identify which sub-components are disabled and attribute source
        $gpoRtpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
        $mdmPath    = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender'

        foreach ($sc in $subComponents) {
            if ($sc.Value -eq $true) {
                Write-Output "[OK]  $($sc.Display): Enabled"
            } else {
                # Determine who disabled it
                $source = 'Unknown'

                if ($sc.Name -eq 'RealTimeProtection') {
                    $gpoVal = Get-RegVal -Path $gpoRtpPath -Name 'DisableRealtimeMonitoring'
                    $mdmVal = Get-RegVal -Path $mdmPath -Name 'AllowRealtimeMonitoring'
                    if ($null -ne $gpoVal -and $gpoVal -eq 1) {
                        $source = 'GPO (DisableRealtimeMonitoring = 1)'
                    } elseif ($null -ne $mdmVal -and $mdmVal -eq 0) {
                        $source = 'MDM/Intune (AllowRealtimeMonitoring = 0)'
                    } else {
                        # Check local preference
                        try {
                            $pref = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpPreference -ErrorAction Stop
                            if ($null -ne $pref -and $pref.DisableRealtimeMonitoring -eq $true) {
                                $source = 'Local preference (Set-MpPreference or UI toggle)'
                            }
                        } catch { }
                        if ($source -eq 'Unknown') { $source = 'Could not determine -- may be third-party AV or transient state' }
                    }
                } elseif ($sc.Name -eq 'BehaviorMonitor') {
                    $gpoVal = Get-RegVal -Path $gpoRtpPath -Name 'DisableBehaviorMonitoring'
                    $mdmVal = Get-RegVal -Path $mdmPath -Name 'AllowBehaviorMonitoring'
                    if ($null -ne $gpoVal -and $gpoVal -eq 1) {
                        $source = 'GPO (DisableBehaviorMonitoring = 1)'
                    } elseif ($null -ne $mdmVal -and $mdmVal -eq 0) {
                        $source = 'MDM/Intune (AllowBehaviorMonitoring = 0)'
                    } else {
                        $source = 'Local preference or transient state'
                    }
                } elseif ($sc.Name -eq 'OnAccessProtection') {
                    $gpoVal = Get-RegVal -Path $gpoRtpPath -Name 'DisableOnAccessProtection'
                    if ($null -ne $gpoVal -and $gpoVal -eq 1) {
                        $source = 'GPO (DisableOnAccessProtection = 1)'
                    } else {
                        $source = 'Local preference or transient state'
                    }
                } elseif ($sc.Name -eq 'IoavProtection') {
                    $gpoVal = Get-RegVal -Path $gpoRtpPath -Name 'DisableIOAVProtection'
                    if ($null -ne $gpoVal -and $gpoVal -eq 1) {
                        $source = 'GPO (DisableIOAVProtection = 1)'
                    } else {
                        $source = 'Local preference or transient state'
                    }
                }

                Write-Output "[!!]  $($sc.Display): DISABLED"
                Write-Output "       Disabled by: $source."
                if ($sc.Name -eq 'RealTimeProtection') {
                    Write-Output '       The primary scanning engine is off. Endpoint is not actively protected.'
                } elseif ($sc.Name -eq 'BehaviorMonitor') {
                    Write-Output '       Heuristic analysis is off. Defender cannot detect anomalous process behavior.'
                } elseif ($sc.Name -eq 'OnAccessProtection') {
                    Write-Output '       File-system interception is off. Files are not scanned on read/write.'
                } elseif ($sc.Name -eq 'IoavProtection') {
                    Write-Output '       Download scanning is off. Files from IE/Edge are not inspected.'
                }
                $issueCount++
            }
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: Tamper Protection Diagnostics
# ---------------------------------------------------------------
Write-Output '--- Tamper Protection ---'

$tpFeaturesPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'

$tpValue  = Get-RegVal -Path $tpFeaturesPath -Name 'TamperProtection'
$tpSource = Get-RegVal -Path $tpFeaturesPath -Name 'TamperProtectionSource'
$tpExcl   = Get-RegVal -Path $tpFeaturesPath -Name 'TPExclusions'

$defenderPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
$managedType  = Get-RegVal -Path $defenderPath -Name 'ManagedDefenderProductType'

if ($null -eq $tpValue) {
    Write-Output '[!]   Tamper Protection: Not Configured'
    Write-Output '       TamperProtection registry value not found.'
    Write-Output '       Defender settings can be modified by any process with admin rights.'
    $warnCount++
} elseif ([int]$tpValue -eq 5) {
    $srcStr = 'Unknown'
    if ($null -ne $tpSource) {
        $srcStr = switch ([int]$tpSource) {
            5 { 'Microsoft signatures/cloud defaults' }
            default { "Source code $tpSource" }
        }
    }
    Write-Output '[OK]  Tamper Protection: Active (value = 5)'
    Write-Output "       Source: $srcStr."
    Write-Output '       Defender settings are protected from local tampering.'
    Write-Output '       Changes must come from Intune/MDE portal or cloud policy.'

    # Cross-reference: if RTP is disabled while TP is active, it was disabled at a higher level
    if ($statusOK -and $mpStatus.RealTimeProtectionEnabled -ne $true) {
        Write-Output '[i]   Note: RTP is disabled despite Tamper Protection being active.'
        Write-Output '       This means RTP was disabled at a level ABOVE tamper protection'
        Write-Output '       (cloud policy, MDM, or GPO with MDMWinsOverGP). Local re-enable'
        Write-Output '       attempts will be silently reverted by Tamper Protection.'
    }
} elseif ([int]$tpValue -eq 4) {
    Write-Output '[!]   Tamper Protection: Disabled (value = 4, was previously enabled)'
    Write-Output '       Someone or something disabled Tamper Protection.'
    Write-Output '       Defender settings can now be modified by any admin process.'
    Write-Output '       Re-enable via Intune or Windows Security UI.'
    $warnCount++
} else {
    Write-Output "[!]   Tamper Protection: Off (value = $tpValue)"
    Write-Output '       Defender settings are unprotected from local tampering.'
    $warnCount++
}

# TPExclusions
if ($null -ne $tpExcl -and [int]$tpExcl -eq 1) {
    Write-Output '[OK]  Exclusion Protection: Tamper-protected'
    Write-Output '       TPExclusions = 1. Local admins cannot modify AV exclusions.'
    if ($null -ne $managedType -and [int]$managedType -eq 6) {
        Write-Output '       ManagedDefenderProductType = 6 (Intune standalone). Required for TPExclusions.'
    }
} else {
    $tpExclStr = if ($null -eq $tpExcl) { 'not set' } else { "$tpExcl" }
    Write-Output "[i]   Exclusion Protection: Not tamper-protected (TPExclusions = $tpExclStr)"
    Write-Output '       Local admins can add, modify, or remove AV exclusions.'
}

# Management type
if ($null -ne $managedType) {
    $mgmtStr = switch ([int]$managedType) {
        6 { 'Intune standalone' }
        7 { 'Co-managed (Intune + ConfigMgr)' }
        default { "Type $managedType" }
    }
    Write-Output "[i]   Management Type: $mgmtStr (ManagedDefenderProductType = $managedType)"
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: MsMpEng.exe Process Health
# ---------------------------------------------------------------
Write-Output '--- MsMpEng.exe Process Health ---'

$mpProc = $null
try {
    $mpProc = Get-Process -Name MsMpEng -ErrorAction Stop | Select-Object -First 1
} catch { }

if ($null -eq $mpProc) {
    Write-Output '[!!]  MsMpEng.exe: NOT RUNNING'
    Write-Output '       The Defender antimalware engine process is not found.'
    Write-Output '       RTP cannot function without this process.'
    Write-Output '       Run DEF001 DEFStatusTriage to check WinDefend service status.'
    $issueCount++
} else {
    $procId = $mpProc.Id
    $wsBytes = $mpProc.WorkingSet64
    $wsMB = [math]::Round($wsBytes / 1MB, 0)

    # CPU measurement: two samples 2 seconds apart
    $cpuPct = 0
    try {
        $procCount = [Environment]::ProcessorCount
        if ($procCount -lt 1) { $procCount = 1 }

        $cpu1 = $mpProc.TotalProcessorTime.TotalMilliseconds
        $time1 = [DateTime]::UtcNow

        Start-Sleep -Seconds 2

        # Refresh process data
        $mpProc2 = Get-Process -Id $procId -ErrorAction Stop
        $cpu2 = $mpProc2.TotalProcessorTime.TotalMilliseconds
        $time2 = [DateTime]::UtcNow

        $cpuDelta = $cpu2 - $cpu1
        $timeDelta = ($time2 - $time1).TotalMilliseconds
        if ($timeDelta -gt 0) {
            $cpuPct = [math]::Round(($cpuDelta / ($timeDelta * $procCount)) * 100, 1)
        }
    } catch {
        $cpuPct = -1
    }

    # Uptime
    $uptime = ''
    try {
        $startTime = $mpProc.StartTime
        if ($null -ne $startTime) {
            $uptimeSpan = (Get-Date) - $startTime
            if ($uptimeSpan.Days -gt 0) {
                $uptime = "$($uptimeSpan.Days) day(s)"
            } elseif ($uptimeSpan.Hours -gt 0) {
                $uptime = "$($uptimeSpan.Hours) hour(s)"
            } else {
                $uptime = "$($uptimeSpan.Minutes) minute(s)"
            }
        }
    } catch { }

    # Memory verdict
    if ($wsBytes -gt 1073741824) {
        Write-Output "[!!]  MsMpEng.exe (PID: $procId)"
        Write-Output "       Memory: $wsMB MB working set. EXCESSIVE (> 1 GB)."
        Write-Output '       Possible scan hang, definition corruption, or scanning its own cache.'
        Write-Output '       Run DEF008 DEFRemediation to flush definition cache.'
        $issueCount++
    } elseif ($wsBytes -gt 536870912) {
        Write-Output "[!]   MsMpEng.exe (PID: $procId)"
        Write-Output "       Memory: $wsMB MB working set. Elevated (> 500 MB)."
        Write-Output '       Monitor for continued growth. May indicate a large scan in progress.'
        $warnCount++
    } else {
        Write-Output "[OK]  MsMpEng.exe (PID: $procId)"
        Write-Output "       Memory: $wsMB MB working set. Normal."
    }

    # CPU verdict
    if ($cpuPct -lt 0) {
        Write-Output '[i]   CPU: Could not measure (process access issue).'
    } elseif ($cpuPct -gt 30) {
        Write-Output "[!!]  CPU: ${cpuPct}% (measured over 2 seconds)"
        Write-Output '       Sustained high CPU suggests a scan loop or definition unpacking issue.'
        Write-Output '       Check for recursive archive scanning or exclusion on the Scans directory.'
        $issueCount++
    } elseif ($cpuPct -gt 10) {
        Write-Output "[!]   CPU: ${cpuPct}% (measured over 2 seconds)"
        Write-Output '       Elevated CPU. A scan may be in progress. Monitor.'
        $warnCount++
    } else {
        Write-Output "[OK]  CPU: ${cpuPct}% (measured over 2 seconds). Normal."
    }

    if ($uptime.Length -gt 0) {
        Write-Output "[i]   Uptime: $uptime."
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Exclusion Audit
# ---------------------------------------------------------------
Write-Output '--- Exclusion Audit ---'

$mpPref = $null
$prefOK = $false
try {
    $mpPref = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpPreference -ErrorAction Stop
    if ($null -ne $mpPref) { $prefOK = $true }
} catch { }

if (-not $prefOK) {
    Write-Output '[!]   Cannot Query Defender Preferences'
    Write-Output '       Get-MpPreference / CIM query failed. Cannot audit exclusions.'
    $warnCount++
} else {
    $exclPaths = @()
    $exclExts  = @()
    $exclProcs = @()

    if ($null -ne $mpPref.ExclusionPath) { $exclPaths = @($mpPref.ExclusionPath) }
    if ($null -ne $mpPref.ExclusionExtension) { $exclExts = @($mpPref.ExclusionExtension) }
    if ($null -ne $mpPref.ExclusionProcess) { $exclProcs = @($mpPref.ExclusionProcess) }

    # Dangerous path patterns
    $dangerousPathPatterns = @(
        @{ Pattern = '^\w:\\$';                  Severity = 'ISSUE'; Reason = 'Entire drive root excluded. RTP effectively disabled for this volume.' }
        @{ Pattern = '^\w:\\\*';                 Severity = 'ISSUE'; Reason = 'Root wildcard. All files on this volume are excluded.' }
        @{ Pattern = '(?i)^\w:\\Windows\\?$';    Severity = 'ISSUE'; Reason = 'Entire Windows directory excluded. Critical system files unscanned.' }
        @{ Pattern = '(?i)^\w:\\Windows\\Temp';  Severity = 'ISSUE'; Reason = 'Windows Temp excluded. Extremely common malware staging location.' }
        @{ Pattern = '(?i)^\w:\\Windows\\Prefetch'; Severity = 'WARN'; Reason = 'Prefetch excluded. Malware can stage here.' }
        @{ Pattern = '(?i)^\w:\\Program Files\\?$'; Severity = 'WARN'; Reason = 'Entire Program Files excluded. Broad but sometimes required by vendors.' }
        @{ Pattern = '(?i)^\w:\\Program Files \(x86\)\\?$'; Severity = 'WARN'; Reason = 'Entire Program Files (x86) excluded.' }
        @{ Pattern = '(?i)%APPDATA%';            Severity = 'WARN'; Reason = 'User-context variable trap: resolves to systemprofile in SYSTEM context, not the actual user folder.' }
        @{ Pattern = '(?i)%LOCALAPPDATA%';       Severity = 'WARN'; Reason = 'User-context variable trap: resolves to systemprofile\\AppData\\Local in SYSTEM context.' }
        @{ Pattern = '(?i)%USERPROFILE%';        Severity = 'WARN'; Reason = 'User-context variable trap: resolves to systemprofile in SYSTEM context.' }
        @{ Pattern = '(?i)^\*\.\*$';            Severity = 'ISSUE'; Reason = 'Wildcard *.* at path level. All files excluded.' }
    )

    # Dangerous extension patterns
    $dangerousExts = @('.exe', '.dll', '.ps1', '.bat', '.cmd', '.vbs', '.js', '.wsf', '.scr', '.com')

    # -- Path exclusions --
    if ($exclPaths.Count -eq 0) {
        Write-Output '[OK]  Path Exclusions: None configured.'
    } else {
        Write-Output "[i]   Path Exclusions ($($exclPaths.Count) configured)"

        foreach ($ep in $exclPaths) {
            $isDangerous = $false
            $matchedReason = ''
            $matchedSeverity = ''

            foreach ($dp in $dangerousPathPatterns) {
                if ($ep -match $dp.Pattern) {
                    $isDangerous = $true
                    $matchedReason = $dp.Reason
                    $matchedSeverity = $dp.Severity
                    break
                }
            }

            if ($isDangerous) {

                if ($matchedSeverity -eq 'ISSUE') {
                    Write-Output "[!!]  DANGEROUS: $ep"
                    Write-Output "       $matchedReason"
                    $issueCount++
                } else {
                    Write-Output "[!]   REVIEW: $ep"
                    Write-Output "       $matchedReason"
                    $warnCount++
                }
            } else {
                Write-Output "       $ep"
            }
        }
    }

    # -- Extension exclusions --
    if ($exclExts.Count -eq 0) {
        Write-Output '[OK]  Extension Exclusions: None configured.'
    } else {
        Write-Output "[i]   Extension Exclusions ($($exclExts.Count) configured)"
        foreach ($ee in $exclExts) {
            $extNorm = $ee.Trim()
            if (-not $extNorm.StartsWith('.')) { $extNorm = ".$extNorm" }

            $extLower = $extNorm.ToLower()
            if ($extLower -eq '*.*' -or $extLower -eq '.*' -or $extLower -eq '*') {
                Write-Output "[!!]  DANGEROUS: $ee"
                Write-Output '       Wildcard extension. ALL file types excluded from scanning.'
                $issueCount++
            } elseif ($dangerousExts -contains $extLower) {
                Write-Output "[!!]  DANGEROUS: $ee"
                Write-Output '       Executable file type excluded. Malware in this format will not be scanned.'
                $issueCount++
            } else {
                Write-Output "       $ee"
            }
        }
    }

    # -- Process exclusions --
    if ($exclProcs.Count -eq 0) {
        Write-Output '[OK]  Process Exclusions: None configured.'
    } else {
        Write-Output "[i]   Process Exclusions ($($exclProcs.Count) configured)"
        foreach ($ep in $exclProcs) {
            Write-Output "       $ep"
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4b: Shadow Exclusion Registry Audit
# Get-MpPreference / MSFT_MpPreference only surfaces the active
# merged exclusion set. Two additional registry hives can hold
# exclusions that the modern cmdlets do not report:
#   1. GPO policy path -- actively honored, but lacks WdFilter
#      kernel protection (primary attack surface for T1562.001)
#   2. Legacy SCEP/Microsoft Antimalware path -- invisible to
#      modern WMI classes but may still be read by some components
# ---------------------------------------------------------------
Write-Output '--- Shadow Exclusion Registry Audit ---'

$shadowHives = @(
    @{
        Label = 'GPO Policy'
        Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
        Risk  = 'HIGH -- this path is actively honored by Defender but lacks kernel-mode protection.'
    }
    @{
        Label = 'Legacy SCEP/Antimalware'
        Path  = 'HKLM:\SOFTWARE\Microsoft\Microsoft Antimalware\Exclusions'
        Risk  = 'MEDIUM -- legacy hive invisible to Get-MpPreference. APTs exploit this blind spot.'
    }
)

$shadowFound = $false

foreach ($hive in $shadowHives) {
    if (-not (Test-Path $hive.Path)) { continue }

    $subKeys = @('Paths', 'Extensions', 'Processes')
    foreach ($sub in $subKeys) {
        $subPath = "$($hive.Path)\$sub"
        if (-not (Test-Path $subPath)) { continue }

        $entries = $null
        try {
            $regItem = Get-ItemProperty -Path $subPath -ErrorAction Stop
            if ($null -ne $regItem) {
                $entries = @($regItem.PSObject.Properties | Where-Object {
                    $_.Name -notmatch '^PS' -and $_.Name -ne '(default)'
                })
            }
        } catch { }

        if ($null -ne $entries -and $entries.Count -gt 0) {
            if (-not $shadowFound) {
                Write-Output '[!!]  Shadow Exclusions Detected Outside Normal WMI View'
                $shadowFound = $true
            }

            Write-Output ''
            Write-Output "[!!]  $($hive.Label): $($entries.Count) $sub exclusion(s)"
            Write-Output "       Source: $($hive.Path)\$sub"
            Write-Output "       Risk: $($hive.Risk)"

            $showMax = [math]::Min($entries.Count, 10)
            for ($ei = 0; $ei -lt $showMax; $ei++) {
                Write-Output "       - $($entries[$ei].Name)"
            }
            if ($entries.Count -gt 10) {
                Write-Output "       ... and $($entries.Count - 10) more"
            }
            $issueCount++
        }
    }
}

if (-not $shadowFound) {
    Write-Output '[OK]  No shadow exclusions found in GPO policy or legacy SCEP registry hives.'
    Write-Output '       All exclusions are visible through the standard MSFT_MpPreference WMI class.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: ASR (Attack Surface Reduction) Rules
# ---------------------------------------------------------------
Write-Output '--- ASR Rules ---'

# GUID-to-name mapping
$asrNames = @{}
$asrNames['d4f940ab-401b-4efc-aadc-ad5f3c50688a'] = 'Block Office apps from creating child processes'
$asrNames['3b576869-a4ec-4529-8536-b80a7769e899'] = 'Block Office apps from creating executable content'
$asrNames['92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'] = 'Block Win32 API calls from Office macros'
$asrNames['9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'] = 'Block credential stealing from LSASS'
$asrNames['5beb7efe-fd9a-4556-801d-275e5ffc04cc'] = 'Block execution of potentially obfuscated scripts'
$asrNames['be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'] = 'Block executable content from email/webmail'
$asrNames['01443614-cd74-433a-b99e-2ecdc07bfc25'] = 'Block executable files unless trust criteria met'
$asrNames['26190899-1602-49e8-8b27-eb1d0a1ce869'] = 'Block Office comm apps from creating child processes'
$asrNames['7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'] = 'Block Adobe Reader from creating child processes'
$asrNames['75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'] = 'Block Office apps from injecting code into processes'
$asrNames['d1e49aac-8f56-4280-b9ba-993a6d77406c'] = 'Block process creations from PSExec and WMI'
$asrNames['b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4'] = 'Block untrusted/unsigned processes from USB'
$asrNames['e6db77e5-3df2-4cf1-b95a-636979351e5b'] = 'Block persistence through WMI event subscription'
$asrNames['56a863a9-875e-4185-98a7-b882c64b5ce5'] = 'Block abuse of exploited vulnerable signed drivers'
$asrNames['c1db55ab-c21a-4637-bb3f-a12568109d35'] = 'Block use of copied or impersonated system tools'

# High-disruption GUIDs (commonly cause app compat issues)
$highDisruption = @(
    'd4f940ab-401b-4efc-aadc-ad5f3c50688a'
    '3b576869-a4ec-4529-8536-b80a7769e899'
    '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'
    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'
    '5beb7efe-fd9a-4556-801d-275e5ffc04cc'
)

$asrIds     = $null
$asrActions = $null

if ($prefOK -and $null -ne $mpPref) {
    $asrIds     = $mpPref.AttackSurfaceReductionRules_Ids
    $asrActions = $mpPref.AttackSurfaceReductionRules_Actions
}

if ($null -eq $asrIds -or @($asrIds).Count -eq 0) {
    Write-Output '[i]   ASR Rules: Not configured'
    Write-Output '       No Attack Surface Reduction rules are active on this endpoint.'
    Write-Output '       Consider enabling high-value rules in Audit mode first.'
} else {
    $asrIdArray     = @($asrIds)
    $asrActionArray = @($asrActions)

    Write-Output "[i]   ASR Rules: $($asrIdArray.Count) configured"

    $highDisruptionBlockCount = 0

    for ($i = 0; $i -lt $asrIdArray.Count; $i++) {
        $ruleGuid = $asrIdArray[$i].ToLower()
        $ruleAction = if ($i -lt $asrActionArray.Count) { [int]$asrActionArray[$i] } else { -1 }

        $actionStr = switch ($ruleAction) {
            0 { 'Disabled' }
            1 { 'Block' }
            2 { 'Audit' }
            6 { 'Warn' }
            default { "Unknown ($ruleAction)" }
        }

        $ruleName = $asrNames[$ruleGuid]
        if ([string]::IsNullOrWhiteSpace($ruleName)) {
            $ruleName = "Unknown rule"
        }

        $shortGuid = $ruleGuid.Substring(0, 8)
        $isHighDisruption = $highDisruption -contains $ruleGuid

        if ($ruleAction -eq 0) {
            Write-Output "[i]   $ruleName ($shortGuid): $actionStr"
        } elseif ($isHighDisruption -and $ruleAction -eq 1) {
            Write-Output "[!]   $ruleName ($shortGuid): $actionStr"
            Write-Output '       This rule commonly causes app compat issues (Office, scripts, macros).'
            Write-Output '       If users report application failures, this may be the cause.'
            Write-Output '       Consider switching to Audit mode to diagnose before blocking.'
            $highDisruptionBlockCount++
            $warnCount++
        } elseif ($ruleAction -eq 1) {
            Write-Output "[OK]  $ruleName ($shortGuid): $actionStr"
        } elseif ($ruleAction -eq 2) {
            Write-Output "[OK]  $ruleName ($shortGuid): $actionStr"
        } elseif ($ruleAction -eq 6) {
            Write-Output "[i]   $ruleName ($shortGuid): $actionStr"
        } else {
            Write-Output "[i]   $ruleName ($shortGuid): $actionStr"
        }
    }

    if ($highDisruptionBlockCount -gt 0) {
        Write-Output ''
        Write-Output "[!]   $highDisruptionBlockCount high-disruption rule(s) in Block mode."
        Write-Output '       Admins sometimes disable RTP as a workaround for ASR compat issues.'
        Write-Output '       If RTP is off, check if ASR friction is the root cause.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. RTP and Tamper Protection appear healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If disabled by GPO         -> run DEF005 DEFPolicyConflict to identify the source'
Write-Output '        If tamper protection blocking changes -> changes must come from Intune cloud policy'
Write-Output '        If MsMpEng stuck           -> restart WinDefend service or run DEF008 DEFRemediation'
Write-Output '        If exclusions too broad    -> review with the security admin'
Write-Output '        If ASR compat issues       -> switch high-disruption rules from Block to Audit'
Write-Output ''
