# BL001_BLStatusSnapshot.ps1
# Scriptlet: BL001 - BitLocker Status Snapshot
# Context: System | Version: 1.1

$ErrorActionPreference = 'Continue'

Write-Output ''
Write-Output '=== BitLocker Status Snapshot ==='
Write-Output ''

$issueCount = 0
$warnCount = 0

# --- Check 1: Volume Encryption Status ---
$blAvailable = $true
$blError = $null
$volumes = $null

try {
    $volumes = Get-BitLockerVolume -ErrorAction Stop
} catch {
    # BitLocker module not available or access denied -- capture error for later
    $blAvailable = $false
    $blError = $_.Exception.Message
}

if (-not $blAvailable) {
    # WMI fallback
    try {
        $wmiVols = @(Get-CimInstance -Namespace root/CIMv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -ErrorAction Stop)
        if ($wmiVols.Count -gt 0) {
            Write-Output '[i]   Using WMI fallback -- key protector details unavailable.'
            # Build a simplified volume list from WMI data
            $encMethodMap = @{
                0 = 'None'
                1 = 'AES-128-Diffuser'
                2 = 'AES-256-Diffuser'
                3 = 'AES-128'
                4 = 'AES-256'
                6 = 'XTS-AES-128'
                7 = 'XTS-AES-256'
            }
            $convStatusMap = @{
                0 = 'FullyDecrypted'
                1 = 'FullyEncrypted'
                2 = 'EncryptionInProgress'
                3 = 'DecryptionInProgress'
                4 = 'EncryptionPaused'
                5 = 'DecryptionPaused'
            }
            $protStatusMap = @{
                0 = 'Off'
                1 = 'On'
                2 = 'Unknown'
            }

            # Filter out removable volumes (VolumeType 2 = Removable)
            $fixedWmiVols = @($wmiVols | Where-Object { $_.VolumeType -ne 2 })
            if ($fixedWmiVols.Count -eq 0) { $fixedWmiVols = @($wmiVols) }

            foreach ($wv in $fixedWmiVols) {
                $mp = $wv.DriveLetter
                if ([string]::IsNullOrWhiteSpace($mp)) { continue }

                $conv = [int]$wv.ConversionStatus
                $prot = [int]$wv.ProtectionStatus
                $enc  = [int]$wv.EncryptionMethod

                $convStr = if ($convStatusMap.ContainsKey($conv)) { $convStatusMap[$conv] } else { "Unknown ($conv)" }
                $protStr = if ($protStatusMap.ContainsKey($prot)) { $protStatusMap[$prot] } else { "Unknown ($prot)" }
                $encStr  = if ($encMethodMap.ContainsKey($enc))  { $encMethodMap[$enc] }  else { "Unknown ($enc)" }

                if ($conv -eq 1 -and $prot -eq 1) {
                    Write-Output "[OK]  Volume $mp (WMI)"
                    Write-Output "       Status: $convStr. Protection: $protStr. Method: $encStr."
                } elseif ($conv -eq 1 -and $prot -eq 0) {
                    Write-Output "[!!]  Volume $mp (WMI)"
                    Write-Output '       GHOST STATE -- Volume is encrypted but protection is OFF.'
                    Write-Output '       The encryption key is in the clear. Data is not actually protected.'
                    Write-Output '       Run BL009 BLTpmRemediation to bind a key protector.'
                    $issueCount++
                } elseif ($conv -eq 0) {
                    Write-Output "[!!]  Volume $mp (WMI)"
                    Write-Output "       Status: $convStr. Volume is not encrypted."
                    Write-Output '       Run BL002 BLTpmHealth to check encryption readiness.'
                    $issueCount++
                } elseif ($conv -eq 2) {
                    $pct = 'unknown'
                    try {
                        $cpResult = Invoke-CimMethod -InputObject $wv -MethodName GetConversionStatus -ErrorAction Stop
                        if ($null -ne $cpResult -and $null -ne $cpResult.EncryptionPercentage) {
                            $pct = "$($cpResult.EncryptionPercentage)%"
                        }
                    } catch { }
                    Write-Output "[i]   Volume $mp (WMI)"
                    Write-Output "       Status: $convStr ($pct). Encryption is in progress."
                    Write-Output '       This is normal during initial provisioning. Re-run BL001 to check progress.'
                } elseif ($conv -eq 4 -or $conv -eq 5) {
                    Write-Output "[!!]  Volume $mp (WMI)"
                    Write-Output "       Status: $convStr. Operation was interrupted and needs intervention."
                    Write-Output '       Run BL009 BLTpmRemediation to resume or restart.'
                    $issueCount++
                } elseif ($conv -eq 3) {
                    Write-Output "[!]   Volume $mp (WMI)"
                    Write-Output "       Status: $convStr. Someone or something is actively decrypting this volume."
                    $warnCount++
                } else {
                    Write-Output "[i]   Volume $mp (WMI)"
                    Write-Output "       Status: $convStr. Protection: $protStr. Method: $encStr."
                }
            }
        } else {
            $wasBLAccessDenied = ($null -ne $blError -and ($blError -like '*Access*denied*' -or $blError -like '*0x80070005*'))
            if ($wasBLAccessDenied) {
                Write-Output '[!!]  BitLocker Status'
                Write-Output '       ACCESS DENIED -- BitLocker queries require Administrator or SYSTEM privileges.'
                Write-Output '       Re-run this script in an elevated PowerShell window or via the RMM tool.'
            } else {
                Write-Output '[!!]  BitLocker Status'
                Write-Output '       Could not query BitLocker volumes.'
                if (-not [string]::IsNullOrWhiteSpace($blError)) {
                    Write-Output "       Get-BitLockerVolume: $blError"
                }
                Write-Output '       WMI Win32_EncryptableVolume returned no data.'
                Write-Output '       Possible causes: BitLocker feature not installed, no encryptable volumes found,'
                Write-Output '       or TPM/hardware prerequisites not met. Run BL002 BLTpmHealth to investigate.'
            }
            $issueCount++
        }
    } catch {
        $wmiErr = $_.Exception.Message
        $isAccessDenied = ($wmiErr -like '*Access*denied*' -or $wmiErr -like '*0x80070005*')
        $wasBLAccessDenied = ($null -ne $blError -and ($blError -like '*Access*denied*' -or $blError -like '*0x80070005*'))
        if ($isAccessDenied -or $wasBLAccessDenied) {
            Write-Output '[!!]  BitLocker Status'
            Write-Output '       ACCESS DENIED -- BitLocker queries require Administrator or SYSTEM privileges.'
            Write-Output '       Re-run this script in an elevated PowerShell window or via the RMM tool.'
            $issueCount++
        } elseif ($wmiErr -like '*Invalid namespace*' -or $wmiErr -like '*not found*') {
            Write-Output '[!!]  BitLocker Status'
            Write-Output '       BitLocker is not available on this Windows edition.'
            Write-Output "       WMI namespace not found: $wmiErr"
            $issueCount++
        } else {
            Write-Output '[!!]  BitLocker Status'
            Write-Output '       Could not query BitLocker volumes.'
            if (-not [string]::IsNullOrWhiteSpace($blError)) {
                Write-Output "       Get-BitLockerVolume: $blError"
            }
            Write-Output "       WMI fallback: $wmiErr"
            Write-Output '       Possible causes: BitLocker feature not installed, no encryptable volumes,'
            Write-Output '       or TPM/hardware prerequisites not met. Run BL002 BLTpmHealth to investigate.'
            $issueCount++
        }
    }
}

if ($null -ne $volumes) {
    $fixedVols = @($volumes | Where-Object { $_.VolumeType -ne 'RemovableData' -and $_.VolumeType -ne $null })
    if ($fixedVols.Count -eq 0) {
        $fixedVols = @($volumes)
    }

    if ($fixedVols.Count -eq 0) {
        Write-Output '[!!]  BitLocker Status'
        Write-Output '       Get-BitLockerVolume returned no volumes.'
        Write-Output '       No encryptable volumes found. Run BL002 BLTpmHealth to investigate.'
        $issueCount++
    }

    foreach ($vol in $fixedVols) {
        $mp       = $vol.MountPoint
        $vType    = $vol.VolumeType
        $vStatus  = $vol.VolumeStatus
        $pct      = $vol.EncryptionPercentage
        $protStat = $vol.ProtectionStatus
        $encMeth  = $vol.EncryptionMethod
        $lockStat = $vol.LockStatus

        # Build key protector type list
        $kpTypes = @()
        if ($null -ne $vol.KeyProtector) {
            foreach ($kp in $vol.KeyProtector) {
                $kpTypes += $kp.KeyProtectorType.ToString()
            }
        }
        $kpStr = if ($kpTypes.Count -gt 0) { $kpTypes -join ', ' } else { 'None' }

        $hasTpm = $kpTypes -contains 'Tpm' -or $kpTypes -contains 'TpmPin' -or $kpTypes -contains 'TpmStartupKey' -or $kpTypes -contains 'TpmPinStartupKey'
        $hasRecovery = $kpTypes -contains 'RecoveryPassword'

        $detail1 = "Status: $vStatus. Protection: $protStat. Method: $encMeth."
        $detail2 = "Type: $vType. Lock: $lockStat. Protectors: $kpStr."

        if ($vStatus -eq 'FullyEncrypted' -and $protStat -eq 'On') {
            if ($hasTpm -and $hasRecovery) {
                Write-Output "[OK]  Volume $mp"
                Write-Output "       $detail1"
                Write-Output "       $detail2"
            } elseif (-not $hasRecovery) {
                Write-Output "[!]   Volume $mp"
                Write-Output "       $detail1"
                Write-Output "       $detail2"
                Write-Output "       No RecoveryPassword protector found. Key escrow may have failed."
                Write-Output "       Run BL005 BLEscrowCheck to investigate."
                $warnCount++
            } else {
                Write-Output "[OK]  Volume $mp"
                Write-Output "       $detail1"
                Write-Output "       $detail2"
            }
        } elseif ($vStatus -eq 'FullyEncrypted' -and $protStat -eq 'Off') {
            Write-Output "[!!]  Volume $mp"
            Write-Output '       GHOST STATE -- Volume is encrypted but protection is OFF.'
            Write-Output '       The encryption key is in the clear. Data is not actually protected.'
            Write-Output "       $detail2"
            Write-Output '       Run BL009 BLTpmRemediation to bind a key protector.'
            $issueCount++
        } elseif ($vStatus -eq 'FullyDecrypted') {
            Write-Output "[!!]  Volume $mp"
            Write-Output "       Not encrypted. $detail2"
            Write-Output '       Run BL002 BLTpmHealth to check encryption readiness.'
            $issueCount++
        } elseif ($vStatus -eq 'EncryptionInProgress') {
            Write-Output "[i]   Volume $mp"
            Write-Output "       Encryption in progress ($pct%). $detail2"
            Write-Output '       This is normal during initial provisioning. Re-run BL001 to check progress.'
        } elseif ($vStatus -eq 'EncryptionPaused') {
            Write-Output "[!!]  Volume $mp"
            Write-Output "       Encryption PAUSED at $pct%. Encryption was interrupted and needs intervention."
            Write-Output "       $detail2"
            Write-Output '       Run BL009 BLTpmRemediation to resume or restart.'
            $issueCount++
        } elseif ($vStatus -eq 'DecryptionInProgress') {
            Write-Output "[!]   Volume $mp"
            Write-Output "       Decryption in progress ($pct%). Someone or something is actively decrypting."
            Write-Output "       $detail2"
            $warnCount++
        } elseif ($vStatus -eq 'DecryptionPaused') {
            Write-Output "[!!]  Volume $mp"
            Write-Output "       Decryption PAUSED at $pct%. Operation was interrupted."
            Write-Output "       $detail2"
            Write-Output '       Run BL009 BLTpmRemediation to resume or restart.'
            $issueCount++
        } elseif ($protStat -eq 'Off') {
            # Protection suspended on a volume that is not FullyEncrypted (ghost state handled above)
            Write-Output "[!]   Volume $mp"
            Write-Output "       Protection suspended. $detail1"
            Write-Output "       $detail2"
            $warnCount++
        } else {
            Write-Output "[i]   Volume $mp"
            Write-Output "       $detail1"
            Write-Output "       $detail2"
        }
    }
}

# --- Check 2: OS Drive Letter Validation ---
$osDrive = $env:SystemDrive
if ($osDrive -eq 'C:') {
    Write-Output '[OK]  OS Drive Letter'
    Write-Output '       OS is on C: as expected. Intune policies will target the correct volume.'
} else {
    Write-Output '[!!]  OS Drive Letter'
    Write-Output "       OS is on $osDrive -- NOT the standard C: drive."
    Write-Output '       Intune BitLocker policies and remediation scripts assume C: and may target the wrong volume.'
    $issueCount++
}

# --- Check 3: Last BitLocker Event ---
$eventIdMap = @{
    768 = 'Encryption started successfully'
    770 = 'Decryption started'
    771 = 'Decryption paused or stopped'
    775 = 'Encryption method and key protector set'
    778 = 'Volume reverted to unprotected state'
    805 = 'Volume unlocked with recovery key (protector failure occurred)'
    810 = 'BitLocker cannot use Secure Boot for integrity validation'
    846 = 'Recovery key escrow to Entra ID FAILED'
    851 = 'Silent encryption FAILED'
    853 = 'TPM not found or bootable media detected'
    854 = 'WinRE not configured -- encryption blocked'
}

$failureIds = @(846, 851, 853, 854)
$warningIds = @(778, 805, 810, 770, 771)

try {
    $lastEvent = Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management' -MaxEvents 1 -ErrorAction Stop
    $evId = $lastEvent.Id
    $evTime = $lastEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $evMsg = $lastEvent.Message
    if ($null -ne $evMsg -and $evMsg.Length -gt 200) {
        $evMsg = $evMsg.Substring(0, 200) + '...'
    }

    $evSummary = if ($eventIdMap.ContainsKey($evId)) { $eventIdMap[$evId] } else { '' }

    if ($failureIds -contains $evId) {
        Write-Output "[!!]  Last BitLocker Event (ID $evId, $evTime)"
        if ($evSummary -ne '') {
            Write-Output "       $evSummary"
        }
        Write-Output "       $evMsg"
        Write-Output '       Run BL007 BLEventAnalysis for the full failure timeline.'
        $issueCount++
    } elseif ($warningIds -contains $evId) {
        Write-Output "[!]   Last BitLocker Event (ID $evId, $evTime)"
        if ($evSummary -ne '') {
            Write-Output "       $evSummary"
        }
        Write-Output "       $evMsg"
        $warnCount++
    } else {
        Write-Output "[OK]  Last BitLocker Event (ID $evId, $evTime)"
        if ($evSummary -ne '') {
            Write-Output "       $evSummary"
        }
        Write-Output "       $evMsg"
    }
} catch {
    $fqeid = $_.FullyQualifiedErrorId
    if ($fqeid -eq 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand' -or $fqeid -like '*EventLogNotFoundException*') {
        Write-Output '[i]   Last BitLocker Event'
        Write-Output '       No BitLocker management events found. Encryption may never have been attempted.'
    } else {
        Write-Output '[i]   Last BitLocker Event'
        Write-Output "       Could not read BitLocker event log: $($_.Exception.Message)"
    }
}

# --- Check 4: BDESVC Service Health ---
$bdesvc = Get-Service -Name 'BDESVC' -ErrorAction SilentlyContinue
if ($null -eq $bdesvc) {
    Write-Output '[!!]  BitLocker Service (BDESVC)'
    Write-Output '       Service not found. BitLocker may not be available on this Windows edition.'
    $issueCount++
} else {
    $bdeStatus = $bdesvc.Status.ToString()
    $bdeStart  = $bdesvc.StartType.ToString()

    if ($bdeStart -eq 'Disabled') {
        Write-Output '[!!]  BitLocker Service (BDESVC)'
        Write-Output '       DISABLED. All BitLocker operations will fail.'
        Write-Output '       Run BL009 BLTpmRemediation or re-enable the service manually.'
        $issueCount++
    } elseif ($bdeStatus -ne 'Running' -and ($bdeStart -eq 'Manual' -or $bdeStart -eq 'Automatic')) {
        Write-Output '[OK]  BitLocker Service (BDESVC)'
        Write-Output "       $bdeStatus, start type: $bdeStart. This is expected -- service starts on demand."
    } else {
        Write-Output '[OK]  BitLocker Service (BDESVC)'
        Write-Output "       $bdeStatus, start type: $bdeStart. Operational."
    }

    # Verify BDESvc SDDL for the Removable Drive "Access is denied" bug
    try {
        $scOut = & sc.exe sdshow bdesvc 2>&1
        # Filter for SDDL line only (starts with D:, O:, G:, or S:), skip sc.exe header text
        $sddlLine = $scOut | Where-Object { "$_" -match '^[DOGS]:' }
        $sddl = ($sddlLine | ForEach-Object { "$_" }) -join ''

        # The specific bug: Interactive (IU) replacing Authenticated Users (AU)
        if ($sddl -match '\(A;;[^)]*;;;IU\)' -and $sddl -notmatch '\(A;;[^)]*;;;AU\)') {
            Write-Output ''
            Write-Output '[!!]  BitLocker Service (BDESVC) -- Security Descriptor Bug'
            Write-Output '       The BDESvc security descriptor contains INTERACTIVE (IU) instead of Authenticated Users (AU).'
            Write-Output '       This explicitly causes an "Access is denied" error when users try to encrypt removable USB drives.'
            Write-Output '       RESOLUTION: Run "sc sdset bdesvc <Default_SDDL>" to repair. Check GPOs for service permission poisoning.'
            $issueCount++
        }
    } catch { }
}

# --- Summary ---
Write-Output ''
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. BitLocker appears healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] and [!] above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}
Write-Output ''
Write-Output 'NEXT:   If not encrypted and no errors  -> run BL002 BLTpmHealth to check TPM readiness'
Write-Output '        If encryption failed            -> run BL007 BLEventAnalysis for the failure reason'
Write-Output '        If suspended                    -> run BL009 BLTpmRemediation to resume or restart'
Write-Output '        If encrypted but Intune non-compliant -> force Intune sync (INT001)'
Write-Output '        If ghost state (encrypted, protection off) -> run BL009 BLTpmRemediation'
Write-Output '        If no recovery key              -> run BL005 BLEscrowCheck'
