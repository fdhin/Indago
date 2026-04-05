# BL006_BLPolicyConflict.ps1
# Scriptlet: BL006 - BitLocker Group Policy vs MDM Conflict Detection
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# Check 1 -- GPO-Delivered BitLocker Settings (FVE Registry)
# ============================================================
Write-Output ''
Write-Output '=== BitLocker Group Policy vs MDM Conflict Detection ==='
Write-Output ''
Write-Output '--- GPO BitLocker Settings (FVE Registry) ---'

$fvePath = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
$fveExists = Test-Path $fvePath
$fveValues = @{}
$fveValueCount = 0

# Cipher method decode table
$cipherMap = @{
    3 = 'AES-CBC 128-bit'
    4 = 'AES-CBC 256-bit'
    6 = 'XTS-AES 128-bit'
    7 = 'XTS-AES 256-bit'
}

# TPM usage decode table
$tpmUsageMap = @{
    0 = 'Do not allow'
    1 = 'Require'
    2 = 'Allow'
}

if (-not $fveExists) {
    $findings.Add([PSCustomObject]@{
        Check  = 'GPO BitLocker Settings'
        Status = 'OK'
        Detail = 'HKLM:\...\FVE path does not exist. No GPO BitLocker settings are configured.'
    })
} else {
    # Read and decode known FVE values
    $fveSettingsDefs = @(
        @{ Name = 'EncryptionMethodWithXtsOs';  Label = 'OS Drive Cipher (GPO)';     Map = $cipherMap }
        @{ Name = 'EncryptionMethodWithXtsFdv';  Label = 'Fixed Drive Cipher (GPO)';   Map = $cipherMap }
        @{ Name = 'EncryptionMethodWithXtsRdv';  Label = 'Removable Drive Cipher (GPO)'; Map = $cipherMap }
        @{ Name = 'UseTPM';        Label = 'TPM Usage (GPO)';        Map = $tpmUsageMap }
        @{ Name = 'UseTPMPIN';     Label = 'Startup PIN (GPO)';      Map = $tpmUsageMap }
        @{ Name = 'UseTPMKey';     Label = 'Startup Key (GPO)';      Map = $tpmUsageMap }
        @{ Name = 'UseTPMKeyPIN';  Label = 'TPM+Key+PIN (GPO)';      Map = $tpmUsageMap }
        @{ Name = 'MinimumPIN';    Label = 'Minimum PIN Length (GPO)'; Map = $null }
        @{ Name = 'OSRecovery';    Label = 'OS Recovery (GPO)';       Map = $null }
        @{ Name = 'OSRequireActiveDirectoryBackup'; Label = 'Require AD Backup (GPO)'; Map = $null }
        @{ Name = 'OSActiveDirectoryInfoToStore';   Label = 'AD Info to Store (GPO)';  Map = $null }
        @{ Name = 'EnableBDEWithNoTPM'; Label = 'Allow BDE Without TPM (GPO)'; Map = $null }
    )

    foreach ($def in $fveSettingsDefs) {
        try {
            $regItem = Get-ItemProperty -Path $fvePath -Name $def.Name -ErrorAction Stop
            $val = $regItem.($def.Name)
            $fveValues[$def.Name] = $val
            $fveValueCount++

            $decoded = $val
            if ($null -ne $def.Map -and $def.Map.ContainsKey([int]$val)) {
                $decoded = "$val ($($def.Map[[int]$val]))"
            }

            $findings.Add([PSCustomObject]@{
                Check  = $def.Label
                Status = 'INFO'
                Detail = "$($def.Name) = $decoded"
            })
        } catch {
            # Value not present -- skip silently
        }
    }

    if ($fveValueCount -eq 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'GPO BitLocker Settings'
            Status = 'OK'
            Detail = 'FVE registry path exists but contains no configured settings.'
        })
    }

    # Check for legacy platform validation subkeys
    $biosValidation = Test-Path (Join-Path $fvePath 'OSPlatformValidation_BIOS')
    $uefiValidation = Test-Path (Join-Path $fvePath 'OSPlatformValidation_UEFI')

    if ($biosValidation -or $uefiValidation) {
        $subkeys = @()
        if ($biosValidation) { $subkeys += 'OSPlatformValidation_BIOS' }
        if ($uefiValidation) { $subkeys += 'OSPlatformValidation_UEFI' }
        $findings.Add([PSCustomObject]@{
            Check  = 'Legacy PCR Validation Profiles (GPO)'
            Status = 'ISSUE'
            Detail = "Legacy platform validation subkey(s) found: $($subkeys -join ', '). These are a primary cause of silent encryption failure on Intune-managed devices (HRESULT 0x80310059). Remove these subkeys from FVE."
        })
    }
}

# ============================================================
# Check 2 -- MDM-Delivered BitLocker Settings (PolicyManager)
# ============================================================
Write-Output ''
Write-Output '--- MDM BitLocker Settings (PolicyManager) ---'

$mdmPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker'
$mdmExists = Test-Path $mdmPath
$mdmValues = @{}

if (-not $mdmExists) {
    $findings.Add([PSCustomObject]@{
        Check  = 'MDM BitLocker Settings'
        Status = 'INFO'
        Detail = 'PolicyManager BitLocker path does not exist. No MDM BitLocker settings are present.'
    })
} else {
    # RequireDeviceEncryption
    try {
        $rde = (Get-ItemProperty -Path $mdmPath -Name 'RequireDeviceEncryption' -ErrorAction Stop).RequireDeviceEncryption
        $mdmValues['RequireDeviceEncryption'] = $rde
        if ($rde -eq 1) {
            $findings.Add([PSCustomObject]@{
                Check  = 'RequireDeviceEncryption (MDM)'
                Status = 'OK'
                Detail = "RequireDeviceEncryption = 1. MDM requires device encryption."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'RequireDeviceEncryption (MDM)'
                Status = 'INFO'
                Detail = "RequireDeviceEncryption = $rde. MDM encryption not actively required."
            })
        }
    } catch {
        $findings.Add([PSCustomObject]@{
            Check  = 'RequireDeviceEncryption (MDM)'
            Status = 'INFO'
            Detail = 'RequireDeviceEncryption not set. MDM may not be managing BitLocker.'
        })
    }

    # EncryptionMethodByDriveType (XML)
    $mdmCipher = $null
    try {
        $emXml = (Get-ItemProperty -Path $mdmPath -Name 'EncryptionMethodByDriveType' -ErrorAction Stop).EncryptionMethodByDriveType
        if ($emXml) {
            $mdmValues['EncryptionMethodByDriveType'] = $emXml
            # Parse XML for OS drive cipher
            if ($emXml -match 'EncryptionMethodWithXtsOsDropDown_Name[^>]*value="([^"]*)"') {
                $mdmCipher = [int]$Matches[1]
                $cipherText = if ($cipherMap.ContainsKey($mdmCipher)) { $cipherMap[$mdmCipher] } else { "Unknown ($mdmCipher)" }
                $findings.Add([PSCustomObject]@{
                    Check  = 'OS Drive Cipher (MDM)'
                    Status = 'INFO'
                    Detail = "EncryptionMethodByDriveType OS cipher = $mdmCipher ($cipherText)"
                })
            } elseif ($emXml -match 'EncryptionMethodWithXtsOsDropDown_Name') {
                # Try alternate XML format
                $findings.Add([PSCustomObject]@{
                    Check  = 'OS Drive Cipher (MDM)'
                    Status = 'INFO'
                    Detail = "EncryptionMethodByDriveType present but cipher value could not be parsed from XML."
                })
            }
        }
    } catch { }

    # SystemDrivesRequireStartupAuthentication (XML)
    $mdmPinRequired = $null
    try {
        $saXml = (Get-ItemProperty -Path $mdmPath -Name 'SystemDrivesRequireStartupAuthentication' -ErrorAction Stop).SystemDrivesRequireStartupAuthentication
        if ($saXml) {
            $mdmValues['SystemDrivesRequireStartupAuthentication'] = $saXml
            # Check for PIN requirement in the XML
            if ($saXml -match 'ConfigureTPMPINUsageDropDown_Name[^>]*value="([^"]*)"') {
                $pinVal = [int]$Matches[1]
                $mdmPinRequired = $pinVal
                $pinText = if ($tpmUsageMap.ContainsKey($pinVal)) { $tpmUsageMap[$pinVal] } else { "Unknown ($pinVal)" }
                $findings.Add([PSCustomObject]@{
                    Check  = 'Startup PIN Requirement (MDM)'
                    Status = 'INFO'
                    Detail = "SystemDrivesRequireStartupAuthentication PIN = $pinVal ($pinText)"
                })
            }
        }
    } catch { }

    # SystemDrivesMinimumPINLength
    $mdmMinPin = $null
    try {
        $mp = (Get-ItemProperty -Path $mdmPath -Name 'SystemDrivesMinimumPINLength' -ErrorAction Stop).SystemDrivesMinimumPINLength
        if ($null -ne $mp) {
            $mdmMinPin = $mp
            $mdmValues['SystemDrivesMinimumPINLength'] = $mp
            $findings.Add([PSCustomObject]@{
                Check  = 'Minimum PIN Length (MDM)'
                Status = 'INFO'
                Detail = "SystemDrivesMinimumPINLength = $mp"
            })
        }
    } catch { }

    # AllowWarningForOtherDiskEncryption
    try {
        $aw = (Get-ItemProperty -Path $mdmPath -Name 'AllowWarningForOtherDiskEncryption' -ErrorAction Stop).AllowWarningForOtherDiskEncryption
        if ($null -ne $aw) {
            $mdmValues['AllowWarningForOtherDiskEncryption'] = $aw
            $warnText = if ($aw -eq 0) { 'Silent encryption enabled (no user warnings)' } else { 'User warnings displayed' }
            $findings.Add([PSCustomObject]@{
                Check  = 'Silent Encryption (MDM)'
                Status = 'INFO'
                Detail = "AllowWarningForOtherDiskEncryption = $aw. $warnText."
            })
        }
    } catch { }
}
# ============================================================
# Check 3 -- Conflict Detection (GPO vs MDM)
# ============================================================
Write-Output ''
Write-Output '--- Conflict Detection ---'

$conflictsFound = $false

if ($fveExists -and $fveValueCount -gt 0 -and $mdmExists) {
    # 3a -- Encryption Method conflict
    $gpoCipher = $null
    if ($fveValues.ContainsKey('EncryptionMethodWithXtsOs')) {
        $gpoCipher = [int]$fveValues['EncryptionMethodWithXtsOs']
    }

    if ($null -ne $gpoCipher -and $null -ne $mdmCipher) {
        if ($gpoCipher -ne $mdmCipher) {
            $gpoText = if ($cipherMap.ContainsKey($gpoCipher)) { $cipherMap[$gpoCipher] } else { "Unknown ($gpoCipher)" }
            $mdmText = if ($cipherMap.ContainsKey($mdmCipher)) { $cipherMap[$mdmCipher] } else { "Unknown ($mdmCipher)" }
            $findings.Add([PSCustomObject]@{
                Check  = 'Encryption Method Conflict'
                Status = 'ISSUE'
                Detail = "GPO: $gpoText ($gpoCipher). MDM: $mdmText ($mdmCipher). GPO and MDM disagree on encryption cipher. GPO takes precedence unless MDMWinsOverGP is set -- and even then, BitLocker CSP settings may not be covered by MDMWinsOverGP."
            })
            $conflictsFound = $true
        } else {
            $cText = if ($cipherMap.ContainsKey($gpoCipher)) { $cipherMap[$gpoCipher] } else { "Unknown ($gpoCipher)" }
            $findings.Add([PSCustomObject]@{
                Check  = 'Encryption Method'
                Status = 'OK'
                Detail = "GPO and MDM agree: $cText ($gpoCipher). No cipher conflict."
            })
        }
    } elseif ($null -ne $gpoCipher -and $null -eq $mdmCipher) {
        $gpoText = if ($cipherMap.ContainsKey($gpoCipher)) { $cipherMap[$gpoCipher] } else { "Unknown ($gpoCipher)" }
        $findings.Add([PSCustomObject]@{
            Check  = 'Encryption Method'
            Status = 'INFO'
            Detail = "GPO sets cipher to $gpoText ($gpoCipher). MDM cipher not configured. GPO value will be used."
        })
    }

    # 3b -- Startup Authentication conflict (PIN)
    $gpoPinRequired = $null
    if ($fveValues.ContainsKey('UseTPMPIN')) {
        $gpoPinRequired = [int]$fveValues['UseTPMPIN']
    }

    if ($null -ne $gpoPinRequired -and $null -ne $mdmPinRequired) {
        if ($gpoPinRequired -ne $mdmPinRequired) {
            $gpoText = if ($tpmUsageMap.ContainsKey($gpoPinRequired)) { $tpmUsageMap[$gpoPinRequired] } else { "Unknown ($gpoPinRequired)" }
            $mdmText = if ($tpmUsageMap.ContainsKey($mdmPinRequired)) { $tpmUsageMap[$mdmPinRequired] } else { "Unknown ($mdmPinRequired)" }
            $conflictDetail = "GPO: $gpoText ($gpoPinRequired). MDM: $mdmText ($mdmPinRequired)."
            if ($gpoPinRequired -eq 1) {
                $conflictDetail += ' GPO REQUIRES startup PIN. If MDM expects silent encryption (TPM-only), this will block it entirely.'
            }
            $findings.Add([PSCustomObject]@{
                Check  = 'Startup PIN Conflict'
                Status = 'ISSUE'
                Detail = $conflictDetail
            })
            $conflictsFound = $true
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Startup PIN'
                Status = 'OK'
                Detail = "GPO and MDM agree on startup PIN setting ($gpoPinRequired). No conflict."
            })
        }
    } elseif ($null -ne $gpoPinRequired -and $gpoPinRequired -eq 1) {
        # GPO requires PIN with no MDM counterpart -- dangerous for silent encryption
        $silentEnc = $false
        if ($mdmValues.ContainsKey('AllowWarningForOtherDiskEncryption')) {
            if ($mdmValues['AllowWarningForOtherDiskEncryption'] -eq 0) { $silentEnc = $true }
        }
        if ($silentEnc) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Startup PIN vs Silent Encryption'
                Status = 'ISSUE'
                Detail = "GPO REQUIRES startup PIN (UseTPMPIN=1) but MDM is configured for silent encryption (AllowWarningForOtherDiskEncryption=0). Silent encryption requires TPM-only -- a mandatory PIN blocks it."
            })
            $conflictsFound = $true
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Startup PIN (GPO)'
                Status = 'WARN'
                Detail = "GPO requires startup PIN (UseTPMPIN=1). MDM startup auth not configured. PIN requirement may block silent encryption if configured later."
            })
        }
    }

    # 3c -- Recovery Password / AD Backup deadlock
    $gpoAdBackup = $null
    if ($fveValues.ContainsKey('OSRequireActiveDirectoryBackup')) {
        $gpoAdBackup = [int]$fveValues['OSRequireActiveDirectoryBackup']
    }

    if ($null -ne $gpoAdBackup -and $gpoAdBackup -eq 1) {
        # Check if machine is MDM-managed (Intune-only or hybrid)
        try {
            $isDomainJoined = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
        } catch {
            $isDomainJoined = $false
        }

        if (-not $isDomainJoined) {
            $findings.Add([PSCustomObject]@{
                Check  = 'AD Backup Deadlock'
                Status = 'ISSUE'
                Detail = "GPO requires AD DS backup (OSRequireActiveDirectoryBackup=1) but machine is NOT domain-joined. BitLocker cannot escrow to AD DS without domain-controller access. This creates a deadlock -- encryption will never succeed (HRESULT 0x80072f9a). Remove this FVE setting."
            })
            $conflictsFound = $true
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'AD Backup Requirement (GPO)'
                Status = 'WARN'
                Detail = "GPO requires AD DS backup (OSRequireActiveDirectoryBackup=1). Machine is domain-joined, so AD backup may succeed, but if Intune also manages BitLocker, this creates a dual-escrow requirement."
            })
        }
    }

    # 3d -- Minimum PIN Length mismatch
    $gpoMinPin = $null
    if ($fveValues.ContainsKey('MinimumPIN')) {
        $gpoMinPin = [int]$fveValues['MinimumPIN']
    }

    if ($null -ne $gpoMinPin -and $null -ne $mdmMinPin) {
        if ($gpoMinPin -ne $mdmMinPin) {
            $findings.Add([PSCustomObject]@{
                Check  = 'Minimum PIN Length Mismatch'
                Status = 'WARN'
                Detail = "GPO: $gpoMinPin. MDM: $mdmMinPin. PIN length requirements differ between GPO and MDM."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Minimum PIN Length'
                Status = 'OK'
                Detail = "GPO and MDM agree: minimum PIN length = $gpoMinPin. No conflict."
            })
        }
    }

    if (-not $conflictsFound) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Conflict Summary'
            Status = 'OK'
            Detail = 'No direct policy conflicts detected between GPO and MDM BitLocker settings.'
        })
    }
} elseif (-not $fveExists -or $fveValueCount -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Conflict Summary'
        Status = 'OK'
        Detail = 'No GPO BitLocker settings present. No GPO vs MDM conflicts possible.'
    })
} elseif (-not $mdmExists) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Conflict Summary'
        Status = 'INFO'
        Detail = 'No MDM BitLocker settings present. GPO settings active but no MDM counterpart to compare.'
    })
}

# ============================================================
# Check 4 -- MDMWinsOverGP Assessment
# ============================================================
Write-Output ''
Write-Output '--- MDMWinsOverGP Assessment ---'

$mdmWinsValue = $null
$mdmWinsSource = $null

# Research doc path (authoritative per Microsoft docs)
$mdmWinsPath1 = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'
try {
    $v1 = (Get-ItemProperty -Path $mdmWinsPath1 -Name 'MDMWinsOverGP' -ErrorAction Stop).MDMWinsOverGP
    $mdmWinsValue = $v1
    $mdmWinsSource = 'PolicyManager'
} catch { }

$hasFveSettings = ($fveExists -and $fveValueCount -gt 0)

if ($null -ne $mdmWinsValue -and $mdmWinsValue -eq 1) {
    if ($hasFveSettings) {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'ISSUE'
            Detail = "MDMWinsOverGP = 1 (source: $mdmWinsSource) BUT GPO BitLocker settings exist in FVE. FALSE SENSE OF SECURITY -- MDMWinsOverGP does NOT fully apply to settings governed by the BitLocker CSP. Legacy FVE registry values will continue to override MDM policy for settings without a direct Policy CSP mapping."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'INFO'
            Detail = "MDMWinsOverGP = 1 (source: $mdmWinsSource). No GPO BitLocker settings in FVE. Setting is active but no conflicts to resolve."
        })
    }
} elseif ($null -ne $mdmWinsValue -and $mdmWinsValue -eq 0) {
    if ($hasFveSettings) {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'ISSUE'
            Detail = "MDMWinsOverGP = 0 (source: $mdmWinsSource) AND GPO BitLocker settings exist. GPO takes full precedence. Intune BitLocker policy may be silently ignored."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'OK'
            Detail = "MDMWinsOverGP = 0 (source: $mdmWinsSource). GPO takes precedence, but no GPO BitLocker settings exist. Standard behavior."
        })
    }
} else {
    # Not set
    if ($hasFveSettings -and $mdmExists) {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'ISSUE'
            Detail = "MDMWinsOverGP is NOT set. Both GPO and MDM BitLocker settings exist. Default behavior: GPO takes precedence. Intune BitLocker policy may be silently ignored."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'MDMWinsOverGP Assessment'
            Status = 'OK'
            Detail = 'MDMWinsOverGP is not set. Standard GPO precedence (default behavior). No active conflict detected.'
        })
    }
}

# ============================================================
# Check 5 -- Orphaned GPO Settings Detection
# ============================================================
Write-Output ''
Write-Output '--- Orphaned GPO Settings ---'

if ($hasFveSettings) {
    # Determine domain-join and MDM state
    $isDomainJoined = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $isDomainJoined = [bool]$cs.PartOfDomain
    } catch { }

    $isMdmManaged = $mdmExists

    if (-not $isDomainJoined) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Orphaned GPO Settings'
            Status = 'ISSUE'
            Detail = "Machine is NOT domain-joined but HKLM:\SOFTWARE\Policies\Microsoft\FVE contains $fveValueCount setting(s). These are tattooed from a previous domain membership and will indefinitely override MDM BitLocker policy. Clear HKLM:\SOFTWARE\Policies\Microsoft\FVE manually or via BL010 BLForceEncrypt."
        })
    } elseif ($isDomainJoined -and $isMdmManaged) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Hybrid Environment GPO Settings'
            Status = 'WARN'
            Detail = "Machine is domain-joined AND Intune-managed (hybrid). $fveValueCount GPO BitLocker setting(s) exist in FVE. In hybrid environments, GPO settings can silently override Intune policy. Review whether these GPO settings are intentional."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'GPO Settings Origin'
            Status = 'OK'
            Detail = "Machine is domain-joined. $fveValueCount GPO BitLocker setting(s) in FVE are expected from Active Directory Group Policy."
        })
    }

    # Flag specific dangerous orphaned patterns
    if ($biosValidation -or $uefiValidation) {
        # Already flagged in Check 1 -- skip duplicate
    }

    if ($null -ne $gpoAdBackup -and $gpoAdBackup -eq 1 -and -not $isDomainJoined) {
        # Already flagged in Check 3 -- skip duplicate
    }

    if ($null -ne $gpoPinRequired -and $gpoPinRequired -eq 1 -and -not $isDomainJoined) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Orphaned PIN Requirement'
            Status = 'ISSUE'
            Detail = "Orphaned GPO setting UseTPMPIN=1 (Require startup PIN) is tattooed from a previous domain membership. This blocks silent MDM encryption on a non-domain-joined device. Remove this setting from HKLM:\SOFTWARE\Policies\Microsoft\FVE."
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Orphaned GPO Settings'
        Status = 'OK'
        Detail = 'No GPO BitLocker settings in FVE registry. No orphaned settings possible.'
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
    Write-Output 'RESULT: No policy conflicts detected. GPO and MDM BitLocker settings are consistent.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] above."
}

Write-Output ''
Write-Output 'NEXT:   If conflicts found         -> set MDMWinsOverGP=1, or remove conflicting GPO settings'
Write-Output '        If orphaned GPO settings   -> clear HKLM:\SOFTWARE\Policies\Microsoft\FVE manually'
Write-Output '        If no conflicts            -> run BL007 BLEventAnalysis for the failure timeline'
Write-Output ''
