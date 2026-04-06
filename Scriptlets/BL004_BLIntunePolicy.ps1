# BL004_BLIntunePolicy.ps1
# Scriptlet: BL004 - Intune Policy & MDM Enrollment Check
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Intune Policy & MDM Enrollment Check ==='
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
# Check 1: MDM Enrollment Status via dsregcmd /status
# ---------------------------------------------------------------
Write-Output '--- MDM Enrollment Status ---'

$dsregOutput = $null
$dsregOK = $false
try {
    $dsregOutput = & dsregcmd.exe /status 2>&1
    # Strip ANSI/VT escape sequences -- dsregcmd on Win 11 emits VT codes that clear the console
    if ($null -ne $dsregOutput) { $dsregOutput = $dsregOutput | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[a-zA-Z]', '' } }
    if ($null -ne $dsregOutput -and $dsregOutput.Count -gt 0) { $dsregOK = $true }
} catch { }

if (-not $dsregOK) {
    Write-Output '[!!]  Cannot Run dsregcmd'
    Write-Output '       dsregcmd.exe /status failed or returned no output.'
    Write-Output '       Cannot determine MDM enrollment state.'
    $issueCount++
} else {
    # Parse key fields from dsregcmd output
    $azureAdJoined = 'UNKNOWN'
    $domainJoined  = 'UNKNOWN'
    $workplaceJoined = 'UNKNOWN'
    $mdmUrl = ''
    $deviceId = ''

    foreach ($line in $dsregOutput) {
        $lineStr = "$line".Trim()
        if ($lineStr -match '^\s*AzureAdJoined\s*:\s*(YES|NO)\s*$') {
            $azureAdJoined = $Matches[1]
        }
        if ($lineStr -match '^\s*DomainJoined\s*:\s*(YES|NO)\s*$') {
            $domainJoined = $Matches[1]
        }
        if ($lineStr -match '^\s*WorkplaceJoined\s*:\s*(YES|NO)\s*$') {
            $workplaceJoined = $Matches[1]
        }
        if ($lineStr -match '^\s*MdmUrl\s*:\s*(https?://.+)\s*$') {
            $mdmUrl = $Matches[1]
        }
        if ($lineStr -match '^\s*DeviceId\s*:\s*([0-9a-fA-F\-]{36})\s*$') {
            $deviceId = $Matches[1]
        }
    }

    # Determine join state
    $joinState = 'Unknown'
    if ($azureAdJoined -eq 'YES' -and $domainJoined -eq 'NO') {
        $joinState = 'Entra ID Joined (cloud-native)'
    } elseif ($azureAdJoined -eq 'YES' -and $domainJoined -eq 'YES') {
        $joinState = 'Hybrid Entra ID Joined'
    } elseif ($azureAdJoined -eq 'NO' -and $domainJoined -eq 'YES') {
        $joinState = 'On-prem AD only (no cloud join)'
    } elseif ($azureAdJoined -eq 'NO' -and $workplaceJoined -eq 'YES') {
        $joinState = 'Workplace Joined (BYOD)'
    } elseif ($azureAdJoined -eq 'NO' -and $domainJoined -eq 'NO' -and $workplaceJoined -eq 'NO') {
        $joinState = 'Not joined to anything'
    }

    # Report join state
    if ($azureAdJoined -eq 'YES') {
        Write-Output "[OK]  $joinState"
        Write-Output "       AzureAdJoined: $azureAdJoined. DomainJoined: $domainJoined."
        if ($joinState -eq 'Hybrid Entra ID Joined') {
            Write-Output '[i]   Hybrid join: both GPO and MDM may deliver BitLocker policies.'
            Write-Output '       If encryption fails, run BL006 BLPolicyConflict to check for conflicts.'
        }
    } elseif ($azureAdJoined -eq 'NO' -and $workplaceJoined -eq 'YES') {
        Write-Output "[!]   $joinState"
        Write-Output '       BYOD registration does not support device-level BitLocker policies.'
        Write-Output '       The device must be Entra ID Joined for Intune BitLocker management.'
        $warnCount++
    } elseif ($azureAdJoined -eq 'NO') {
        Write-Output "[!!]  $joinState"
        Write-Output "       AzureAdJoined: $azureAdJoined. DomainJoined: $domainJoined."
        Write-Output '       Intune BitLocker policies cannot be delivered to this device.'
        Write-Output '       The device must be joined to Entra ID (cloud or hybrid).'
        $issueCount++
    } else {
        Write-Output "[!]   Join State: $joinState"
        Write-Output "       AzureAdJoined: $azureAdJoined. DomainJoined: $domainJoined."
        $warnCount++
    }

    # Report MDM URL
    if ($mdmUrl.Length -gt 0) {
        Write-Output '[OK]  MDM URL Configured'
        Write-Output "       MdmUrl: $mdmUrl"
        Write-Output '       Intune enrollment channel is present.'
    } else {
        if ($azureAdJoined -eq 'YES') {
            Write-Output '[!!]  MDM URL: NOT CONFIGURED'
            Write-Output '       Device is Entra joined but has no MDM endpoint URL.'
            Write-Output '       Possible causes: missing Intune license, user excluded from'
            Write-Output '       MDM auto-enrollment scope, or stale enrollment.'
            $issueCount++
        } else {
            Write-Output '[i]   MDM URL: Not present (device is not Entra joined)'
        }
    }

    # Report DeviceId
    if ($deviceId.Length -gt 0) {
        Write-Output "[i]   DeviceId: $deviceId"
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: BitLocker CSP Settings from Registry
# ---------------------------------------------------------------
Write-Output '--- BitLocker CSP Policy ---'

$cspPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker'
$cspExists = Test-Path $cspPath

if (-not $cspExists) {
    # Check for ghost policies trapped in the SYSTEM profile hive (HKU\.DEFAULT).
    # During Autopilot, the MDM client runs as SYSTEM. A known failure mode causes
    # BitLocker CSP payloads to land in the SYSTEM user hive instead of the machine
    # hive, producing the infamous Intune "Error 65000" with no visible root cause.
    $ghostPath = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\PolicyManager\current\Device\BitLocker'
    $ghostExists = Test-Path $ghostPath

    if ($ghostExists) {
        Write-Output '[!!]  BitLocker CSP Policy: TRAPPED IN SYSTEM PROFILE HIVE'
        Write-Output '       Policy NOT found in machine hive (HKLM):'
        Write-Output "       $cspPath"
        Write-Output '       Policy FOUND in SYSTEM user hive (HKU\.DEFAULT):'
        Write-Output "       $ghostPath"
        Write-Output '       Root cause: Autopilot enrolled under SYSTEM context and the MDM client'
        Write-Output '       wrote CSP payloads to the wrong registry hive. This is the cause of'
        Write-Output '       Intune "Error 65000" during BitLocker provisioning.'
        Write-Output '       Remediation: re-enroll the device or manually move the policy keys'
        Write-Output '       from HKU\.DEFAULT to HKLM\SOFTWARE\Microsoft\PolicyManager.'
        $issueCount++
    }
    else {
        # Check for policies staged in the Provider path that failed to merge into Current.
        # PolicyManager pipeline: Providers\<GUID>\default -> merge -> current\device.
        # If the policy exists in staging but not current, the merge was rejected -- typically
        # because a legacy GPO won conflict resolution and blocked the Intune payload.
        $provBasePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers'
        $stagedGuidFound = $null

        if (Test-Path $provBasePath) {
            $providers = $null
            try {
                $providers = Get-ChildItem -Path $provBasePath -ErrorAction Stop |
                    Where-Object { $_.PSChildName -match '^[0-9a-fA-F-]{36}$' }
            } catch { }
            if ($providers) {
                foreach ($prov in $providers) {
                    $checkPath = "$($prov.PSPath)\default\Device\BitLocker"
                    if (Test-Path $checkPath) { $stagedGuidFound = $prov.PSChildName; break }
                }
            }
        }

        if ($stagedGuidFound) {
            Write-Output '[!!]  BitLocker CSP Policy: MERGE REJECTED (Staged but not Current)'
            Write-Output "       Policy FOUND in Staging Provider: $stagedGuidFound"
            Write-Output '       Policy NOT found in Active Current: HKLM\...\current\device\BitLocker'
            Write-Output '       Root cause: Intune successfully delivered the policy to the device, but'
            Write-Output '       the Windows PolicyManager refused to merge it into the active configuration.'
            Write-Output '       This is almost always caused by an overlapping legacy Active Directory GPO.'
            Write-Output '       Run BL006 BLPolicyConflict to identify the blocking GPO.'
            $issueCount++
        }
        else {
            Write-Output '[!]   BitLocker CSP Policy: NOT RECEIVED'
            Write-Output '       Registry path not found:'
            Write-Output "       $cspPath"
            Write-Output '       Intune has not delivered a BitLocker policy to this device.'
            Write-Output '       Force an Intune sync and wait 15 minutes, then re-check.'
            $warnCount++
        }
    }
} else {
    # RequireDeviceEncryption
    $requireEncrypt = Get-RegVal -Path $cspPath -Name 'RequireDeviceEncryption'
    if ($null -ne $requireEncrypt -and [int]$requireEncrypt -eq 1) {
        Write-Output '[OK]  RequireDeviceEncryption: 1 (Required)'
        Write-Output '       Intune is requiring BitLocker encryption on this device.'
    } elseif ($null -ne $requireEncrypt -and [int]$requireEncrypt -eq 0) {
        Write-Output '[i]   RequireDeviceEncryption: 0 (Not required)'
        Write-Output '       Intune is not requiring encryption. Policy may be informational only.'
    } else {
        Write-Output '[i]   RequireDeviceEncryption: Not set'
        Write-Output '       No encryption requirement found in CSP policy.'
    }

    # EncryptionMethodByDriveType (XML-encoded)
    $encMethodRaw = Get-RegVal -Path $cspPath -Name 'EncryptionMethodByDriveType'
    $osCipher = 'Not specified'
    $fixedCipher = 'Not specified'
    $removableCipher = 'Not specified'

    # Cipher decode helper
    $cipherMap = @{
        '3' = 'AES-CBC 128-bit'
        '4' = 'AES-CBC 256-bit'
        '6' = 'XTS-AES 128-bit'
        '7' = 'XTS-AES 256-bit'
    }
    $osCipherInt = -1
    $fixedCipherInt = -1

    if ($null -ne $encMethodRaw -and $encMethodRaw.Length -gt 0) {
        # Try to extract cipher integers from XML or raw value
        # The CSP stores this as XML: <enabled/><data id="EncryptionMethodWithXtsOsDropDown_Name" value="7"/>...
        if ($encMethodRaw -match 'EncryptionMethodWithXtsOs[^"]*"\s*value\s*=\s*"(\d+)"') {
            $osCipherInt = [int]$Matches[1]
            $val = "$osCipherInt"
            if ($cipherMap.ContainsKey($val)) { $osCipher = $cipherMap[$val] }
            else { $osCipher = "Unknown ($osCipherInt)" }
        }
        if ($encMethodRaw -match 'EncryptionMethodWithXtsFdv[^"]*"\s*value\s*=\s*"(\d+)"') {
            $fixedCipherInt = [int]$Matches[1]
            $val = "$fixedCipherInt"
            if ($cipherMap.ContainsKey($val)) { $fixedCipher = $cipherMap[$val] }
            else { $fixedCipher = "Unknown ($fixedCipherInt)" }
        }
        if ($encMethodRaw -match 'EncryptionMethodWithXtsRdv[^"]*"\s*value\s*=\s*"(\d+)"') {
            $rdvInt = [int]$Matches[1]
            $val = "$rdvInt"
            if ($cipherMap.ContainsKey($val)) { $removableCipher = $cipherMap[$val] }
            else { $removableCipher = "Unknown ($rdvInt)" }
        }
        Write-Output "[i]   Encryption Method: $osCipher (OS), $fixedCipher (Fixed), $removableCipher (Removable)"
    } else {
        Write-Output '[i]   EncryptionMethodByDriveType: Not configured in CSP'
    }

    # AllowStandardUserEncryption
    $allowStdUser = Get-RegVal -Path $cspPath -Name 'AllowStandardUserEncryption'
    if ($null -ne $allowStdUser -and [int]$allowStdUser -eq 1) {
        Write-Output '[OK]  AllowStandardUserEncryption: 1 (Allowed)'
    } elseif ($null -ne $allowStdUser) {
        Write-Output "[!]   AllowStandardUserEncryption: $allowStdUser"
        Write-Output '       Standard users cannot trigger encryption during Autopilot OOBE.'
        $warnCount++
    } else {
        Write-Output '[i]   AllowStandardUserEncryption: Not set'
    }

    # AllowWarningForOtherDiskEncryption
    $allowWarning = Get-RegVal -Path $cspPath -Name 'AllowWarningForOtherDiskEncryption'
    if ($null -ne $allowWarning -and [int]$allowWarning -eq 0) {
        Write-Output '[OK]  AllowWarningForOtherDiskEncryption: 0 (Suppressed -- silent encryption enabled)'
    } elseif ($null -ne $allowWarning -and [int]$allowWarning -eq 1) {
        Write-Output '[!]   AllowWarningForOtherDiskEncryption: 1 (Warning shown)'
        Write-Output '       The encryption wizard will prompt the user, breaking silent provisioning.'
        $warnCount++
    } else {
        Write-Output '[i]   AllowWarningForOtherDiskEncryption: Not set (defaults to showing warning)'
    }

    # SystemDrivesRequireStartupAuthentication
    $startupAuth = Get-RegVal -Path $cspPath -Name 'SystemDrivesRequireStartupAuthentication'
    $requiresPin = $false
    if ($null -ne $startupAuth -and $startupAuth.Length -gt 0) {
        # Check if PIN is required from the XML
        # UseTPMPIN = 2 means Allow, UseTPMKeyPIN = 2 means Allow
        # If UseTPM = 2 and UseTPMPIN = 0 and UseTPMKeyPIN = 0 -> TPM-only (silent)
        $tpmOnly = $true
        if ($startupAuth -match 'UseTPMPIN[^K][^"]*"\s*value\s*=\s*"([12])"') {
            if ([int]$Matches[1] -ge 1) {
                $requiresPin = $true
                $tpmOnly = $false
            }
        }
        if ($startupAuth -match 'UseTPMKeyPIN[^"]*"\s*value\s*=\s*"([12])"') {
            if ([int]$Matches[1] -ge 1) {
                $requiresPin = $true
                $tpmOnly = $false
            }
        }
        if ($tpmOnly) {
            Write-Output '[OK]  Startup Authentication: TPM-only (silent compatible)'
        } else {
            Write-Output '[!]   Startup Authentication: TPM+PIN or TPM+Key+PIN configured'
            Write-Output '       Pre-boot PIN requires user interaction. Silent encryption is not possible.'
            $warnCount++
        }
    } else {
        Write-Output '[i]   SystemDrivesRequireStartupAuthentication: Not configured'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Policy vs Hardware Comparison
# ---------------------------------------------------------------
Write-Output '--- Policy vs Hardware ---'

$comparisonDone = $false

if ($cspExists) {
    # Check XTS cipher vs OS build
    if ($osCipherInt -ge 6) {
        # XTS requires Windows 10 1511+ (build 10586)
        $osBuild = 0
        try {
            $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ($null -ne $osInfo) {
                $osBuild = [int]$osInfo.BuildNumber
            }
        } catch { }

        if ($osBuild -gt 0 -and $osBuild -lt 10586) {
            Write-Output "[!!]  Cipher Incompatibility"
            Write-Output "       Policy requires XTS-AES but OS build $osBuild does not support XTS."
            Write-Output '       XTS-AES requires Windows 10 1511 (build 10586) or later.'
            Write-Output '       Change the CSP to use AES-CBC, or upgrade the OS.'
            $issueCount++
            $comparisonDone = $true
        } elseif ($osBuild -ge 10586) {
            Write-Output '[OK]  Cipher Compatibility'
            Write-Output "       XTS-AES is supported on this OS build ($osBuild)."
            $comparisonDone = $true
        }
    }

    # Check TPM+PIN vs silent encryption
    if ($requiresPin) {
        Write-Output '[!!]  Silent Encryption: BLOCKED'
        Write-Output '       Policy requires TPM+PIN, which needs user interaction at pre-boot.'
        Write-Output '       Silent encryption cannot proceed. Change to TPM-only if silent is needed.'
        $issueCount++
        $comparisonDone = $true
    }

    # Check AllowWarning + AllowStdUser coherence for silent path
    $silentReady = $true
    $silentIssues = New-Object System.Collections.Generic.List[string]

    if ($null -eq $allowWarning -or [int]$allowWarning -ne 0) {
        $silentReady = $false
        $null = $silentIssues.Add('AllowWarningForOtherDiskEncryption not suppressed')
    }
    if ($requiresPin) {
        $silentReady = $false
        $null = $silentIssues.Add('TPM+PIN requires user interaction')
    }

    if ($silentReady -and -not $requiresPin) {
        if (-not $comparisonDone) {
            Write-Output '[OK]  Silent Encryption Coherence'
            Write-Output '       Policy settings are compatible with silent encryption path.'
            $comparisonDone = $true
        }
    } elseif ($silentIssues.Count -gt 0 -and -not $requiresPin) {
        Write-Output '[!]   Silent Encryption: Partial'
        foreach ($si in $silentIssues) {
            Write-Output "       - $si"
        }
        $warnCount++
        $comparisonDone = $true
    }

    # Check cipher mismatch with currently encrypted volume
    try {
        $blVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($null -ne $blVol -and $blVol.VolumeStatus -ne 'FullyDecrypted') {
            $currentMethod = "$($blVol.EncryptionMethod)"
            # Map current method to cipher int for comparison
            $currentInt = -1
            switch ($currentMethod) {
                'Aes128'    { $currentInt = 3 }
                'Aes256'    { $currentInt = 4 }
                'XtsAes128' { $currentInt = 6 }
                'XtsAes256' { $currentInt = 7 }
            }
            if ($osCipherInt -gt 0 -and $currentInt -gt 0 -and $osCipherInt -ne $currentInt) {
                $currentName = $currentMethod
                $policyName = $osCipher
                Write-Output "[!]   Cipher Mismatch Detected"
                Write-Output "       Current encryption: $currentName."
                Write-Output "       Policy requires: $policyName."
                Write-Output '       BitLocker cannot change ciphers on an encrypted volume.'
                Write-Output '       A full decrypt/re-encrypt cycle is required to comply.'
                # Flag the XTS-128 vs XTS-256 Autopilot race condition on pre-24H2 builds.
                # Windows auto-encrypts at XTS-AES-128 during OOBE before the Intune policy
                # (typically XTS-AES-256) finishes downloading. 24H2 introduced the OOBE
                # Deferral Mechanism to prevent this.
                if ($currentInt -eq 6 -and $osCipherInt -eq 7) {
                    $rcBuild = 0
                    try {
                        $rcNtVer = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
                        $rcBuild = [int]$rcNtVer.CurrentBuildNumber
                    } catch { }
                    if ($rcBuild -gt 0 -and $rcBuild -lt 26100) {
                        Write-Output ''
                        Write-Output "[i]   DIAGNOSTIC INSIGHT: Autopilot Cipher Race Condition (build $rcBuild)"
                        Write-Output '       Windows natively encrypted at XTS-AES-128 during OOBE before the'
                        Write-Output '       Intune XTS-AES-256 policy finished downloading. Pre-24H2 builds'
                        Write-Output '       lack the OOBE Deferral Mechanism that prevents this race condition.'
                        Write-Output '       This is not a policy error -- the device encrypted with OS defaults'
                        Write-Output '       before MDM policy delivery completed.'
                    }
                }
                $warnCount++
                $comparisonDone = $true
            }
        }
    } catch { }
}

if (-not $comparisonDone) {
    if (-not $cspExists) {
        Write-Output '[i]   No policy to compare against hardware. CSP not received.'
    } else {
        Write-Output '[OK]  No hardware conflicts detected with current policy settings.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Intune Management Extension Logs
# ---------------------------------------------------------------
Write-Output '--- Intune Management Extension Logs ---'

$imePath = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log'

if (-not (Test-Path $imePath)) {
    Write-Output '[!]   IME Log: Not found'
    Write-Output "       Path: $imePath"
    Write-Output '       Intune Management Extension may not be installed, or the log has been cleared.'
    $warnCount++
} else {
    $imeMatches = New-Object System.Collections.Generic.List[string]
    try {
        # Read last 5000 lines to avoid memory issues on large logs
        $imeLines = Get-Content -Path $imePath -Tail 5000 -ErrorAction Stop
        foreach ($imeLine in $imeLines) {
            if ($imeLine -match '(?i)bitlocker') {
                $null = $imeMatches.Add($imeLine)
            }
        }
    } catch {
        Write-Output '[!]   Cannot read IME log'
        Write-Output "       Error: $($_.Exception.Message)"
        $warnCount++
    }

    if ($imeMatches.Count -eq 0) {
        Write-Output '[i]   No BitLocker-related entries in IME log (last 5000 lines searched).'
    } else {
        # Show last 20 matches
        $showCount = [math]::Min($imeMatches.Count, 20)
        $startIdx = $imeMatches.Count - $showCount
        Write-Output "[i]   BitLocker-related IME entries: $($imeMatches.Count) found. Showing last $showCount."

        for ($idx = $startIdx; $idx -lt $imeMatches.Count; $idx++) {
            $entry = $imeMatches[$idx]
            # Try to extract timestamp from IME log format: <![LOG[...]LOG]!><time="" date="" ...>
            $ts = ''
            if ($entry -match 'date="([^"]+)"\s+.*time="([^"]+)"') {
                $ts = "$($Matches[1]) $($Matches[2].Substring(0, [math]::Min(8, $Matches[2].Length)))"
            }
            # Extract message
            $msg = $entry
            if ($entry -match '<!\[LOG\[(.+?)\]LOG\]') {
                $msg = $Matches[1]
            }
            # Trim long messages
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + '...' }

            if ($ts.Length -gt 0) {
                Write-Output "       [$ts] $msg"
            } else {
                Write-Output "       $msg"
            }
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: MDM Enrollment Health
# ---------------------------------------------------------------
Write-Output '--- MDM Enrollment Health ---'

# 5a: EnterpriseMgmt Scheduled Tasks
$mdmTasks = $null
try {
    $mdmTasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction Stop
} catch { }

if ($null -eq $mdmTasks -or @($mdmTasks).Count -eq 0) {
    Write-Output '[!]   MDM Sync Tasks: None found'
    Write-Output '       No scheduled tasks under \Microsoft\Windows\EnterpriseMgmt\.'
    Write-Output '       Device may not be enrolled in Intune, or enrollment is incomplete.'
    $warnCount++
} else {
    $taskArray = @($mdmTasks)
    $anyFailure = $false
    # Show up to 3 tasks
    $showTasks = [math]::Min($taskArray.Count, 3)
    Write-Output "[OK]  MDM Sync Tasks: $($taskArray.Count) found"

    for ($t = 0; $t -lt $showTasks; $t++) {
        $task = $taskArray[$t]
        $taskName = $task.TaskName
        $taskInfo = $null
        try {
            $taskInfo = $task | Get-ScheduledTaskInfo -ErrorAction Stop
        } catch { }

        if ($null -ne $taskInfo) {
            $lastRun = $taskInfo.LastRunTime
            $lastResult = $taskInfo.LastTaskResult
            $resultHex = '0x{0:X}' -f $lastResult

            $lastRunStr = 'Never'
            if ($null -ne $lastRun -and $lastRun.Year -gt 2000) {
                $lastRunStr = $lastRun.ToString('yyyy-MM-dd HH:mm')
            }

            if ($lastResult -eq 0) {
                Write-Output "       Task: $taskName"
                Write-Output "       Last run: $lastRunStr. Result: $resultHex (Success)."
            } else {
                Write-Output "[!]   Task: $taskName"
                Write-Output "       Last run: $lastRunStr. Result: $resultHex (Failure)."
                $anyFailure = $true
            }
        } else {
            Write-Output "       Task: $taskName (could not retrieve run info)"
        }
    }

    if ($anyFailure) {
        Write-Output '       One or more MDM sync tasks reported failures.'
        Write-Output '       Force an Intune sync or run INT001 IntuneForceComplianceCheck.'
        $warnCount++
    }
}

# 5b: MDM Enrollment Certificate
$mdmCert = $null
try {
    $allCerts = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop
    foreach ($cert in $allCerts) {
        $issuer = "$($cert.Issuer)"
        if ($issuer -match 'SC_Online_Issuing' -or $issuer -match 'Microsoft Intune MDM Device CA') {
            $mdmCert = $cert
            break
        }
    }
} catch { }

if ($null -eq $mdmCert) {
    Write-Output '[!]   MDM Device Certificate: Not found'
    Write-Output '       No certificate from SC_Online_Issuing or Microsoft Intune MDM Device CA.'
    Write-Output '       Enrollment may be incomplete or the certificate was removed.'
    $warnCount++
} else {
    $certIssuer  = "$($mdmCert.Issuer)"
    $certExpires = $mdmCert.NotAfter
    $now = Get-Date

    # Parse issuer for display
    $issuerDisplay = $certIssuer
    if ($certIssuer -match 'CN=([^,]+)') { $issuerDisplay = $Matches[1] }

    $expiresStr = $certExpires.ToString('yyyy-MM-dd')

    if ($certExpires -lt $now) {
        Write-Output '[!!]  MDM Device Certificate: EXPIRED'
        Write-Output "       Issuer: $issuerDisplay. Expired: $expiresStr."
        Write-Output '       The MDM enrollment certificate has expired.'
        Write-Output '       Device cannot authenticate to Intune. Re-enrollment required.'
        $issueCount++
    } else {
        $daysRemaining = [math]::Round(($certExpires - $now).TotalDays, 0)
        if ($daysRemaining -lt 30) {
            Write-Output "[!]   MDM Device Certificate: Expiring soon ($daysRemaining days)"
            Write-Output "       Issuer: $issuerDisplay. Expires: $expiresStr."
            Write-Output '       Certificate will expire within 30 days. Monitor for renewal.'
            $warnCount++
        } else {
            Write-Output '[OK]  MDM Device Certificate'
            Write-Output "       Issuer: $issuerDisplay. Expires: $expiresStr. Valid ($daysRemaining days remaining)."
        }
    }
}

Write-Output ''

# 5c: Ghost MDM Enrollment Detection
# Orphaned GUID keys in HKLM\SOFTWARE\Microsoft\Enrollments\ cause re-enrollment
# to fail because the MDM client thinks the device is already managed.
$enrollPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'

if (Test-Path $enrollPath) {
    $enrollKeys = $null
    try {
        $enrollKeys = Get-ChildItem -Path $enrollPath -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^[{(]?[0-9a-fA-F-]{36}[})]?$' }
    }
    catch { }

    if ($enrollKeys) {
        $intuneEnrollments = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($key in $enrollKeys) {
            $provId = Get-RegVal -Path $key.PSPath -Name 'ProviderID'
            if ($provId -eq 'MS DM Server') {
                $enrollGuid = $key.PSChildName
                $upn = Get-RegVal -Path $key.PSPath -Name 'UPN'
                $upnStr = if ($upn) { $upn } else { 'No UPN' }
                $null = $intuneEnrollments.Add([PSCustomObject]@{ Guid = $enrollGuid; UPN = $upnStr })
            }
        }

        if ($intuneEnrollments.Count -gt 1) {
            Write-Output "[!!]  Ghost MDM Enrollment: $($intuneEnrollments.Count) Intune enrollment GUIDs found"
            Write-Output '       Only one active enrollment should exist. Multiple GUIDs indicate'
            Write-Output '       orphaned enrollments from failed provisioning or stale disenrollment.'
            foreach ($enr in $intuneEnrollments) {
                Write-Output "       - $($enr.Guid) ($($enr.UPN))"
            }
            Write-Output "       Remediation: delete orphaned GUID keys from $enrollPath"
            Write-Output '       then re-enroll the device.'
            $issueCount++
        }
        elseif ($intuneEnrollments.Count -eq 1 -and ([string]::IsNullOrEmpty($mdmUrl))) {
            # Enrollment GUID exists but dsregcmd shows no MdmUrl -- ghost enrollment
            Write-Output '[!!]  Ghost MDM Enrollment: GUID present but no MDM URL'
            Write-Output "       GUID: $($intuneEnrollments[0].Guid)"
            Write-Output '       dsregcmd reports no MdmUrl, but an Intune enrollment key exists.'
            Write-Output '       This stale GUID blocks re-enrollment (error 0x8018002b).'
            Write-Output "       Remediation: delete $enrollPath\$($intuneEnrollments[0].Guid)"
            Write-Output '       then re-enroll the device.'
            $issueCount++
        }
        elseif ($intuneEnrollments.Count -eq 1) {
            Write-Output "[OK]  MDM Enrollment Registry: 1 Intune enrollment GUID found"
            Write-Output "       GUID: $($intuneEnrollments[0].Guid). UPN: $($intuneEnrollments[0].UPN)."
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. Intune BitLocker policy is present and coherent.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If not MDM enrolled       -> re-enroll the device in Intune'
Write-Output '        If policy not received    -> force Intune sync and wait 15 minutes'
Write-Output '        If policy conflicts       -> run BL006 BLPolicyConflict to check GPO vs MDM'
Write-Output '        If policy looks correct   -> run BL005 BLEscrowCheck to verify key escrow'
Write-Output ''
