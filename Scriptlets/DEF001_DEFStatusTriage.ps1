# DEF001_DEFStatusTriage.ps1
# Scriptlet: DEF001 - Defender & AV Status Triage
# Context: System | Version: 2.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Defender & AV Status Triage ==='
Write-Output ''

$issueCount = 0
$warnCount = 0

# State tracking for signal gap analysis
$hasThirdPartyAV = $false
$thirdPartyAVOn = $false
$defenderPassive = $false
$secCenterAvailable = $true

# --- Check 1: Security Center AV Products ---
try {
    $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
    if ($null -eq $avProducts -or @($avProducts).Count -eq 0) {
        Write-Output '[!!]  Security Center AV Products'
        Write-Output '       No antivirus products registered in Security Center. Machine may be unprotected.'
        $issueCount++
    } else {
        foreach ($av in @($avProducts)) {
            $pState = [UInt32]$av.productState
            $engineBits = $pState -band 0xF000
            $sigBits    = $pState -band 0x00F0
            $ownerBits  = $pState -band 0x0F00

            $engineState = switch ($engineBits) {
                0x1000 { 'On' }
                0x0000 { 'Off' }
                0x2000 { 'Snoozed' }
                0x3000 { 'Expired' }
                default { "Unknown (0x$($engineBits.ToString('X4')))" }
            }

            $sigState = if ($sigBits -eq 0x0000) { 'Current' } else { 'Outdated' }
            $owner    = if ($ownerBits -eq 0x0100) { 'Microsoft' } else { 'Third-party' }

            $isDefender = ($av.displayName -like '*Windows Defender*' -or $av.displayName -like '*Microsoft Defender*')

            if (-not $isDefender) {
                $hasThirdPartyAV = $true
                if ($engineState -eq 'On') { $thirdPartyAVOn = $true }
            }

            # Ghost detection: verify executable exists on disk
            $isGhost = $false
            $exePath = $av.pathToSignedReportingExe
            if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                # Skip URI-style paths (windowsdefender://) and environment variable paths
                if ($exePath -notlike 'windowsdefender://*' -and $exePath -notlike '%*') {
                    if (-not (Test-Path $exePath)) {
                        $isGhost = $true
                    }
                }
            }

            if ($isGhost) {
                Write-Output "[!!]  Security Center: $($av.displayName)"
                Write-Output "       GHOST REGISTRATION -- product registered but executable not found on disk."
                Write-Output "       Path: $exePath"
                Write-Output '       Intune sees this as the AV, but it is not installed. Run DEF003 DEFThirdPartyAV.'
                $issueCount++
            } elseif (-not $isDefender -and ($engineState -ne 'On')) {
                Write-Output "[!!]  Security Center: $($av.displayName)"
                Write-Output "       State: $engineState, Signatures: $sigState, Origin: $owner."
                Write-Output '       Registered but not actively protecting. Check third-party AV configuration.'
                $issueCount++
            } elseif (-not $isDefender -and $engineState -eq 'On') {
                Write-Output "[i]   Security Center: $($av.displayName)"
                Write-Output "       State: $engineState, Signatures: $sigState, Origin: $owner."
                Write-Output '       Third-party AV is primary. Defender should be in passive mode.'
            } else {
                Write-Output "[OK]  Security Center: $($av.displayName)"
                Write-Output "       State: $engineState, Signatures: $sigState, Origin: $owner."
            }
        }
    }
} catch {
    $secCenterAvailable = $false
    Write-Output '[i]   Security Center AV Products'
    Write-Output '       SecurityCenter2 namespace not available (normal on Windows Server).'
    Write-Output '       Skipping Security Center checks. Defender status checked below.'
}

# --- Check 2: Defender Status (Get-MpComputerStatus) ---
$mpOK = $false
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $mpOK = $true

    $runMode = $mpStatus.AMRunningMode
    $rtpEnabled = $mpStatus.RealTimeProtectionEnabled

    # Running mode verdict
    if ($runMode -eq 'Normal' -and $rtpEnabled) {
        Write-Output '[OK]  Defender Running Mode'
        Write-Output "       Mode: $runMode. Real-time protection: Enabled. Defender is active and protecting."
    } elseif ($runMode -like '*Passive*') {
        $defenderPassive = $true
        if ($hasThirdPartyAV) {
            Write-Output '[i]   Defender Running Mode'
            Write-Output "       Mode: $runMode. This is expected -- a third-party AV is primary."
        } else {
            Write-Output '[!!]  Defender Running Mode'
            Write-Output "       Mode: $runMode but no third-party AV detected in Security Center."
            Write-Output '       A ghost AV registration may be forcing passive mode. Machine may be unprotected.'
            Write-Output '       Run DEF003 DEFThirdPartyAV to investigate.'
            $issueCount++
        }
    } elseif ($runMode -eq 'EDR Block Mode') {
        Write-Output '[i]   Defender Running Mode'
        Write-Output "       Mode: EDR Block Mode. AV is passive but EDR detections are actively blocked."
    } elseif ($runMode -eq 'Normal' -and -not $rtpEnabled) {
        Write-Output '[!!]  Defender Running Mode'
        Write-Output "       Mode: $runMode but Real-time protection is DISABLED."
        Write-Output '       Defender is primary but not scanning files. Run DEF004 DEFRealtimeProtection.'
        $issueCount++
    } else {
        $rtpText = if ($rtpEnabled) { 'Enabled' } else { 'Disabled' }
        Write-Output '[i]   Defender Running Mode'
        Write-Output "       Mode: $runMode. Real-time protection: $rtpText."
    }

    # Definition age
    $sigAge = $mpStatus.AntivirusSignatureAge
    $sigUpdated = $mpStatus.AntivirusSignatureLastUpdated
    $sigDateStr = 'unknown'
    if ($null -ne $sigUpdated -and $sigUpdated -ne [datetime]::MinValue) {
        $sigDateStr = $sigUpdated.ToString('yyyy-MM-dd HH:mm')
    }

    if ($sigAge -gt 3) {
        Write-Output '[!!]  Definition Age'
        Write-Output "       $sigAge day(s) old (last updated: $sigDateStr). Definitions are stale."
        Write-Output '       Run DEF002 DEFDefinitionHealth to diagnose update failures.'
        $issueCount++
    } elseif ($sigAge -gt 1) {
        Write-Output '[!]   Definition Age'
        Write-Output "       $sigAge day(s) old (last updated: $sigDateStr). Slightly behind."
        $warnCount++
    } else {
        Write-Output '[OK]  Definition Age'
        Write-Output "       $sigAge day(s) old (last updated: $sigDateStr). Definitions are current."
    }

    # Scan ages (only if Defender is active, not passive)
    if (-not $defenderPassive) {
        $quickAge = $mpStatus.QuickScanAge
        $fullAge  = $mpStatus.FullScanAge

        if ($fullAge -gt 30) {
            Write-Output '[!]   Scan History'
            Write-Output "       Quick scan: $quickAge day(s) ago. Full scan: $fullAge day(s) ago. No full scan in over 30 days."
            $warnCount++
        } elseif ($quickAge -gt 14) {
            Write-Output '[!]   Scan History'
            Write-Output "       Quick scan: $quickAge day(s) ago. Full scan: $fullAge day(s) ago. No quick scan in over 14 days."
            $warnCount++
        } else {
            Write-Output '[OK]  Scan History'
            Write-Output "       Quick scan: $quickAge day(s) ago. Full scan: $fullAge day(s) ago."
        }
    }

    # Platform info (informational)
    Write-Output '[i]   Platform Info'
    Write-Output "       Product: $($mpStatus.AMProductVersion), Engine: $($mpStatus.AMEngineVersion), NIS Engine: $($mpStatus.NISEngineVersion)."

    # Tamper protection (informational)
    $tamper = $mpStatus.IsTamperProtected
    if ($tamper) {
        Write-Output '[i]   Tamper Protection'
        Write-Output '       Enabled. Defender settings are protected from unauthorized changes.'
    } else {
        Write-Output '[i]   Tamper Protection'
        Write-Output '       Disabled. Defender settings can be modified by local admin or malware.'
    }

} catch {
    Write-Output '[!!]  Defender Status'
    Write-Output "       Get-MpComputerStatus failed: $($_.Exception.Message)"
    Write-Output '       Defender module may not be installed or is in a broken state.'
    $issueCount++
}

# --- Check 3: Core Defender Services ---
$services = @(
    @{ Name = 'WinDefend'; Display = 'Windows Defender Antivirus (WinDefend)'; ExpectedStart = 'Automatic' },
    @{ Name = 'WdNisSvc';  Display = 'Network Inspection Service (WdNisSvc)';  ExpectedStart = 'Manual' }
)

foreach ($svc in $services) {
    $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    if ($null -eq $s) {
        Write-Output "[!!]  $($svc.Display)"
        Write-Output '       Service not found. Defender may not be installed.'
        $issueCount++
    } else {
        $startType = $s.StartType.ToString()
        $status    = $s.Status.ToString()

        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display)"
            Write-Output "       DISABLED. Service cannot start. Run DEF008 DEFRemediation."
            $issueCount++
        } elseif ($status -ne 'Running' -and $svc.ExpectedStart -eq 'Automatic') {
            Write-Output "[!!]  $($svc.Display)"
            Write-Output "       $status, start type: $startType. Should be running. Run DEF008 DEFRemediation."
            $issueCount++
        } elseif ($status -ne 'Running' -and $svc.ExpectedStart -eq 'Manual') {
            Write-Output "[OK]  $($svc.Display)"
            Write-Output "       $status, start type: $startType. This is expected -- service starts on demand."
        } else {
            Write-Output "[OK]  $($svc.Display)"
            Write-Output "       $status, start type: $startType. Operational."
        }
    }
}

# --- Check 4: Defender for Endpoint (MDE Sensor) ---
$sense = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
if ($null -eq $sense) {
    Write-Output '[i]   Defender for Endpoint (Sense)'
    Write-Output '       Sense service not found. Device is not onboarded to MDE (may be expected).'
} else {
    $senseStatus = $sense.Status.ToString()
    $senseStart  = $sense.StartType.ToString()

    if ($senseStart -eq 'Disabled') {
        Write-Output '[!!]  Defender for Endpoint (Sense)'
        Write-Output "       DISABLED. MDE sensor cannot start. Onboard the device or check policies."
        $issueCount++
    } elseif ($senseStatus -ne 'Running') {
        Write-Output '[!!]  Defender for Endpoint (Sense)'
        Write-Output "       $senseStatus, start type: $senseStart. MDE sensor is not running."
        $issueCount++
    } else {
        $onboardReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -ErrorAction SilentlyContinue
        if ($null -ne $onboardReg -and $onboardReg.OnboardingState -eq 1) {
            $orgId = $onboardReg.OrgId
            Write-Output '[OK]  Defender for Endpoint (Sense)'
            Write-Output "       Running, onboarded. OrgId: $orgId."
        } else {
            Write-Output '[!]   Defender for Endpoint (Sense)'
            Write-Output "       Running but onboarding state unclear. Check MDE portal."
            $warnCount++
        }
    }
}

# --- Check 5: Signal Gap Analysis ---
if ($secCenterAvailable -and $mpOK) {
    if ($defenderPassive -and -not $hasThirdPartyAV) {
        Write-Output '[!!]  Signal Gap Analysis'
        Write-Output '       CRITICAL: Defender is in passive mode but no third-party AV is registered.'
        Write-Output '       A ghost AV registration may be the cause. Machine is likely UNPROTECTED.'
        Write-Output '       Run DEF003 DEFThirdPartyAV to investigate and DEF008 to remediate.'
    } elseif (-not $defenderPassive -and $thirdPartyAVOn) {
        Write-Output '[!!]  Signal Gap Analysis'
        Write-Output '       Defender is in active mode while a third-party AV is also active.'
        Write-Output '       Two AV engines running simultaneously causes severe performance issues.'
        Write-Output '       Run DEF003 DEFThirdPartyAV to resolve the conflict.'
        $issueCount++
    } else {
        Write-Output '[OK]  Signal Gap Analysis'
        Write-Output '       Security Center and Defender ground truth are consistent.'
    }
} else {
    Write-Output '[i]   Signal Gap Analysis'
    Write-Output '       Skipped -- Security Center or Defender status was not available for cross-reference.'
}

# --- Summary ---
Write-Output ''
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. Defender appears healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] and [!] above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}
Write-Output ''
Write-Output 'NEXT:   If Defender not running       -> restart WinDefend service or run DEF008 DEFRemediation'
Write-Output '        If definitions stale          -> run DEF002 DEFDefinitionHealth'
Write-Output '        If third-party AV detected    -> run DEF003 DEFThirdPartyAV'
Write-Output '        If passive mode unexpected    -> run DEF003 DEFThirdPartyAV (likely ghost registration)'
Write-Output '        If RTP disabled               -> run DEF004 DEFRealtimeProtection'
Write-Output '        If Security Center mismatch   -> run DEF003 DEFThirdPartyAV'
