# BL008_BLReadinessCheck.ps1
# Scriptlet: BL008 - BitLocker Encryption Readiness Dry Run
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

Write-Output ''
Write-Output '=== BitLocker Encryption Readiness Dry Run ==='
Write-Output '[i]   Pre-flight check: Can this volume be encrypted right now?'
Write-Output ''

# Target the OS drive
$osDrive = $env:SystemDrive
if (-not $osDrive) { $osDrive = 'C:' }

# ============================================================
# Helper: Parse key-value from command output
# ============================================================
function Get-ParsedValue {
    param([string[]]$Lines, [string]$Label)
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match "^${Label}\s*[:](.+)$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ============================================================
# Section 0: Service Dependency Gate
# ============================================================
Write-Output '--- Service Dependencies ---'

$svcChecks = @(
    @{ Name = 'BDESVC'; Display = 'BitLocker Drive Encryption Service' },
    @{ Name = 'TBS';    Display = 'TPM Base Services' },
    @{ Name = 'RpcSs';  Display = 'Remote Procedure Call (RPC)' }
)

$svcIssues = 0
foreach ($svc in $svcChecks) {
    $svcObj = $null
    try {
        $svcObj = Get-Service -Name $svc.Name -ErrorAction Stop
    } catch {
        # Service may not exist
    }

    if (-not $svcObj) {
        Write-Output "[!!]  $($svc.Display) ($($svc.Name)): NOT FOUND"
        Write-Output "       This service is required for BitLocker encryption."
        $blockers.Add("Service $($svc.Name) not found")
        $svcIssues++
        $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = 'Service not found on this system.' })
        continue
    }

    $status = $svcObj.Status
    $startType = $svcObj.StartType

    if ($svc.Name -eq 'RpcSs') {
        # RpcSs must be running
        if ($status -ne 'Running') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): $status"
            Write-Output "       RPC must be running for BitLocker WMI operations."
            $blockers.Add("Service $($svc.Name) is $status (must be Running)")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "Status: $status. Must be Running." })
        } else {
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): Running"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = 'Running.' })
        }
    } elseif ($svc.Name -eq 'BDESVC') {
        # BDESVC is Manual (Trigger Start) by default -- Disabled is a problem
        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): DISABLED"
            Write-Output "       BDESVC startup type is Disabled. Encryption cannot proceed."
            $blockers.Add("Service BDESVC is Disabled")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "StartType: Disabled. Must not be Disabled." })
        } else {
            $detail = "Status: $status, StartType: $startType."
            if ($status -ne 'Running') {
                $detail += ' Not currently running (normal -- BDESVC is trigger-start).'
            }
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): $startType / $status"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = $detail })
        }
    } elseif ($svc.Name -eq 'TBS') {
        # TBS should be running or at least not Disabled
        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): DISABLED"
            Write-Output "       TPM Base Services is Disabled. TPM-backed encryption cannot proceed."
            $blockers.Add("Service TBS is Disabled")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "StartType: Disabled. Required for TPM operations." })
        } elseif ($status -ne 'Running') {
            Write-Output "[!]   $($svc.Display) ($($svc.Name)): $status"
            Write-Output "       TBS is not running. TPM communication may fail."
            $warnings.Add("Service TBS is $status")
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'WARN'; Detail = "Status: $status. TPM operations may fail." })
        } else {
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): Running"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = 'Running.' })
        }
    }
}

if ($svcIssues -eq 0) {
    Write-Output "[OK]  All required services are available."
}
Write-Output ''

# ============================================================
# Section 1: Volume State Assessment (manage-bde -status)
# ============================================================
Write-Output '--- Volume State (manage-bde -status) ---'

$manageBdeAvailable = $true
$bdeOutput = $null

try {
    $bdeOutput = & manage-bde.exe -status $osDrive 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $bdeOutput) {
        $manageBdeAvailable = $false
    }
} catch {
    $manageBdeAvailable = $false
}

if (-not $manageBdeAvailable -or -not $bdeOutput) {
    Write-Output "[!!]  manage-bde.exe is not available or failed to execute."
    Write-Output "       BitLocker feature may not be installed on this system."
    $blockers.Add('manage-bde.exe not available')
    $findings.Add([PSCustomObject]@{ Check = 'manage-bde availability'; Status = 'ISSUE'; Detail = 'manage-bde.exe not available or returned no output.' })
} else {
    $bdeLines = @($bdeOutput | ForEach-Object { "$_" })

    # Parse Conversion Status
    $conversionStatus = Get-ParsedValue -Lines $bdeLines -Label 'Conversion Status'
    if ($conversionStatus) {
        if ($conversionStatus -match 'Fully Decrypted') {
            Write-Output "[OK]  Conversion Status: $conversionStatus"
            Write-Output "       Volume is eligible for new encryption."
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'OK'; Detail = "$conversionStatus -- eligible for encryption." })
        } elseif ($conversionStatus -match 'Fully Encrypted') {
            # Check for ghost state (encrypted + protection off)
            $protStatus = Get-ParsedValue -Lines $bdeLines -Label 'Protection Status'
            if ($protStatus -and $protStatus -match 'Off') {
                Write-Output "[!!]  Conversion Status: $conversionStatus / Protection: Off"
                Write-Output '       GHOST STATE DETECTED: Volume appears encrypted but FVEK is stored in the clear.'
                Write-Output '       This is the "Waiting for Activation" state. Data is NOT protected.'
                Write-Output '       Remediation: manage-bde -off C: to fully decrypt, then re-encrypt cleanly.'
                $blockers.Add('Ghost state: FullyEncrypted with Protection Off (Waiting for Activation)')
                $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'ISSUE'; Detail = 'GHOST STATE: FullyEncrypted + Protection Off. Remediate with manage-bde -off.' })
            } else {
                Write-Output "[i]   Conversion Status: $conversionStatus / Protection: $protStatus"
                Write-Output '       Volume is already encrypted and protected. No action needed.'
                $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'INFO'; Detail = "Already encrypted. Protection: $protStatus." })
            }
        } elseif ($conversionStatus -match 'Encryption in Progress|Decryption in Progress') {
            Write-Output "[!!]  Conversion Status: $conversionStatus"
            Write-Output '       Volume is currently undergoing a conversion operation.'
            Write-Output '       Cannot start a new encryption while another is in progress.'
            $blockers.Add("Active conversion: $conversionStatus")
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'ISSUE'; Detail = "$conversionStatus -- cannot start new encryption." })
        } else {
            Write-Output "[!]   Conversion Status: $conversionStatus"
            Write-Output "       Unexpected conversion status. Investigate with BL001 BLStatusSnapshot."
            $warnings.Add("Unexpected conversion status: $conversionStatus")
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'WARN'; Detail = "Unexpected: $conversionStatus" })
        }
    } else {
        Write-Output "[!]   Could not parse Conversion Status from manage-bde output."
        $warnings.Add('Could not parse Conversion Status')
        $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'WARN'; Detail = 'Could not parse from manage-bde output.' })
    }

    # Parse Percentage Encrypted
    $pctEncrypted = Get-ParsedValue -Lines $bdeLines -Label 'Percentage Encrypted'
    if ($pctEncrypted) {
        $pctVal = $pctEncrypted -replace '[^0-9.]', ''
        if ($pctVal -and [double]$pctVal -gt 0 -and [double]$pctVal -lt 100) {
            Write-Output "[!!]  Percentage Encrypted: $pctEncrypted"
            Write-Output "       Partial encryption detected. Volume is in an incomplete state."
            $blockers.Add("Partial encryption: $pctEncrypted")
            $findings.Add([PSCustomObject]@{ Check = 'Percentage Encrypted'; Status = 'ISSUE'; Detail = "Partial: $pctEncrypted" })
        }
    }

    # Parse Encryption Method
    $encMethod = Get-ParsedValue -Lines $bdeLines -Label 'Encryption Method'
    if ($encMethod -and $encMethod -notmatch 'None') {
        if ($conversionStatus -and $conversionStatus -match 'Fully Decrypted') {
            Write-Output "[!]   Encryption Method: $encMethod (on a FullyDecrypted volume)"
            Write-Output '       Residual crypto metadata present. May be from a previous encryption attempt.'
            $warnings.Add("Residual encryption method: $encMethod on decrypted volume")
            $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'WARN'; Detail = "Residual metadata: $encMethod on decrypted volume." })
        } else {
            Write-Output "[i]   Encryption Method: $encMethod"
            $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'INFO'; Detail = $encMethod })
        }
    }

    # Parse Key Protectors section
    $kpSection = $false
    $kpCount = 0
    foreach ($line in $bdeLines) {
        if ($line -match 'Key Protectors') { $kpSection = $true; continue }
        if ($kpSection -and $line.Trim() -match '^(TPM|Numerical Password|External Key|Recovery Password|Startup Key|Password|Certificate)') {
            $kpCount++
        }
    }

    if ($kpCount -gt 0 -and $conversionStatus -and $conversionStatus -match 'Fully Decrypted') {
        Write-Output "[!!]  Key Protectors: $kpCount protector(s) found on a FullyDecrypted volume."
        Write-Output '       Orphaned protectors may block fresh encryption. Remove with manage-bde -protectors -delete.'
        $blockers.Add("$kpCount orphaned key protector(s) on decrypted volume")
        $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'ISSUE'; Detail = "$kpCount orphaned protector(s) on FullyDecrypted volume." })
    } elseif ($kpCount -eq 0 -and $conversionStatus -and $conversionStatus -match 'Fully Decrypted') {
        Write-Output "[OK]  No key protectors found. Clean slate for fresh encryption."
        $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'OK'; Detail = 'No protectors on decrypted volume. Clean slate.' })
    } elseif ($kpCount -gt 0) {
        Write-Output "[i]   Key Protectors: $kpCount protector(s) found."
        $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'INFO'; Detail = "$kpCount protector(s) present." })
    }
}

Write-Output ''

# ============================================================
# Section 2: WMI Encryption Readiness (Win32_EncryptableVolume)
# ============================================================
Write-Output '--- WMI Readiness (Win32_EncryptableVolume) ---'

$wmiAvailable = $true
$encVol = $null

try {
    $encVol = Get-CimInstance -Namespace 'ROOT\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter='$osDrive'" -ErrorAction Stop
} catch {
    $wmiAvailable = $false
}

if (-not $wmiAvailable -or -not $encVol) {
    Write-Output "[!]   Win32_EncryptableVolume WMI class not available for $osDrive."
    Write-Output '       The BitLocker WMI provider may not be registered. This can happen if the'
    Write-Output '       BitLocker feature is not installed or the MOF file is not compiled.'
    $warnings.Add('Win32_EncryptableVolume WMI not available')
    $findings.Add([PSCustomObject]@{ Check = 'WMI Readiness'; Status = 'WARN'; Detail = 'Win32_EncryptableVolume not available. BitLocker feature may not be installed.' })
} else {
    # GetConversionStatus
    $convResult = $null
    try {
        $convResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetConversionStatus' -ErrorAction Stop
    } catch { }

    $wmiConvStatus = 'Unknown'
    $wmiPct = 'Unknown'

    if ($convResult -and $convResult.ReturnValue -eq 0) {
        $convCode = $convResult.ConversionStatus
        $wmiPct = $convResult.EncryptionPercentage

        $convStatusMap = @{
            0 = 'FullyDecrypted'
            1 = 'FullyEncrypted'
            2 = 'EncryptionInProgress'
            3 = 'DecryptionInProgress'
            4 = 'EncryptionPaused'
            5 = 'DecryptionPaused'
        }
        if ($convStatusMap.ContainsKey([int]$convCode)) {
            $wmiConvStatus = $convStatusMap[[int]$convCode]
        } else {
            $wmiConvStatus = "Code $convCode"
        }

        if ([int]$convCode -eq 0) {
            Write-Output "[OK]  ConversionStatus: $wmiConvStatus (code $convCode)"
            Write-Output '       Volume is fully decrypted and eligible for encryption.'
            $findings.Add([PSCustomObject]@{ Check = 'WMI ConversionStatus'; Status = 'OK'; Detail = "$wmiConvStatus (EncryptionPercentage: $wmiPct%)" })
        } elseif ([int]$convCode -eq 1) {
            Write-Output "[i]   ConversionStatus: $wmiConvStatus (code $convCode). Already encrypted."
            $findings.Add([PSCustomObject]@{ Check = 'WMI ConversionStatus'; Status = 'INFO'; Detail = "$wmiConvStatus. Volume is already encrypted." })
        } else {
            Write-Output "[!!]  ConversionStatus: $wmiConvStatus (code $convCode)"
            Write-Output "       EncryptionPercentage: $wmiPct%. Volume is in a transitional state."
            $blockers.Add("WMI ConversionStatus: $wmiConvStatus")
            $findings.Add([PSCustomObject]@{ Check = 'WMI ConversionStatus'; Status = 'ISSUE'; Detail = "$wmiConvStatus -- transitional state." })
        }
    } else {
        $retVal = if ($convResult) { "0x{0:X8}" -f $convResult.ReturnValue } else { 'N/A' }
        Write-Output "[!]   GetConversionStatus returned: $retVal"
        Write-Output '       Could not determine volume conversion state via WMI.'
        $warnings.Add("WMI GetConversionStatus returned $retVal")
        $findings.Add([PSCustomObject]@{ Check = 'WMI ConversionStatus'; Status = 'WARN'; Detail = "GetConversionStatus returned $retVal" })
    }

    # GetProtectionStatus
    $protResult = $null
    try {
        $protResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetProtectionStatus' -ErrorAction Stop
    } catch { }

    if ($protResult -and $protResult.ReturnValue -eq 0) {
        $protCode = $protResult.ProtectionStatus
        $protStatusMap = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Unknown' }
        $protLabel = if ($protStatusMap.ContainsKey([int]$protCode)) { $protStatusMap[[int]$protCode] } else { "Code $protCode" }

        Write-Output "[i]   ProtectionStatus: $protLabel (code $protCode)"
        $findings.Add([PSCustomObject]@{ Check = 'WMI ProtectionStatus'; Status = 'INFO'; Detail = "$protLabel (code $protCode)" })
    }
}

Write-Output ''

# ============================================================
# Section 3: BCD Integrity (bcdedit /enum all)
# ============================================================
Write-Output '--- BCD Integrity ---'

$bcdOutput = $null
$bcdAvailable = $true

try {
    $bcdOutput = & bcdedit.exe /enum all 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $bcdOutput) {
        $bcdAvailable = $false
    }
} catch {
    $bcdAvailable = $false
}

if (-not $bcdAvailable -or -not $bcdOutput) {
    Write-Output "[!]   bcdedit.exe failed or is not available."
    Write-Output '       Cannot validate Boot Configuration Data integrity.'
    $warnings.Add('bcdedit not available or failed')
    $findings.Add([PSCustomObject]@{ Check = 'BCD Integrity'; Status = 'WARN'; Detail = 'bcdedit not available or failed.' })
} else {
    $bcdLines = @($bcdOutput | ForEach-Object { "$_" })
    $bcdIssues = 0

    # Parse into blocks
    $blocks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentBlock = $null
    $currentId = ''

    foreach ($line in $bcdLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^-+$') { continue }
        if ($trimmed -eq '') {
            if ($currentBlock) {
                $blocks.Add([PSCustomObject]@{ Id = $currentId; Lines = $currentBlock })
                $currentBlock = $null
                $currentId = ''
            }
            continue
        }
        if ($trimmed -match '^(Windows Boot Manager|Windows Boot Loader|Firmware Boot Manager)') {
            $currentBlock = [System.Collections.Generic.List[string]]::new()
            $currentId = $trimmed
        }
        if ($currentBlock) {
            $currentBlock.Add($trimmed)
        }
    }
    if ($currentBlock) {
        $blocks.Add([PSCustomObject]@{ Id = $currentId; Lines = $currentBlock })
    }

    # Find Boot Manager block
    $bootMgrFound = $false
    foreach ($block in $blocks) {
        if ($block.Id -match 'Windows Boot Manager') {
            $bootMgrFound = $true
            $bmDevice = Get-ParsedValue -Lines $block.Lines -Label 'device'
            if ($bmDevice) {
                if ($bmDevice -match 'unknown') {
                    Write-Output "[!!]  Boot Manager device: $bmDevice"
                    Write-Output '       Boot Manager points to an UNKNOWN volume. BCD is corrupted.'
                    Write-Output '       Remediation: bcdboot C:\Windows /s S: /f UEFI'
                    $blockers.Add('Boot Manager device is unknown -- BCD corrupted')
                    $bcdIssues++
                    $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager device'; Status = 'ISSUE'; Detail = "Device: $bmDevice -- UNKNOWN volume." })
                } else {
                    Write-Output "[OK]  Boot Manager device: $bmDevice"
                    $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager device'; Status = 'OK'; Detail = $bmDevice })
                }
            }
            break
        }
    }

    if (-not $bootMgrFound) {
        Write-Output "[!]   Could not locate Windows Boot Manager block in BCD."
        $warnings.Add('Boot Manager block not found in BCD')
        $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager'; Status = 'WARN'; Detail = 'Block not found in BCD output.' })
    }

    # Find current/default OS loader block
    $osLoaderFound = $false
    foreach ($block in $blocks) {
        if ($block.Id -match 'Windows Boot Loader') {
            # Check if this is the current/default
            $identifier = Get-ParsedValue -Lines $block.Lines -Label 'identifier'
            if ($identifier -and ($identifier -match '\{current\}' -or $identifier -match '\{default\}')) {
                $osLoaderFound = $true

                $osDevice = Get-ParsedValue -Lines $block.Lines -Label 'device'
                $osOsDevice = Get-ParsedValue -Lines $block.Lines -Label 'osdevice'

                if ($osDevice) {
                    if ($osDevice -match 'unknown') {
                        Write-Output "[!!]  OS Loader ($identifier) device: $osDevice"
                        Write-Output '       OS Loader device points to an UNKNOWN volume. BCD is broken.'
                        $blockers.Add("OS Loader device is unknown ($identifier)")
                        $bcdIssues++
                        $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader device ($identifier)"; Status = 'ISSUE'; Detail = "Device: $osDevice -- UNKNOWN." })
                    } else {
                        Write-Output "[OK]  OS Loader ($identifier) device: $osDevice"
                        $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader device ($identifier)"; Status = 'OK'; Detail = $osDevice })
                    }
                }

                if ($osOsDevice) {
                    if ($osOsDevice -match 'unknown') {
                        Write-Output "[!!]  OS Loader ($identifier) osdevice: $osOsDevice"
                        Write-Output '       OS Loader osdevice points to an UNKNOWN volume. BCD is broken.'
                        $blockers.Add("OS Loader osdevice is unknown ($identifier)")
                        $bcdIssues++
                        $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader osdevice ($identifier)"; Status = 'ISSUE'; Detail = "osdevice: $osOsDevice -- UNKNOWN." })
                    } else {
                        Write-Output "[OK]  OS Loader ($identifier) osdevice: $osOsDevice"
                        $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader osdevice ($identifier)"; Status = 'OK'; Detail = $osOsDevice })
                    }
                }

                break
            }
        }
    }

    if (-not $osLoaderFound) {
        Write-Output "[!]   Could not locate {current} or {default} OS Loader in BCD."
        $warnings.Add('OS Loader block not found for {current}/{default}')
        $findings.Add([PSCustomObject]@{ Check = 'BCD OS Loader'; Status = 'WARN'; Detail = 'Could not find {current} or {default} loader.' })
    }

    if ($bcdIssues -eq 0 -and $bootMgrFound -and $osLoaderFound) {
        Write-Output "[OK]  All BCD paths are consistent. Boot configuration appears healthy."
    }
}

Write-Output ''

# ============================================================
# Section 4: WinRE Health (reagentc /info)
# ============================================================
Write-Output '--- WinRE Health ---'

$reOutput = $null
$reAvailable = $true

try {
    $reOutput = & reagentc.exe /info 2>&1
} catch {
    $reAvailable = $false
}

if (-not $reAvailable -or -not $reOutput) {
    Write-Output "[!]   reagentc.exe failed or is not available."
    $warnings.Add('reagentc not available or failed')
    $findings.Add([PSCustomObject]@{ Check = 'WinRE Health'; Status = 'WARN'; Detail = 'reagentc not available or failed.' })
} else {
    $reLines = @($reOutput | ForEach-Object { "$_" })

    # Parse Windows RE status
    $reStatus = Get-ParsedValue -Lines $reLines -Label 'Windows RE status'
    if (-not $reStatus) {
        # Try alternate label (localization can change this)
        foreach ($line in $reLines) {
            if ($line -match 'Enabled|Disabled') {
                $reStatus = if ($line -match 'Enabled') { 'Enabled' } else { 'Disabled' }
                break
            }
        }
    }

    if ($reStatus) {
        if ($reStatus -match 'Enabled') {
            Write-Output "[OK]  Windows RE status: $reStatus"
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'OK'; Detail = 'Enabled.' })
        } else {
            Write-Output "[!!]  Windows RE status: $reStatus"
            Write-Output '       WinRE is DISABLED. Silent encryption (Intune/MDM) CANNOT proceed without WinRE.'
            Write-Output '       Remediation: reagentc /enable'
            Write-Output '       If that fails, the WinRE partition may be too small (CVE-2024-20666 fallout).'
            $blockers.Add('WinRE is Disabled -- silent encryption blocked')
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'ISSUE'; Detail = 'Disabled. Silent encryption blocked. Run reagentc /enable.' })
        }
    } else {
        Write-Output "[!]   Could not parse Windows RE status."
        $warnings.Add('Could not parse WinRE status')
        $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'WARN'; Detail = 'Could not parse status from reagentc output.' })
    }

    # Parse Windows RE location
    $reLocation = Get-ParsedValue -Lines $reLines -Label 'Windows RE location'
    if ($reLocation) {
        if ($reLocation -match '\\\\[?]\\\\GLOBALROOT' -or $reLocation -match 'harddisk\d+\\\\partition\d+') {
            Write-Output "[OK]  Windows RE location: $reLocation"
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Location'; Status = 'OK'; Detail = $reLocation })
        } elseif ($reLocation.Trim() -eq '' -or $reLocation -match 'not found|unavailable') {
            Write-Output "[!!]  Windows RE location: (empty or not found)"
            Write-Output '       WinRE image may be missing or corrupted.'
            $blockers.Add('WinRE location is empty or not found')
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Location'; Status = 'ISSUE'; Detail = 'Empty or not found. WinRE image may be missing.' })
        } else {
            Write-Output "[i]   Windows RE location: $reLocation"
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Location'; Status = 'INFO'; Detail = $reLocation })
        }
    }

    # Parse BCD identifier
    $reBcdId = Get-ParsedValue -Lines $reLines -Label 'BCD identifier'
    if ($reBcdId) {
        if ($reBcdId -match '\{00000000-0000-0000-0000-000000000000\}') {
            Write-Output "[!!]  BCD identifier: $reBcdId"
            Write-Output '       NULL GUID detected. Severe BCD-to-WinRE linkage failure.'
            Write-Output '       The boot manager cannot locate the recovery environment.'
            Write-Output '       Remediation: reagentc /setreimage /path <WinRE_path> then reagentc /enable'
            $blockers.Add('WinRE BCD identifier is null GUID -- severe linkage break')
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'ISSUE'; Detail = 'NULL GUID. Severe BCD/WinRE linkage failure.' })
        } elseif ($reBcdId -match '\{[0-9a-fA-F-]+\}') {
            Write-Output "[OK]  BCD identifier: $reBcdId (valid)"
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'OK'; Detail = "$reBcdId (valid)" })
        } else {
            Write-Output "[!]   BCD identifier: $reBcdId (unexpected format)"
            $warnings.Add("WinRE BCD identifier unexpected: $reBcdId")
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'WARN'; Detail = "$reBcdId (unexpected format)" })
        }
    }
}

Write-Output ''

# ============================================================
# Section 5: PCR Validation Profile (manage-bde -protectors -get)
# ============================================================
Write-Output '--- PCR Validation Profile ---'

$pcrOutput = $null

if ($manageBdeAvailable) {
    try {
        $pcrOutput = & manage-bde.exe -protectors -get $osDrive 2>&1
    } catch { }
}

if (-not $pcrOutput) {
    Write-Output "[i]   manage-bde -protectors -get not available or returned no output."
    Write-Output '       PCR validation profile cannot be assessed.'
    $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'manage-bde protectors output not available.' })
} else {
    $pcrLines = @($pcrOutput | ForEach-Object { "$_" })

    # Look for TPM protector block and PCR Validation Profile
    $tpmBlockFound = $false
    $pcrProfile = $null
    $inTpmBlock = $false

    foreach ($line in $pcrLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*TPM\s*:?\s*$' -or $trimmed -match '^\s*TPM\s*$') {
            $inTpmBlock = $true
            $tpmBlockFound = $true
            continue
        }
        if ($inTpmBlock) {
            if ($trimmed -match 'PCR Validation Profile') {
                $pcrProfile = $trimmed -replace '.*PCR Validation Profile\s*[:]?\s*', ''
                break
            }
            # Exit TPM block if we hit another protector type
            if ($trimmed -match '^\s*(Numerical Password|External Key|Recovery Password|Startup Key|Password|Certificate)\s*:?\s*$') {
                $inTpmBlock = $false
            }
        }
    }

    if (-not $tpmBlockFound) {
        Write-Output "[i]   No TPM protector found on $osDrive."
        Write-Output '       This is expected if the volume is not yet encrypted.'
        Write-Output '       PCR binding will be established when encryption begins.'
        $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'No TPM protector found. Expected if volume is not encrypted.' })
    } elseif ($pcrProfile) {
        # Analyze PCR profile
        $pcrNumbers = @($pcrProfile -replace '[^0-9,\s]', '' -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })

        $isIdeal = ($pcrNumbers.Count -eq 2 -and $pcrNumbers -contains 7 -and $pcrNumbers -contains 11)
        $isDegraded = ($pcrNumbers -contains 0 -and $pcrNumbers -contains 2 -and $pcrNumbers -contains 4 -and $pcrNumbers -contains 11 -and $pcrNumbers -notcontains 7)

        if ($isIdeal) {
            Write-Output "[OK]  PCR Validation Profile: $pcrProfile"
            Write-Output '       Ideal binding: PCR 7 (Secure Boot) + PCR 11 (BitLocker Access Control).'
            Write-Output '       Firmware updates will NOT trigger recovery key prompts.'
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'OK'; Detail = "$pcrProfile -- ideal Secure Boot binding." })
        } elseif ($isDegraded) {
            Write-Output "[!!]  PCR Validation Profile: $pcrProfile"
            Write-Output '       DEGRADED LEGACY PROFILE: PCR 0,2,4,11 detected.'
            Write-Output '       The system fell back to legacy PCR measurements instead of PCR 7 (Secure Boot).'
            Write-Output '       This typically indicates unsigned Option ROM (OROM) interference from dGPU or RAID controller.'
            Write-Output '       Impact: minor firmware/driver changes WILL trigger BitLocker recovery key prompts.'
            Write-Output '       Resolution: update BIOS/UEFI firmware, or disable Secure Boot for the offending device.'
            Write-Output '       This is NOT fixable from the OS -- requires BIOS/vendor action.'
            $warnings.Add('Degraded PCR profile (0,2,4,11) -- OROM fallback detected')
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'WARN'; Detail = "$pcrProfile -- degraded legacy profile. OROM interference likely." })
        } else {
            Write-Output "[i]   PCR Validation Profile: $pcrProfile"
            Write-Output '       Custom or non-standard PCR binding detected.'
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = "$pcrProfile -- non-standard profile." })
        }
    } else {
        Write-Output "[i]   TPM protector found but no PCR Validation Profile line detected."
        $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'TPM protector present but PCR profile not found in output.' })
    }
}

Write-Output ''

# ============================================================
# Readiness Verdict
# ============================================================
Write-Output '--- Readiness Verdict ---'

$blockerCount = $blockers.Count
$warningCount = $warnings.Count

if ($blockerCount -eq 0 -and $warningCount -eq 0) {
    Write-Output 'RESULT: READY FOR ENCRYPTION. No blocking conditions detected.'
} elseif ($blockerCount -eq 0 -and $warningCount -gt 0) {
    Write-Output "RESULT: CONDITIONALLY READY. $warningCount warning(s) found but no hard blockers."
    Write-Output '        Review warnings above before proceeding with encryption.'
} else {
    Write-Output "RESULT: NOT READY. $blockerCount blocker(s) and $warningCount warning(s) detected."
    Write-Output '        Address the issues marked [!!] above before attempting encryption.'
    Write-Output ''
    Write-Output '        Blockers:'
    foreach ($b in $blockers) {
        Write-Output "        - $b"
    }
}

if ($warningCount -gt 0 -and $blockerCount -gt 0) {
    Write-Output ''
    Write-Output '        Warnings:'
    foreach ($w in $warnings) {
        Write-Output "        - $w"
    }
}

Write-Output ''
Write-Output 'NEXT:   If WinRE disabled         -> run: reagentc /enable'
Write-Output '        If boot config broken      -> run: bcdboot C:\Windows /s S: /f UEFI'
Write-Output '        If ghost state detected    -> run: manage-bde -off C: (then re-encrypt)'
Write-Output '        If orphaned protectors     -> run: manage-bde -protectors -delete C: -type RecoveryPassword'
Write-Output '        If TPM issues              -> run BL002 BLTpmHealth'
Write-Output '        If hardware prerequisites  -> run BL003 BLHardwarePrereqs'
Write-Output '        If policy issues           -> run BL006 BLPolicyConflict'
Write-Output '        If all checks pass         -> system is ready for encryption'
Write-Output ''
