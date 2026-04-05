# BL002_BLTpmHealth.ps1
# Scriptlet: BL002 - TPM Health & Readiness
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== TPM Health & Readiness ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0
$tpmPresent = $false

# ---------------------------------------------------------------
# Check 1: TPM Presence & State
# ---------------------------------------------------------------
Write-Output '--- TPM Presence & State ---'

$tpmObj = $null
$tpmOK = $false
$usedFallback = $false

try {
    $tpmObj = Get-Tpm -ErrorAction Stop
    if ($null -ne $tpmObj) { $tpmOK = $true }
} catch { }

if (-not $tpmOK) {
    # Fallback: tpmtool.exe getdeviceinformation
    $tpmToolPath = Join-Path $env:WinDir 'System32\tpmtool.exe'
    if (Test-Path $tpmToolPath) {
        try {
            $tpmToolOutput = & $tpmToolPath getdeviceinformation 2>&1
            $usedFallback = $true
            if ($null -ne $tpmToolOutput) {
                $tpmToolLines = @($tpmToolOutput | ForEach-Object { $_.ToString().Trim() })
                $fbPresent = $false
                $fbVersion = ''
                $fbVendor  = ''
                $fbLocked  = $false
                $fbInit    = $false
                foreach ($line in $tpmToolLines) {
                    if ($line -match 'TPM Present\s*:\s*(.+)') {
                        $fbPresent = ($Matches[1].Trim() -eq 'True')
                    }
                    if ($line -match 'TPM Version\s*:\s*(.+)') {
                        $fbVersion = $Matches[1].Trim()
                    }
                    if ($line -match 'TPM Manufacturer ID\s*:\s*(.+)') {
                        $fbVendor = $Matches[1].Trim()
                    }
                    if ($line -match 'Is Locked Out\s*:\s*(.+)') {
                        $fbLocked = ($Matches[1].Trim() -eq 'True')
                    }
                    if ($line -match 'Is Initialized\s*:\s*(.+)') {
                        $fbInit = ($Matches[1].Trim() -eq 'True')
                    }
                }
                if ($fbPresent) {
                    $tpmPresent = $true
                    Write-Output '[i]   TPM Present (tpmtool.exe fallback)'
                    Write-Output '       Get-Tpm cmdlet unavailable. Using tpmtool.exe for basic diagnostics.'
                    Write-Output "       TPM Present: True. Version: $fbVersion. Manufacturer: $fbVendor."
                    if ($fbInit) {
                        Write-Output '       Initialized: True.'
                    } else {
                        Write-Output '[!!]  TPM Not Initialized'
                        Write-Output '       The TPM has not been provisioned by the OS.'
                        $issueCount++
                    }
                    if ($fbLocked) {
                        Write-Output '[!!]  TPM Locked Out (tpmtool)'
                        Write-Output '       The TPM is currently refusing authentication commands.'
                        Write-Output '       Wait for the lockout to expire with the system powered on.'
                        $issueCount++
                    }
                } else {
                    Write-Output '[!!]  TPM Not Present'
                    Write-Output '       tpmtool.exe reports no TPM hardware detected.'
                    Write-Output '       Check BIOS/UEFI settings -- TPM may be disabled at the silicon level.'
                    $issueCount++
                }
                # With fallback, we have limited data. Report what we can and skip deep checks.
                Write-Output ''
                Write-Output '[i]   Limited diagnostics available via tpmtool.exe fallback.'
                Write-Output '       For full TPM health analysis, ensure the TrustedPlatformModule PowerShell module'
                Write-Output '       is available. Run: Get-Module -ListAvailable TrustedPlatformModule'
            } else {
                Write-Output '[!!]  TPM Status Unavailable'
                Write-Output '       Get-Tpm cmdlet failed and tpmtool.exe returned no data.'
                Write-Output '       TPM infrastructure may be missing or corrupted.'
                $issueCount++
            }
        } catch {
            Write-Output '[!!]  TPM Status Unavailable'
            Write-Output '       Get-Tpm cmdlet failed and tpmtool.exe also failed.'
            Write-Output '       TPM infrastructure may be missing or corrupted.'
            $issueCount++
        }
    } else {
        Write-Output '[!!]  TPM Status Unavailable'
        Write-Output '       Get-Tpm cmdlet failed. tpmtool.exe not found.'
        Write-Output '       TPM infrastructure may be missing or corrupted.'
        $issueCount++
    }
} else {
    # Get-Tpm succeeded
    $tpmPresent = $tpmObj.TpmPresent

    if (-not $tpmPresent) {
        Write-Output '[!!]  TPM Not Present'
        Write-Output '       TpmPresent: False. No TPM hardware detected by the operating system.'
        Write-Output '       Check BIOS/UEFI settings -- TPM is often disabled by default on new hardware.'
        Write-Output '       BitLocker cannot use seamless pre-boot unlocking without a TPM.'
        $issueCount++
    } else {
        # TPM Present
        Write-Output '[OK]  TPM Present'
        Write-Output '       TpmPresent: True. The operating system detects the TPM hardware.'

        # TpmReady
        if ($tpmObj.TpmReady) {
            Write-Output '[OK]  TPM Ready'
            Write-Output '       TpmReady: True. TPM is fully compliant with Windows standards.'
        } else {
            Write-Output '[!!]  TPM Not Ready'
            Write-Output '       TpmReady: False. The TPM does not meet Windows readiness requirements.'
            Write-Output '       BitLocker and other cryptographic services cannot use this TPM.'
            $issueCount++
        }

        # TpmEnabled & TpmActivated
        $tpmEnabled   = $tpmObj.TpmEnabled
        $tpmActivated = $tpmObj.TpmActivated
        if ($tpmEnabled -and $tpmActivated) {
            Write-Output '[OK]  TPM Enabled & Activated'
            Write-Output '       TpmEnabled: True. TpmActivated: True.'
        } else {
            if (-not $tpmEnabled) {
                Write-Output '[!!]  TPM Not Enabled'
                Write-Output '       TpmEnabled: False. The TPM is present but disabled.'
                Write-Output '       Enable the TPM in BIOS/UEFI settings.'
                $issueCount++
            }
            if (-not $tpmActivated) {
                Write-Output '[!!]  TPM Not Activated'
                Write-Output '       TpmActivated: False. The TPM is enabled but not activated for cryptographic operations.'
                Write-Output '       Activation is typically done via BIOS/UEFI or OS provisioning.'
                $issueCount++
            }
        }

        # TpmOwned
        if ($tpmObj.TpmOwned) {
            Write-Output '[OK]  TPM Ownership'
            Write-Output '       TpmOwned: True. Windows has taken ownership of the TPM.'
        } else {
            Write-Output '[!]   TPM Not Owned'
            Write-Output '       TpmOwned: False. Windows has not taken ownership of the TPM.'
            $apProp = $tpmObj.AutoProvisioning
            if ($null -ne $apProp) {
                $apStr = $apProp.ToString()
                if ($apStr -eq 'Enabled') {
                    Write-Output '       AutoProvisioning is Enabled. Windows should take ownership on next boot.'
                } else {
                    Write-Output "       AutoProvisioning: $apStr. OS is not permitted to provision the TPM."
                    Write-Output '       Check Group Policy or MDM settings for TPM provisioning restrictions.'
                }
            } else {
                Write-Output '       Unable to determine AutoProvisioning state.'
            }
            $warnCount++
        }
    }
}

Write-Output ''

# Early exit: if TPM is not present AND we used Get-Tpm (not fallback), skip deep checks
if (-not $tpmPresent) {
    Write-Output ''
    if ($issueCount -eq 0 -and $warnCount -eq 0) {
        Write-Output 'RESULT: No issues detected. TPM is healthy and ready for BitLocker.'
    } elseif ($issueCount -eq 0) {
        Write-Output "RESULT: $warnCount warning(s) found. TPM is functional but review the flagged items."
    } else {
        Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. TPM needs attention."
    }
    Write-Output ''
    Write-Output 'NEXT:   If TPM not present         -> check BIOS settings (often disabled by default)'
    Write-Output '        If TPM 1.2                 -> may need hardware upgrade or BIOS setting to enable 2.0 mode'
    Write-Output '        If firmware flagged        -> visit OEM support site for TPM firmware update'
    Write-Output '        If TPM locked out          -> wait for lockout to expire, then retry'
    Write-Output '        If TPM ready               -> run BL003 BLHardwarePrereqs to check other prerequisites'
    return
}

# If we used the fallback, we also skip deep checks (already reported limited info)
if ($usedFallback) {
    Write-Output ''
    if ($issueCount -eq 0 -and $warnCount -eq 0) {
        Write-Output 'RESULT: No issues detected (limited diagnostics via tpmtool.exe).'
    } elseif ($issueCount -eq 0) {
        Write-Output "RESULT: $warnCount warning(s) found (limited diagnostics via tpmtool.exe)."
    } else {
        Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found (limited diagnostics)."
    }
    Write-Output ''
    Write-Output 'NEXT:   If TPM not present         -> check BIOS settings (often disabled by default)'
    Write-Output '        If TPM 1.2                 -> may need hardware upgrade or BIOS setting to enable 2.0 mode'
    Write-Output '        If firmware flagged        -> visit OEM support site for TPM firmware update'
    Write-Output '        If TPM locked out          -> wait for lockout to expire, then retry'
    Write-Output '        If TPM ready               -> run BL003 BLHardwarePrereqs to check other prerequisites'
    return
}

# ---------------------------------------------------------------
# Check 2: TPM Version
# ---------------------------------------------------------------
Write-Output '--- TPM Version ---'

$tpmVersion = ''
$tpmPpiVer  = ''

try {
    $wmiTpm = Get-CimInstance -Namespace 'ROOT\CIMv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
    if ($null -ne $wmiTpm) {
        $specVer = $wmiTpm.SpecVersion
        if (-not [string]::IsNullOrWhiteSpace($specVer)) {
            $specParts = $specVer -split ','
            $tpmVersion = $specParts[0].Trim()

            if ($tpmVersion -eq '2.0') {
                Write-Output '[OK]  TPM Specification Version'
                Write-Output "       Version: 2.0 (SpecVersion: $specVer). Meets modern Intune requirements."
            } elseif ($tpmVersion -eq '1.2') {
                Write-Output '[!]   TPM Specification Version'
                Write-Output "       Version: 1.2 (SpecVersion: $specVer)."
                Write-Output '       Intune compliance policies often require TPM 2.0.'
                Write-Output '       TPM 1.2 limits BitLocker to legacy modes and prevents silent encryption.'
                Write-Output '       Check if BIOS offers a 1.2-to-2.0 firmware switch (some hardware supports this).'
                $warnCount++
            } else {
                Write-Output '[i]   TPM Specification Version'
                Write-Output "       Version: $tpmVersion (SpecVersion: $specVer). Unexpected version."
            }
        } else {
            Write-Output '[i]   TPM Specification Version'
            Write-Output '       SpecVersion property is empty. Unable to determine TPM version from WMI.'
        }

        # PPI version
        $ppiVer = $wmiTpm.PhysicalPresenceVersionInfo
        if (-not [string]::IsNullOrWhiteSpace($ppiVer)) {
            $tpmPpiVer = $ppiVer
            Write-Output "[i]   Physical Presence Interface: $ppiVer"
        }
    } else {
        Write-Output '[i]   TPM Version'
        Write-Output '       Win32_Tpm WMI class returned no data. Unable to determine TPM version.'
    }
} catch {
    $verErr = $_.Exception.Message
    Write-Output '[i]   TPM Version'
    Write-Output "       Could not query Win32_Tpm WMI class: $verErr"
    Write-Output '       TPM version check unavailable.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Manufacturer & Firmware Vulnerability Check
# ---------------------------------------------------------------
Write-Output '--- TPM Manufacturer & Firmware ---'

$mfgId  = ''
$mfgVer = ''
$mfgVerFull = ''

if ($null -ne $tpmObj) {
    $mfgId  = $tpmObj.ManufacturerIdTxt
    $mfgVer = $tpmObj.ManufacturerVersion
    try {
        $mfgVerFull = $tpmObj.ManufacturerVersionFull20
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($mfgId)) {
    Write-Output '[i]   TPM Manufacturer'
    Write-Output '       ManufacturerIdTxt is empty. Unable to identify TPM vendor.'
    Write-Output '       Firmware vulnerability check skipped.'
} else {
    $vulnFound = $false
    $verForCheck = if (-not [string]::IsNullOrWhiteSpace($mfgVerFull)) { $mfgVerFull } else { $mfgVer }

    # --- Infineon ROCA (CVE-2017-15361) ---
    if ($mfgId -eq 'IFX') {
        # Parse version to check against vulnerable ranges
        # Affected: TPM 1.2 fw < 4.34 or < 6.43; TPM 2.0 fw < 7.63
        # We extract the major.minor from the version string
        $verParts = @()
        if (-not [string]::IsNullOrWhiteSpace($verForCheck)) {
            $verParts = $verForCheck -split '\.'
        }
        $verMajor = 0
        $verMinor = 0
        if ($verParts.Count -ge 1) {
            try { $verMajor = [int]$verParts[0] } catch { }
        }
        if ($verParts.Count -ge 2) {
            try { $verMinor = [int]$verParts[1] } catch { }
        }

        $isVulnerable = $false
        if ($tpmVersion -eq '1.2') {
            # TPM 1.2: vulnerable if major < 4, or (major 4, minor < 34), or (major 6, minor < 43)
            if ($verMajor -lt 4) { $isVulnerable = $true }
            elseif ($verMajor -eq 4 -and $verMinor -lt 34) { $isVulnerable = $true }
            elseif ($verMajor -eq 6 -and $verMinor -lt 43) { $isVulnerable = $true }
        } elseif ($tpmVersion -eq '2.0') {
            # TPM 2.0: vulnerable if major < 7, or (major 7, minor < 63)
            if ($verMajor -lt 7) { $isVulnerable = $true }
            elseif ($verMajor -eq 7 -and $verMinor -lt 63) { $isVulnerable = $true }
        }

        if ($isVulnerable) {
            $vulnFound = $true
            Write-Output '[!!]  Infineon TPM -- CVE-2017-15361 (ROCA Vulnerability)'
            Write-Output "       Manufacturer: $mfgId (Infineon). Firmware: $verForCheck."
            Write-Output '       This firmware has a known RSA key generation flaw. Private keys can be'
            Write-Output '       deduced from public keys via computational attack.'
            Write-Output '       BitLocker keys generated on this firmware may be compromised.'
            Write-Output '       ACTION: Visit OEM support site for a TPM firmware update immediately.'
            $issueCount++
        }
    }

    # --- STMicro TPM-FAIL (CVE-2019-16863) ---
    if ($mfgId -eq 'STM') {
        $verParts = @()
        if (-not [string]::IsNullOrWhiteSpace($verForCheck)) {
            $verParts = $verForCheck -split '\.'
        }
        $verMajor = 0
        $verMinor = 0
        if ($verParts.Count -ge 1) {
            try { $verMajor = [int]$verParts[0] } catch { }
        }
        if ($verParts.Count -ge 2) {
            try { $verMinor = [int]$verParts[1] } catch { }
        }

        $isVulnerable = $false
        # Vulnerable branches: 71.x (safe >= 71.16), 73.x (safe >= 73.20), 74.x (safe >= 74.20)
        if ($verMajor -eq 71 -and $verMinor -lt 16) { $isVulnerable = $true }
        elseif ($verMajor -eq 73 -and $verMinor -lt 20) { $isVulnerable = $true }
        elseif ($verMajor -eq 74 -and $verMinor -lt 20) { $isVulnerable = $true }

        if ($isVulnerable) {
            $vulnFound = $true
            Write-Output '[!!]  STMicro TPM -- CVE-2019-16863 (TPM-FAIL Vulnerability)'
            Write-Output "       Manufacturer: $mfgId (STMicroelectronics). Firmware: $verForCheck."
            Write-Output '       This firmware has an ECDSA side-channel timing attack vulnerability.'
            Write-Output '       Attackers can extract the ECDSA private key via side-channel analysis.'
            Write-Output '       ACTION: Visit OEM support site for a TPM firmware update immediately.'
            $issueCount++
        }
    }

    if (-not $vulnFound) {
        Write-Output "[i]   Manufacturer: $mfgId. Firmware: $verForCheck."
        Write-Output '       No known firmware vulnerabilities for this manufacturer/version combination.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Lockout State
# ---------------------------------------------------------------
Write-Output '--- Lockout State ---'

if ($null -ne $tpmObj) {
    $lockedOut    = $tpmObj.LockedOut
    $lockCount    = $tpmObj.LockoutCount
    $lockMax      = $tpmObj.LockoutMax
    $lockHealTime = $tpmObj.LockoutHealTime

    if ($lockedOut) {
        Write-Output '[!!]  TPM LOCKED OUT'
        Write-Output '       The TPM is currently refusing all authentication commands.'
        Write-Output "       LockoutCount: $lockCount of $lockMax max attempts."
        if ($null -ne $lockHealTime) {
            $healStr = $lockHealTime.ToString()
            if ($null -ne $lockCount -and $lockCount -gt 0) {
                # Calculate estimated heal duration
                # LockoutHealTime is a TimeSpan - time for count to decrement by 1
                try {
                    $totalHeal = [TimeSpan]::FromTicks($lockHealTime.Ticks * $lockCount)
                    $healHours = [Math]::Round($totalHeal.TotalHours, 1)
                    Write-Output "       Heal time per decrement: $healStr."
                    Write-Output "       Estimated total heal: $healHours hours of CONTINUOUS powered-on time."
                } catch {
                    Write-Output "       LockoutHealTime: $healStr."
                }
            } else {
                Write-Output "       LockoutHealTime: $healStr."
            }
        }
        Write-Output '       The heal timer requires continuous powered-on operation.'
        Write-Output '       Shutdowns, hibernation, and deep sleep pause the timer.'
        Write-Output '       No exact unlock time can be predicted.'
        Write-Output '       No native method exists to clear the lockout without the owner auth password'
        Write-Output '       (which modern Windows discards after provisioning).'
        $issueCount++
    } elseif ($null -ne $lockCount -and $lockCount -gt 0) {
        Write-Output '[!]   TPM Lockout Activity'
        Write-Output "       LockoutCount: $lockCount of $lockMax max. Not locked out, but failed attempts recorded."
        Write-Output '       Investigate what is causing repeated auth failures (PIN brute-force, malware, driver bug).'
        $warnCount++
    } else {
        $maxStr = if ($null -ne $lockMax) { $lockMax.ToString() } else { 'unknown' }
        Write-Output '[OK]  TPM Lockout'
        Write-Output "       Not locked out. LockoutCount: 0 of $maxStr max. No dictionary attack activity."
    }
} else {
    Write-Output '[i]   Lockout State'
    Write-Output '       Get-Tpm data unavailable. Unable to check lockout state.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Attestation & Provisioning Readiness
# ---------------------------------------------------------------
Write-Output '--- Attestation & Provisioning ---'

# 5a: TBS (TPM Base Services) service
$tbsSvc = $null
try {
    $tbsSvc = Get-Service -Name 'TBS' -ErrorAction Stop
} catch { }

if ($null -eq $tbsSvc) {
    if ($tpmOK) {
        # Get-Tpm succeeded, so TPM operations work despite missing service.
        # Common on virtual machines (e.g., VMware vTPM).
        Write-Output '[i]   TPM Base Services (TBS)'
        Write-Output '       TBS service not found as standalone SCM entry, but TPM operations succeeded.'
        Write-Output '       On some Windows builds the TBS runs as a kernel-managed driver. No action needed.'
    } else {
        Write-Output '[!!]  TPM Base Services (TBS)'
        Write-Output '       TBS service not found. TPM driver stack may be missing.'
        Write-Output '       All user-mode TPM access is impossible without this service.'
        $issueCount++
    }
} else {
    $tbsStatus = $tbsSvc.Status
    $tbsStart  = $tbsSvc.StartType
    if ($tbsStatus -eq 'Running') {
        Write-Output '[OK]  TPM Base Services (TBS)'
        Write-Output '       Service is running. TPM stack is operational.'
    } elseif ($tbsStart -eq 'Disabled') {
        Write-Output '[!!]  TPM Base Services (TBS)'
        Write-Output '       Service is DISABLED. No user-mode TPM access possible.'
        Write-Output '       Re-enable the TBS service and restart the machine.'
        $issueCount++
    } else {
        Write-Output '[!!]  TPM Base Services (TBS)'
        Write-Output "       Service status: $tbsStatus (StartType: $tbsStart)."
        Write-Output '       TBS must be running for TPM operations. Start the service or investigate why it stopped.'
        $issueCount++
    }
}

# 5b: Auto-Provisioning (already partially covered in Check 1 for TpmOwned=false)
if ($null -ne $tpmObj -and -not $tpmObj.TpmOwned) {
    # Already reported in Check 1
    Write-Output '[i]   Auto-Provisioning'
    Write-Output '       See TPM Ownership check above for auto-provisioning details.'
} elseif ($null -ne $tpmObj -and $tpmObj.TpmOwned) {
    Write-Output '[OK]  Auto-Provisioning'
    Write-Output '       TPM is owned. Provisioning was successful.'
}

# 5c: Owner Auth Retention level
$tpmPolPath = 'HKLM:\SOFTWARE\Policies\Microsoft\TPM'
$osManagedAuthLevel = $null
try {
    $tpmPolReg = Get-ItemProperty -Path $tpmPolPath -ErrorAction Stop
    if ($null -ne $tpmPolReg) {
        $osManagedAuthLevel = $tpmPolReg.OSManagedAuthLevel
    }
} catch { }

if ($null -ne $osManagedAuthLevel) {
    $authDesc = switch ([int]$osManagedAuthLevel) {
        0 { 'None -- OS stores no owner authorization data. No programmatic TPM clear/reset possible.' }
        2 { 'Delegated -- OS stores admin and user delegation blobs only. Partial programmatic control.' }
        4 { 'Full -- OS retains the full TPM owner authorization password. Full programmatic TPM management available.' }
        5 { 'Default (modern) -- Retains lockout auth, discards full owner. Cannot clear TPM programmatically.' }
        default { "Unknown value: $osManagedAuthLevel" }
    }
    Write-Output '[i]   Owner Auth Retention'
    Write-Output "       OSManagedAuthLevel: $osManagedAuthLevel. $authDesc"
    if ([int]$osManagedAuthLevel -ne 4) {
        Write-Output '       A TPM clear requires physical presence (reboot + BIOS key press).'
    }
} else {
    Write-Output '[i]   Owner Auth Retention'
    Write-Output '       OSManagedAuthLevel not configured by policy. Modern Windows default applies.'
    Write-Output '       Retains lockout auth, discards full owner auth after provisioning.'
    Write-Output '       A TPM clear requires physical presence (reboot + BIOS key press).'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. TPM is healthy and ready for BitLocker.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. TPM is functional but review the flagged items."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. TPM needs attention."
}

Write-Output ''
Write-Output 'NEXT:   If TPM not present         -> check BIOS settings (often disabled by default)'
Write-Output '        If TPM 1.2                 -> may need hardware upgrade or BIOS setting to enable 2.0 mode'
Write-Output '        If firmware flagged        -> visit OEM support site for TPM firmware update'
Write-Output '        If TPM locked out          -> wait for lockout to expire, then retry'
Write-Output '        If TPM ready               -> run BL003 BLHardwarePrereqs to check other prerequisites'
