# BL009_BLTpmRemediation.ps1
# Scriptlet: BL009 - TPM & Key Protector Remediation
# Context: System | Version: 1.1

$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== TPM & Key Protector Remediation ==='

# ============================================================
# Step 0 -- Parameter Parsing & Mode Selection
# ============================================================
$mode = if ($Param1) { $Param1.Trim() } else { 'Auto' }
$validModes = @('Auto', 'DecryptFirst', 'ClearTPM')
if ($validModes -notcontains $mode) {
    Write-Output ''
    Write-Output "[ERR] Invalid mode '$mode'. Valid modes: Auto, DecryptFirst, ClearTPM."
    Write-Output '       Defaulting to Auto.'
    $mode = 'Auto'
}

# Define which steps run in each mode
$doCleanProtectors = ($mode -eq 'Auto' -or $mode -eq 'DecryptFirst' -or $mode -eq 'ClearTPM')
$doHandleSuspended = $true  # All modes
$doDecryptFirst    = ($mode -eq 'DecryptFirst')
$doTpmInit         = ($mode -eq 'Auto' -or $mode -eq 'ClearTPM')
$doTpmClear        = ($mode -eq 'ClearTPM')
$doGenerateKey     = ($mode -eq 'Auto' -or $mode -eq 'ClearTPM')
$doEscrow          = ($mode -eq 'Auto' -or $mode -eq 'ClearTPM')

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
}

# TPM state
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $preState.TpmPresent        = $tpm.TpmPresent
    $preState.TpmReady          = $tpm.TpmReady
    $preState.TpmOwned          = $tpm.TpmOwned
    $preState.TpmEnabled        = $tpm.TpmEnabled
    $preState.TpmActivated      = $tpm.TpmActivated
    $preState.LockedOut         = $tpm.LockedOut
    $preState.ManagedAuthLevel  = if ($tpm.ManagedAuthLevel) { $tpm.ManagedAuthLevel.ToString() } else { 'Unknown' }
} catch {
    $preState.TpmError = $_.Exception.Message
}

# TPM spec version and manufacturer (WMI)
try {
    $tpmWmi = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
    if ($tpmWmi) {
        $preState.TpmSpecVersion       = if ($tpmWmi.SpecVersion) { $tpmWmi.SpecVersion } else { 'Unknown' }
        $preState.TpmManufacturerVersion = if ($tpmWmi.ManufacturerVersion) { $tpmWmi.ManufacturerVersion } else { 'Unknown' }
    }
} catch {
    $preState.TpmWmiError = $_.Exception.Message
}

# BitLocker volume state
try {
    $blVol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    $preState.ProtectionStatus    = if ($blVol.ProtectionStatus) { $blVol.ProtectionStatus.ToString() } else { 'Unknown' }
    $preState.VolumeStatus        = if ($blVol.VolumeStatus) { $blVol.VolumeStatus.ToString() } else { 'Unknown' }
    $preState.EncryptionPercentage = $blVol.EncryptionPercentage
    $preState.EncryptionMethod    = if ($blVol.EncryptionMethod) { $blVol.EncryptionMethod.ToString() } else { 'Unknown' }
    $preState.KeyProtectorCount   = @($blVol.KeyProtector).Count

    # Capture protector details
    $protectorList = @()
    foreach ($kp in $blVol.KeyProtector) {
        $protectorList += @{
            Type = if ($kp.KeyProtectorType) { $kp.KeyProtectorType.ToString() } else { 'Unknown' }
            Id   = $kp.KeyProtectorId
        }
    }
    $preState.KeyProtectors = $protectorList
} catch {
    $preState.BitLockerError = $_.Exception.Message
}

# Service states
$svcNames = @('bdesvc', 'tbs', 'KeyIso')
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

# OEM manufacturer (for TPM physical presence warnings)
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $preState.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer } else { 'Unknown' }
    $preState.Model        = if ($cs.Model) { $cs.Model } else { 'Unknown' }
} catch {
    $preState.Manufacturer = 'Unknown'
    $preState.Model        = 'Unknown'
}

# Save pre-state
$preStatePath = Join-Path -Path $logDir -ChildPath "BL009_PreState_$ts.json"
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
# Step 2 -- Service Dependency Validation (all modes)
# ============================================================
Write-Output ''
Write-Output '--- Step 2: Service Dependency Validation ---'

$requiredServices = @(
    @{ Name = 'bdesvc';  Display = 'BitLocker Drive Encryption Service' },
    @{ Name = 'tbs';     Display = 'TPM Base Services' },
    @{ Name = 'KeyIso';  Display = 'CNG Key Isolation' }
)

$serviceBlocker = $false

foreach ($rs in $requiredServices) {
    $svcName = $rs.Name
    $svcDisplay = $rs.Display
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            $findings.Add([PSCustomObject]@{
                Check  = "Service: $svcDisplay"
                Status = 'OK'
                Detail = "$svcName is running."
            })
        } elseif ($svc.Status -eq 'Stopped') {
            # Attempt to start
            try {
                if ($svc.StartType -eq 'Disabled') {
                    # Re-enable first
                    Set-Service -Name $svcName -StartupType Manual -ErrorAction Stop
                    $findings.Add([PSCustomObject]@{
                        Check  = "Service: $svcDisplay"
                        Status = 'INFO'
                        Detail = "$svcName was Disabled. Re-enabled to Manual."
                    })
                }
                Start-Service -Name $svcName -ErrorAction Stop
                Start-Sleep -Seconds 2
                $svc.Refresh()
                if ($svc.Status -eq 'Running') {
                    $findings.Add([PSCustomObject]@{
                        Check  = "Service: $svcDisplay"
                        Status = 'OK'
                        Detail = "$svcName was stopped. Successfully started."
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = "Service: $svcDisplay"
                        Status = 'ISSUE'
                        Detail = "$svcName could not be started. Status: $($svc.Status). BitLocker operations will fail."
                    })
                    $serviceBlocker = $true
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = "Service: $svcDisplay"
                    Status = 'ISSUE'
                    Detail = "$svcName start failed: $($_.Exception.Message). BitLocker operations will fail."
                })
                $serviceBlocker = $true
            }
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Service: $svcDisplay"
                Status = 'WARN'
                Detail = "$svcName status: $($svc.Status). Expected: Running."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = "Service: $svcDisplay"
            Status = 'ISSUE'
            Detail = "$svcName service not found. BitLocker subsystem may be damaged."
        })
        $serviceBlocker = $true
    }
}

if ($serviceBlocker) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Service Validation'
        Status = 'ISSUE'
        Detail = 'Critical service(s) are not running. Remediation steps may fail. Run BL008 BLReadinessCheck for deeper diagnostics.'
    })
}

# ============================================================
# Step 3 -- Stale Key Protector Identification (deferred deletion)
# ============================================================
# SAFETY: Never delete old recovery keys until a new key is generated
# and escrowed. If the new key generation or escrow fails, the old
# keys are the only recovery path. Actual deletion happens in Step 6
# AFTER the new key is confirmed.
$staleProtectorIds = [System.Collections.Generic.List[string]]::new()

if ($doCleanProtectors) {
    Write-Output ''
    Write-Output '--- Step 3: Stale Key Protector Scan ---'

    try {
        $blVol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $protectors = $blVol.KeyProtector

        # Find all RecoveryPassword protectors
        $rpProtectors = @($protectors | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        $otherProtectors = @($protectors | Where-Object { $_.KeyProtectorType -ne 'RecoveryPassword' })

        if ($rpProtectors.Count -eq 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Stale Protector Scan'
                Status = 'INFO'
                Detail = 'No RecoveryPassword protectors found. Nothing to clean.'
            })
        } elseif ($rpProtectors.Count -eq 1) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Stale Protector Scan'
                Status = 'INFO'
                Detail = '1 RecoveryPassword protector found. Tagged for removal after new key is generated and escrowed in Step 6.'
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Stale Protector Scan'
                Status = 'WARN'
                Detail = "$($rpProtectors.Count) RecoveryPassword protectors found. Multiple protectors indicate stale/orphaned keys. Tagged for removal after new key is generated and escrowed in Step 6."
            })
        }

        # Tag protector IDs for deferred deletion -- do NOT delete yet
        foreach ($rp in $rpProtectors) {
            $staleProtectorIds.Add($rp.KeyProtectorId)
            $truncId = if ($rp.KeyProtectorId.Length -gt 12) { $rp.KeyProtectorId.Substring(0, 12) + '...' } else { $rp.KeyProtectorId }
            $findings.Add([PSCustomObject]@{
                Check  = "Tagged: RecoveryPassword $truncId"
                Status = 'INFO'
                Detail = 'Marked for deferred removal. Will be deleted only after new key is confirmed.'
            })
        }

        if ($rpProtectors.Count -gt 0) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Protector Scan Summary'
                Status = 'INFO'
                Detail = "$($rpProtectors.Count) RecoveryPassword protector(s) tagged for deferred removal. $($otherProtectors.Count) non-recovery protector(s) preserved (TPM, TpmPin, etc.)."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'Stale Protector Scan'
            Status = 'ERROR'
            Detail = "Could not query BitLocker volume: $($_.Exception.Message). Run BL001 BLStatusSnapshot for diagnostics."
        })
    }
}

# ============================================================
# Step 4 -- Handle Suspended/Broken BitLocker
# ============================================================
if ($doHandleSuspended) {
    Write-Output ''
    Write-Output '--- Step 4: Handle Suspended/Broken BitLocker ---'

    try {
        $blVol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $protStatus = $blVol.ProtectionStatus.ToString()
        $volStatus  = $blVol.VolumeStatus.ToString()
        $encPct     = $blVol.EncryptionPercentage

        # Hard stop: locked volumes cannot be remediated
        if ($blVol.LockStatus -eq 'Locked' -or $volStatus -eq 'Locked') {
            $findings.Add([PSCustomObject]@{
                Check  = 'BitLocker State'
                Status = 'ISSUE'
                Detail = 'Volume C: is Locked. Unlock the volume first using: manage-bde -unlock C: -RecoveryPassword <key>. Remediation cannot proceed on a locked volume.'
            })
        } elseif ($doDecryptFirst) {
            # DecryptFirst mode: force full decryption regardless of state
            if ($volStatus -eq 'FullyDecrypted') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Decryption'
                    Status = 'OK'
                    Detail = 'Volume is already fully decrypted. No action needed.'
                })
            } elseif ($volStatus -eq 'DecryptionInProgress') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Decryption'
                    Status = 'INFO'
                    Detail = "Decryption already in progress. $encPct% encrypted. Wait for completion, then re-run BL009 in Auto mode."
                })
            } else {
                # Initiate decryption
                try {
                    Disable-BitLocker -MountPoint 'C:' -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $blVol2 = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Decryption'
                        Status = 'OK'
                        Detail = "Decryption initiated. Currently $($blVol2.EncryptionPercentage)% encrypted. This may take hours on large drives. Re-run BL009 in Auto mode after decryption completes."
                    })
                } catch {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Decryption'
                        Status = 'ISSUE'
                        Detail = "Decryption failed: $($_.Exception.Message). The volume may be locked or a policy is preventing decryption."
                    })
                }
            }
        } else {
            # Auto/ClearTPM mode: handle suspended state
            if ($protStatus -eq 'Off' -and $volStatus -eq 'FullyEncrypted') {
                # Ghost suspended state: encrypted but protection off
                # Check if we have a TPM protector
                $hasTpmProtector = $false
                foreach ($kp in $blVol.KeyProtector) {
                    if ($kp.KeyProtectorType -eq 'Tpm' -or $kp.KeyProtectorType -eq 'TpmPin' -or $kp.KeyProtectorType -eq 'TpmStartupKey' -or $kp.KeyProtectorType -eq 'TpmPinStartupKey') {
                        $hasTpmProtector = $true
                        break
                    }
                }

                if ($hasTpmProtector) {
                    # TPM protector exists -- try to resume
                    try {
                        Resume-BitLocker -MountPoint 'C:' -ErrorAction Stop
                        Start-Sleep -Seconds 2
                        $blVol2 = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                        if ($blVol2.ProtectionStatus.ToString() -eq 'On') {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'OK'
                                Detail = 'BitLocker was suspended (encrypted but protection off). Successfully resumed. Protection is now On.'
                            })
                        } else {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'WARN'
                                Detail = "Resume-BitLocker executed but protection status is still $($blVol2.ProtectionStatus). A policy or TPM issue may be preventing activation."
                            })
                        }
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Resume BitLocker'
                            Status = 'ISSUE'
                            Detail = "Could not resume BitLocker: $($_.Exception.Message). Run BL007 BLEventAnalysis for the failure reason."
                        })
                    }
                } else {
                    # No TPM protector -- must add one before resuming
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Suspended State'
                        Status = 'WARN'
                        Detail = 'BitLocker is suspended (encrypted, protection off) with no TPM protector. Adding TPM protector before attempting resume.'
                    })
                    try {
                        Add-BitLockerKeyProtector -MountPoint 'C:' -TpmProtector -ErrorAction Stop
                        Start-Sleep -Seconds 2
                        Resume-BitLocker -MountPoint 'C:' -ErrorAction Stop
                        Start-Sleep -Seconds 2
                        $blVol2 = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                        if ($blVol2.ProtectionStatus.ToString() -eq 'On') {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'OK'
                                Detail = 'TPM protector added and BitLocker resumed. Protection is now On.'
                            })
                        } else {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'WARN'
                                Detail = "TPM protector added but protection status is still $($blVol2.ProtectionStatus). Check TPM health with BL002 BLTpmHealth."
                            })
                        }
                    } catch {
                        $errDetail = $_.Exception.Message
                        # Detect GPO/MDM policy requiring TPM+PIN
                        if ($errDetail -match 'policy|Group Policy|PIN|startup authentication') {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'ISSUE'
                                Detail = "Failed to add TPM-only protector: $errDetail. A Group Policy or Intune profile likely requires TPM+PIN (TpmPin protector). The user must set a PIN manually before BitLocker can be resumed. Use: manage-bde -protectors -add C: -TPMAndPIN"
                            })
                        } else {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'Resume BitLocker'
                                Status = 'ISSUE'
                                Detail = "Failed to add TPM protector or resume: $errDetail. TPM may not be ready. Run BL002 BLTpmHealth."
                            })
                        }
                    }
                }
            } elseif ($volStatus -eq 'EncryptionInProgress') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'INFO'
                    Detail = "Encryption in progress ($encPct% complete). Do not interrupt. Wait for completion."
                })
            } elseif ($volStatus -eq 'DecryptionInProgress') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'INFO'
                    Detail = "Decryption in progress ($encPct% encrypted). Wait for completion, then re-run BL009 in Auto mode."
                })
            } elseif ($volStatus -eq 'EncryptionSuspended' -or $volStatus -eq 'EncryptionPaused') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'WARN'
                    Detail = "Encryption is paused/suspended at $encPct%. This may indicate disk errors or a failed firmware update. Consider running BL009 in DecryptFirst mode to start fresh."
                })
            } elseif ($protStatus -eq 'On' -and $volStatus -eq 'FullyEncrypted') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'OK'
                    Detail = 'BitLocker is fully encrypted and protection is On. Volume is healthy.'
                })
            } elseif ($volStatus -eq 'FullyDecrypted') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'INFO'
                    Detail = 'Volume is fully decrypted. No suspended state to handle. Use BL010 BLForceEncrypt to enable BitLocker.'
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'BitLocker State'
                    Status = 'INFO'
                    Detail = "Volume state: $volStatus, Protection: $protStatus, Encrypted: $encPct%."
                })
            }
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'BitLocker State'
            Status = 'ERROR'
            Detail = "Could not query BitLocker volume: $($_.Exception.Message). Run BL001 BLStatusSnapshot for diagnostics."
        })
    }
}

# ============================================================
# Step 5 -- TPM Re-initialization
# ============================================================
if ($doTpmInit) {
    Write-Output ''
    Write-Output '--- Step 5: TPM Re-initialization ---'

    try {
        $tpm = Get-Tpm -ErrorAction Stop

        if ($doTpmClear) {
            # ClearTPM mode: destructive TPM clear
            # Warn about OEM-specific physical presence requirements
            $mfr = if ($preState.Manufacturer) { $preState.Manufacturer } else { 'Unknown' }
            $mfrLower = $mfr.ToLower()

            if ($mfrLower -match 'lenovo') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM Clear (OEM Warning)'
                    Status = 'WARN'
                    Detail = "Manufacturer: $mfr. Lenovo systems frequently require physical presence confirmation (F9/F12) at next boot. An unattended remote endpoint will hang at the pre-boot screen. Ensure a user is present to confirm, or pre-configure the BIOS to bypass physical presence."
                })
            } elseif ($mfrLower -match 'dell') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM Clear (OEM Warning)'
                    Status = 'INFO'
                    Detail = "Manufacturer: $mfr. Many Dell enterprise models support Physical Presence Bypass via Dell Command | Configure. Check BIOS settings before rebooting."
                })
            } elseif ($mfrLower -match 'hp\b|hewlett') {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM Clear (OEM Warning)'
                    Status = 'INFO'
                    Detail = "Manufacturer: $mfr. HP enterprise systems may support Physical Presence Bypass. Check BIOS settings before rebooting."
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM Clear (OEM Warning)'
                    Status = 'INFO'
                    Detail = "Manufacturer: $mfr. Physical presence confirmation may be required at next boot for TPM clear. Ensure a user is present to confirm."
                })
            }

            # If BitLocker is currently protecting the volume, suspend first
            # to prevent boot lockout after TPM clear
            try {
                $blVolCheck = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                if ($blVolCheck.ProtectionStatus.ToString() -eq 'On') {
                    # RebootCount 0 = suspend indefinitely. TPM clear causes a
                    # double-reboot cycle: (1) BIOS physical presence prompt,
                    # (2) OS load. RebootCount 1 would re-arm after the BIOS
                    # reboot, locking the user out on the OS boot because the
                    # TPM was just wiped and has no sealed keys.
                    Suspend-BitLocker -MountPoint 'C:' -RebootCount 0 -ErrorAction Stop
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Pre-Clear: Suspend BitLocker'
                        Status = 'OK'
                        Detail = 'BitLocker protection suspended indefinitely to survive multi-reboot TPM clear cycle. Re-run BL009 in Auto mode after reboot to re-arm protection.'
                    })
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Pre-Clear: Suspend BitLocker'
                    Status = 'WARN'
                    Detail = "Could not suspend BitLocker before TPM clear: $($_.Exception.Message). Proceed with caution -- boot lockout is possible."
                })
            }

            # Execute TPM clear
            try {
                $clearResult = Clear-Tpm -ErrorAction Stop
                if ($clearResult.RestartRequired) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Clear'
                        Status = 'OK'
                        Detail = 'TPM clear command accepted. A REBOOT IS REQUIRED to complete the clear. After reboot, re-run BL009 in Auto mode to re-initialize.'
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Clear'
                        Status = 'OK'
                        Detail = 'TPM clear completed (no reboot required). Proceeding to re-initialization.'
                    })
                }
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match '80090016|NTE_BAD_KEYSET') {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Clear'
                        Status = 'WARN'
                        Detail = "TPM clear returned NTE_BAD_KEYSET (0x80090016). This typically indicates a motherboard replacement. The TPM ownership data is stale. A BIOS-level TPM clear or firmware reset may be required. Also purge C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc after clear."
                    })
                } elseif ($errMsg -match '80284010|TBS_E_SERVICE_DISABLED') {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Clear'
                        Status = 'ISSUE'
                        Detail = "TPM Base Services (tbs) is disabled (0x80284010). Re-enable the tbs service and retry."
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Clear'
                        Status = 'ISSUE'
                        Detail = "TPM clear failed: $errMsg. A BIOS-level clear may be required. Check OEM documentation."
                    })
                }
            }

            # Attempt re-initialization after clear (may need reboot first)
            try {
                $initResult = Initialize-Tpm -ErrorAction Stop
                if ($initResult.TpmReady) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Initialize'
                        Status = 'OK'
                        Detail = 'TPM re-initialized successfully. TpmReady: True.'
                    })
                } else {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Initialize'
                        Status = 'INFO'
                        Detail = "TPM initialization deferred. TpmReady: $($initResult.TpmReady). A reboot is likely required to complete initialization."
                    })
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM Initialize'
                    Status = 'INFO'
                    Detail = "TPM initialization could not complete now: $($_.Exception.Message). This is expected if a reboot is pending for TPM clear."
                })
            }
        } else {
            # Auto mode: only initialize if needed
            if ($tpm.TpmPresent -eq $true -and $tpm.TpmReady -eq $false) {
                # TPM present but not ready -- try Initialize-Tpm
                if ($tpm.LockedOut -eq $true) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'TPM Lockout'
                        Status = 'ISSUE'
                        Detail = 'TPM is locked out due to excessive failed authorization attempts. Wait for lockout to expire before retrying. Run BL002 BLTpmHealth for lockout timer details.'
                    })
                } else {
                    try {
                        $initResult = Initialize-Tpm -ErrorAction Stop
                        if ($initResult.TpmReady) {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'TPM Initialize'
                                Status = 'OK'
                                Detail = 'TPM was not ready. Successfully initialized. TpmReady: True.'
                            })
                        } else {
                            $findings.Add([PSCustomObject]@{
                                Check  = 'TPM Initialize'
                                Status = 'WARN'
                                Detail = "Initialize-Tpm completed but TpmReady is still False. A reboot or BIOS configuration may be required. Run BL002 BLTpmHealth for details."
                            })
                        }
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'TPM Initialize'
                            Status = 'ISSUE'
                            Detail = "Initialize-Tpm failed: $($_.Exception.Message). Consider running BL009 in ClearTPM mode if the TPM is in a corrupt state."
                        })
                    }
                }
            } elseif ($tpm.TpmPresent -eq $true -and $tpm.TpmReady -eq $true) {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM State'
                    Status = 'OK'
                    Detail = 'TPM is present and ready. No re-initialization needed.'
                })
            } elseif ($tpm.TpmPresent -eq $false) {
                $findings.Add([PSCustomObject]@{
                    Check  = 'TPM State'
                    Status = 'ISSUE'
                    Detail = 'TPM is not present. BitLocker TPM-based encryption is not possible. Check BIOS settings to enable TPM.'
                })
            }
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'TPM Query'
            Status = 'ERROR'
            Detail = "Could not query TPM state: $($_.Exception.Message). TrustedPlatformModule module may not be available."
        })
    }
}

# ============================================================
# Step 6 -- Generate New Recovery Password & Escrow
# ============================================================
if ($doGenerateKey) {
    Write-Output ''
    Write-Output '--- Step 6: Generate New Recovery Password & Escrow ---'

    # Check if the volume is in a state where we can add protectors
    $canAddProtector = $false
    try {
        $blVol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $volStatus = $blVol.VolumeStatus.ToString()
        if ($volStatus -eq 'FullyEncrypted' -or $volStatus -eq 'EncryptionInProgress') {
            $canAddProtector = $true
        } elseif ($volStatus -eq 'FullyDecrypted') {
            $findings.Add([PSCustomObject]@{
                Check  = 'New Recovery Password'
                Status = 'INFO'
                Detail = 'Volume is fully decrypted. Recovery password generation requires an encrypted volume. Use BL010 BLForceEncrypt to enable BitLocker first.'
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'New Recovery Password'
                Status = 'INFO'
                Detail = "Volume status is $volStatus. Cannot add recovery password protector in this state."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'New Recovery Password'
            Status = 'ERROR'
            Detail = "Could not query BitLocker volume: $($_.Exception.Message)"
        })
    }

    if ($canAddProtector) {
        # Generate new RecoveryPassword
        $newProtectorId = $null
        try {
            $addResult = Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector -ErrorAction Stop
            # Get the newly added protector ID
            $blVol2 = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            $rpProtectors = @($blVol2.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
            if ($rpProtectors.Count -gt 0) {
                # The last RecoveryPassword protector is likely the one we just added
                $newProtector = $rpProtectors[$rpProtectors.Count - 1]
                $newProtectorId = $newProtector.KeyProtectorId
                $rpValue = $newProtector.RecoveryPassword
                # Show first 6 digits for verification, mask the rest
                $masked = if ($rpValue -and $rpValue.Length -gt 6) {
                    $rpValue.Substring(0, 6) + '-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX'
                } else {
                    '(could not retrieve)'
                }
                $findings.Add([PSCustomObject]@{
                    Check  = 'New Recovery Password'
                    Status = 'OK'
                    Detail = "New recovery password generated. ID: $newProtectorId. Key: $masked"
                })
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'New Recovery Password'
                    Status = 'WARN'
                    Detail = 'Add-BitLockerKeyProtector completed but no RecoveryPassword protector found on re-query.'
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Check  = 'New Recovery Password'
                Status = 'ISSUE'
                Detail = "Failed to add recovery password: $($_.Exception.Message). A Group Policy or MDM conflict may be blocking protector addition. Run BL006 BLPolicyConflict."
            })
        }

        # Attempt escrow if we have a new protector ID
        $escrowConfirmed = $false
        if ($doEscrow -and $newProtectorId) {
            # Pre-check: device registration state via dsregcmd
            $isAadJoined = $false
            $isHybridJoined = $false
            $isDomainJoined = $false
            $prtValid = $false

            try {
                $dsregOutput = & dsregcmd.exe /status 2>&1 | Out-String
                if ($dsregOutput -match 'AzureAdJoined\s*:\s*YES') {
                    $isAadJoined = $true
                }
                if ($dsregOutput -match 'DomainJoined\s*:\s*YES') {
                    $isDomainJoined = $true
                }
                if ($isAadJoined -and $isDomainJoined) {
                    $isHybridJoined = $true
                }
                if ($dsregOutput -match 'AzureAdPrt\s*:\s*YES') {
                    $prtValid = $true
                }

                $joinType = if ($isHybridJoined) { 'Hybrid Azure AD Joined' }
                            elseif ($isAadJoined) { 'Azure AD Joined' }
                            elseif ($isDomainJoined) { 'Domain Joined (on-prem only)' }
                            else { 'Not joined' }

                $findings.Add([PSCustomObject]@{
                    Check  = 'Device Registration'
                    Status = if ($isAadJoined) { 'OK' } else { 'WARN' }
                    Detail = "Device join type: $joinType. PRT valid: $prtValid."
                })
            } catch {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Device Registration'
                    Status = 'WARN'
                    Detail = "Could not run dsregcmd: $($_.Exception.Message). Escrow may fail."
                })
            }

            # Attempt Entra ID (AAD) escrow
            if ($isAadJoined) {
                try {
                    BackupToAAD-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $newProtectorId -ErrorAction Stop
                    # Check for Event ID 845 as definitive confirmation
                    $escrowEvent = $null
                    Start-Sleep -Seconds 5
                    try {
                        $escrowEvent = Get-WinEvent -FilterHashtable @{
                            LogName   = 'Microsoft-Windows-BitLocker/BitLocker Management'
                            Id        = 845
                        } -MaxEvents 1 -ErrorAction Stop
                    } catch { }

                    if ($escrowEvent) {
                        $escrowConfirmed = $true
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Entra ID Escrow'
                            Status = 'OK'
                            Detail = "Recovery key escrowed to Entra ID successfully. Event ID 845 confirmed at $($escrowEvent.TimeCreated)."
                        })
                    } else {
                        # BackupToAAD returned success but no event yet -- treat as likely success
                        $escrowConfirmed = $true
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Entra ID Escrow'
                            Status = 'OK'
                            Detail = 'BackupToAAD completed without error. Event ID 845 not yet logged -- escrow may still be processing. Verify in Entra ID portal.'
                        })
                    }
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match '845' -or $errMsg -match 'quota') {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Entra ID Escrow'
                            Status = 'ISSUE'
                            Detail = "Escrow failed (possible 200-key quota hit): $errMsg. Stale keys must be cleaned from the Entra ID device object via the admin portal."
                        })
                    } else {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Entra ID Escrow'
                            Status = 'ISSUE'
                            Detail = "Escrow to Entra ID failed: $errMsg. Check network connectivity to login.microsoftonline.com and graph.microsoft.com. Run BL005 BLEscrowCheck for diagnostics."
                        })
                    }
                }
            } elseif ($isDomainJoined) {
                # On-prem domain joined: try AD DS escrow
                try {
                    Backup-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $newProtectorId -ErrorAction Stop
                    $escrowConfirmed = $true
                    $findings.Add([PSCustomObject]@{
                        Check  = 'AD DS Escrow'
                        Status = 'OK'
                        Detail = 'Recovery key backed up to Active Directory Domain Services successfully.'
                    })
                } catch {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'AD DS Escrow'
                        Status = 'WARN'
                        Detail = "AD DS escrow failed: $($_.Exception.Message). The domain controller may not be reachable, or BitLocker AD backup policy is not configured."
                    })
                }
            } else {
                # Not joined to any directory -- key exists locally only
                $findings.Add([PSCustomObject]@{
                    Check  = 'Key Escrow'
                    Status = 'WARN'
                    Detail = 'Device is not joined to Azure AD or on-premises Active Directory. Automatic escrow is not available. The recovery password was generated locally. Ensure it is stored securely.'
                })
                # Show full recovery password for non-joined devices since no escrow is possible
                try {
                    $blVol3 = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                    $rpProt = @($blVol3.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $_.KeyProtectorId -eq $newProtectorId })
                    if ($rpProt.Count -gt 0 -and $rpProt[0].RecoveryPassword) {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Recovery Password (Non-Escrowed)'
                            Status = 'INFO'
                            Detail = "IMPORTANT -- Store this recovery password securely: $($rpProt[0].RecoveryPassword)"
                        })
                    }
                } catch { }
                # For non-joined devices, the new key is the only key -- safe to clean stale
                $escrowConfirmed = $true
            }
        }

        # ---- Deferred stale protector deletion (Golden Rule) ----
        # Only delete old recovery keys AFTER the new key is generated and
        # escrow is confirmed. If escrow failed, old keys are the only
        # recovery path and must be preserved.
        if ($newProtectorId -and $staleProtectorIds.Count -gt 0) {
            if ($escrowConfirmed) {
                $removedCount = 0
                foreach ($oldId in $staleProtectorIds) {
                    # Skip if the old ID is the same as the new one (shouldn't happen, but guard)
                    if ($oldId -eq $newProtectorId) { continue }
                    try {
                        Remove-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $oldId -ErrorAction Stop
                        $removedCount++
                        $truncId = if ($oldId.Length -gt 12) { $oldId.Substring(0, 12) + '...' } else { $oldId }
                        $findings.Add([PSCustomObject]@{
                            Check  = "Cleanup: Old RecoveryPassword $truncId"
                            Status = 'OK'
                            Detail = 'Stale protector removed. New key is generated and escrowed.'
                        })
                    } catch {
                        $findings.Add([PSCustomObject]@{
                            Check  = 'Cleanup: Old RecoveryPassword'
                            Status = 'WARN'
                            Detail = "Could not remove stale protector $oldId : $($_.Exception.Message)"
                        })
                    }
                }
                if ($removedCount -gt 0) {
                    $findings.Add([PSCustomObject]@{
                        Check  = 'Stale Protector Cleanup'
                        Status = 'OK'
                        Detail = "$removedCount stale RecoveryPassword protector(s) removed after new key was confirmed."
                    })
                }
            } else {
                $findings.Add([PSCustomObject]@{
                    Check  = 'Stale Protector Cleanup'
                    Status = 'WARN'
                    Detail = "$($staleProtectorIds.Count) stale protector(s) were NOT removed because escrow could not be confirmed. Old keys are preserved as the only recovery path. Resolve escrow issues and re-run BL009."
                })
            }
        }
    }
}

# ============================================================
# Step 7 -- Post-Remediation Verification
# ============================================================
Write-Output ''
Write-Output '--- Step 7: Post-Remediation Verification ---'

# Re-check TPM
try {
    $postTpm = Get-Tpm -ErrorAction Stop
    if ($postTpm.TpmPresent -eq $true -and $postTpm.TpmReady -eq $true) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: TPM State'
            Status = 'OK'
            Detail = "TPM is present and ready. Owned: $($postTpm.TpmOwned)."
        })
    } elseif ($postTpm.TpmPresent -eq $true -and $postTpm.TpmReady -eq $false) {
        $wasReady = if ($preState.TpmReady) { $preState.TpmReady } else { 'Unknown' }
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: TPM State'
            Status = 'WARN'
            Detail = "TPM present but not ready (was: $wasReady). A reboot may be required to complete initialization."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Verify: TPM State'
            Status = 'ISSUE'
            Detail = "TPM not present. Was present before: $($preState.TpmPresent)."
        })
    }
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Verify: TPM State'
        Status = 'WARN'
        Detail = "Could not query post-remediation TPM state: $($_.Exception.Message)"
    })
}

# Re-check BitLocker
try {
    $postBl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    $postProtStatus = $postBl.ProtectionStatus.ToString()
    $postVolStatus  = $postBl.VolumeStatus.ToString()
    $postProtectors = @($postBl.KeyProtector)
    $postRpCount    = @($postProtectors | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count

    $findings.Add([PSCustomObject]@{
        Check  = 'Verify: BitLocker Volume'
        Status = if ($postVolStatus -eq 'FullyEncrypted' -and $postProtStatus -eq 'On') { 'OK' } else { 'INFO' }
        Detail = "Volume: $postVolStatus. Protection: $postProtStatus. Protectors: $($postProtectors.Count) total ($postRpCount RecoveryPassword)."
    })
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Verify: BitLocker Volume'
        Status = 'WARN'
        Detail = "Could not query post-remediation BitLocker state: $($_.Exception.Message)"
    })
}

# Re-check services
foreach ($rs in $requiredServices) {
    $svcName = $rs.Name
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

# Check for pending reboot
$rebootPending = $false
try {
    $cbsReboot = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing' -Name 'RebootPending' -ErrorAction Stop
    if ($cbsReboot) { $rebootPending = $true }
} catch { }
try {
    $wuReboot = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' -Name 'RebootRequired' -ErrorAction Stop
    if ($wuReboot) { $rebootPending = $true }
} catch { }

if ($rebootPending -or $doTpmClear) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Reboot Status'
        Status = 'WARN'
        Detail = if ($doTpmClear) {
            'A REBOOT IS REQUIRED to complete the TPM clear. Reboot the machine, then re-run BL001 BLStatusSnapshot to verify.'
        } else {
            'A reboot is pending on this system. Some changes may not take effect until the machine is restarted.'
        }
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
Write-Output '        Run BL001 BLStatusSnapshot to verify the current state.'
Write-Output '        If TPM clear was needed -> reboot the machine, then run BL001 again.'
Write-Output '        If ready for encryption -> run BL010 BLForceEncrypt.'
Write-Output ''
