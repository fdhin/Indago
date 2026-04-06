# BL003_BLHardwarePrereqs.ps1
# Scriptlet: BL003 - Hardware & Firmware Prerequisites
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Hardware & Firmware Prerequisites ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Check 1: Boot Mode (UEFI vs Legacy BIOS)
# ---------------------------------------------------------------
Write-Output '--- Boot Mode ---'

$isUEFI = $null

# Primary: Confirm-SecureBootUEFI behavior
# - Returns $true/$false = UEFI
# - Throws "not supported on this platform" = Legacy BIOS
try {
    $sbResult = Confirm-SecureBootUEFI -ErrorAction Stop
    # If we get here without exception, the machine is UEFI
    $isUEFI = $true
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -like '*not supported*' -or $errMsg -like '*Cmdlet not supported*') {
        $isUEFI = $false
    } else {
        # Unexpected error -- try fallback
        $isUEFI = $null
    }
}

# Fallback: Check SecureBoot registry key existence (UEFI indicator)
if ($null -eq $isUEFI) {
    $sbStatePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
    if (Test-Path -Path $sbStatePath -ErrorAction SilentlyContinue) {
        $isUEFI = $true
    } else {
        # Second fallback: bcdedit path check
        try {
            $bcdOutput = & bcdedit /enum '{current}' 2>&1
            $bcdText = ($bcdOutput | Out-String)
            if ($bcdText -match '\.efi') {
                $isUEFI = $true
            } elseif ($bcdText -match 'winload\.exe') {
                $isUEFI = $false
            }
        } catch { }
    }
}

if ($isUEFI -eq $true) {
    Write-Output '[OK]  Boot Mode'
    Write-Output '       UEFI. Compatible with Intune silent encryption.'
} elseif ($isUEFI -eq $false) {
    Write-Output '[!!]  Boot Mode'
    Write-Output '       Legacy BIOS. Silent BitLocker encryption is NOT supported in Legacy mode.'
    Write-Output '       Convert to UEFI using MBR2GPT.exe (requires planning and downtime).'
    Write-Output '       This cannot be fixed by a script -- firmware configuration change required.'
    $issueCount++
} else {
    Write-Output '[!]   Boot Mode'
    Write-Output '       Could not determine boot mode (UEFI or Legacy BIOS).'
    Write-Output '       Check BIOS settings manually.'
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: Secure Boot Status
# ---------------------------------------------------------------
Write-Output '--- Secure Boot ---'

if ($isUEFI -eq $false) {
    Write-Output '[i]   Secure Boot'
    Write-Output '       Not available (Legacy BIOS). Convert to UEFI first.'
} else {
    $secureBootEnabled = $null

    # Primary: Confirm-SecureBootUEFI return value
    try {
        $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
    } catch { }

    # Fallback: registry
    if ($null -eq $secureBootEnabled) {
        $sbStatePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
        try {
            $sbReg = Get-ItemProperty -Path $sbStatePath -ErrorAction Stop
            if ($null -ne $sbReg -and ($sbReg.PSObject.Properties.Name -contains 'UEFISecureBootEnabled')) {
                $secureBootEnabled = ([int]$sbReg.UEFISecureBootEnabled -eq 1)
            }
        } catch { }
    }

    if ($secureBootEnabled -eq $true) {
        Write-Output '[OK]  Secure Boot'
        Write-Output '       Enabled. PCR 7 validation will work for BitLocker binding.'
    } elseif ($secureBootEnabled -eq $false) {
        Write-Output '[!!]  Secure Boot'
        Write-Output '       Disabled. BitLocker PCR 7 binding will fail.'
        Write-Output '       Compliance policies requiring Secure Boot will report non-compliant.'
        Write-Output '       Enable Secure Boot in BIOS/UEFI settings.'
        Write-Output '       This cannot be fixed by a script -- tech must enter BIOS setup.'
        $issueCount++
    } else {
        Write-Output '[!]   Secure Boot'
        Write-Output '       Could not determine Secure Boot status.'
        $warnCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Disk Partition Scheme (GPT vs MBR)
# ---------------------------------------------------------------
Write-Output '--- Disk Partition Scheme ---'

$partStyle = $null
$osDiskNumber = $null

try {
    # Find the boot disk
    $disks = @(Get-Disk -ErrorAction Stop)
    foreach ($disk in $disks) {
        if ($disk.IsBoot -or $disk.IsSystem) {
            $osDiskNumber = $disk.Number
            $partStyle = $disk.PartitionStyle
            break
        }
    }
    # Fallback to Disk 0 if no boot disk flagged
    if ($null -eq $osDiskNumber -and $disks.Count -gt 0) {
        $osDiskNumber = $disks[0].Number
        $partStyle = $disks[0].PartitionStyle
    }
} catch {
    # CIM fallback
    try {
        $diskParts = @(Get-CimInstance -ClassName Win32_DiskPartition -Filter "DiskIndex = 0" -ErrorAction Stop)
        if ($diskParts.Count -gt 0) {
            $osDiskNumber = 0
            $typeStr = $diskParts[0].Type
            if ($typeStr -like 'GPT*') {
                $partStyle = 'GPT'
            } else {
                $partStyle = 'MBR'
            }
        }
    } catch { }
}

if ($partStyle -eq 'GPT') {
    Write-Output '[OK]  Partition Style'
    Write-Output "       GPT (Disk $osDiskNumber). Compatible with UEFI and BitLocker."
} elseif ($partStyle -eq 'MBR') {
    Write-Output '[!!]  Partition Style'
    Write-Output "       MBR (Disk $osDiskNumber). BitLocker with UEFI requires GPT."
    Write-Output '       Convert to GPT using MBR2GPT.exe before enabling BitLocker.'
    Write-Output '       This requires planning -- data loss is possible if done incorrectly.'
    $issueCount++
} elseif ($partStyle -eq 'RAW') {
    Write-Output '[!!]  Partition Style'
    Write-Output "       RAW (Disk $osDiskNumber). Disk has no recognized partition table."
    $issueCount++
} else {
    Write-Output '[!]   Partition Style'
    Write-Output '       Could not determine disk partition style.'
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: System Partition Validation
# ---------------------------------------------------------------
Write-Output '--- System Partition ---'

$sysPart = $null
$sysPartSizeMB = $null
$sysPartFormat = $null
$sysPartFound = $false

if ($null -ne $osDiskNumber) {
    try {
        $partitions = @(Get-Partition -DiskNumber $osDiskNumber -ErrorAction Stop)
        foreach ($p in $partitions) {
            # EFI System Partition GUID: c12a7328-f81f-11d2-ba4b-00a0c93ec93b
            $gptType = $null
            try { $gptType = $p.GptType } catch { }

            $isSystemPart = $false
            if ($null -ne $gptType -and $gptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {
                $isSystemPart = $true
            } elseif ($p.IsSystem -or $p.Type -eq 'System') {
                $isSystemPart = $true
            }

            if ($isSystemPart) {
                $sysPart = $p
                $sysPartSizeMB = [math]::Round($p.Size / 1MB, 0)
                $sysPartFound = $true

                # Get volume info for format
                try {
                    $vol = Get-Volume -Partition $p -ErrorAction Stop
                    $sysPartFormat = $vol.FileSystemType
                } catch {
                    # Try by drive letter if available
                    if ($null -ne $p.DriveLetter -and $p.DriveLetter -ne [char]0) {
                        try {
                            $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction Stop
                            $sysPartFormat = $vol.FileSystemType
                        } catch { }
                    }
                }
                break
            }
        }
    } catch { }
}

if (-not $sysPartFound) {
    Write-Output '[!!]  System Partition'
    Write-Output '       No EFI System Partition (ESP) or System partition found on the boot disk.'
    Write-Output '       BitLocker cannot stage pre-boot authentication files.'
    Write-Output '       Repartitioning or OS reinstallation may be required.'
    $issueCount++
} else {
    # Size check
    if ($sysPartSizeMB -ge 260) {
        Write-Output "[OK]  System Partition"
        $formatStr = if ([string]::IsNullOrWhiteSpace($sysPartFormat)) { 'Unknown' } else { $sysPartFormat }
        Write-Output "       Found. Size: $sysPartSizeMB MB. Format: $formatStr. Meets all requirements."
    } elseif ($sysPartSizeMB -ge 100) {
        Write-Output "[!]   System Partition"
        $formatStr = if ([string]::IsNullOrWhiteSpace($sysPartFormat)) { 'Unknown' } else { $sysPartFormat }
        Write-Output "       Found. Size: $sysPartSizeMB MB. Format: $formatStr."
        Write-Output "       Meets the 100 MB minimum but below the ideal 260 MB."
        Write-Output '       WinRE may not fit on this partition.'
        # Check for Event ID 854 in last 7 days
        try {
            $evt854 = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 854; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 5 -ErrorAction Stop
            if ($null -ne $evt854 -and @($evt854).Count -gt 0) {
                $evtCount = @($evt854).Count
                $lastEvt = $evt854[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')
                Write-Output "[!!]  WinRE Event ID 854: $evtCount occurrence(s) in last 7 days."
                Write-Output "       Last occurrence: $lastEvt."
                Write-Output '       WinRE failed to update due to insufficient partition space.'
                Write-Output '       This blocks Windows security updates that require WinRE patching.'
                $issueCount++
            } else {
                Write-Output '[i]   No WinRE Event ID 854 found in last 7 days.'
            }
        } catch {
            Write-Output '[i]   No WinRE Event ID 854 found in last 7 days.'
        }
        $warnCount++
    } else {
        Write-Output "[!!]  System Partition"
        Write-Output "       Found but only $sysPartSizeMB MB. Below the 100 MB minimum."
        Write-Output '       BitLocker pre-boot files may not fit. Repartitioning may be needed.'
        $issueCount++
    }

    # Format check (UEFI expects FAT32)
    if ($isUEFI -eq $true -and -not [string]::IsNullOrWhiteSpace($sysPartFormat)) {
        if ($sysPartFormat -ne 'FAT32') {
            Write-Output "[!]   System Partition Format"
            Write-Output "       Expected FAT32 for UEFI, found $sysPartFormat."
            Write-Output '       This may indicate a non-standard partition layout.'
            $warnCount++
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4b: Recovery Partition (WinRE) Size & Free Space
# WinRE lives on a dedicated Recovery Partition, not the ESP.
# If the recovery partition has < 250MB free, WinRE security updates
# fail (KB5034441 / CVE-2024-20666 patch), WinRE disables itself,
# and BitLocker silent encryption halts with Event 854.
# ---------------------------------------------------------------
Write-Output '--- Recovery Partition (WinRE) ---'

$recPartFound = $false
if ($null -ne $osDiskNumber) {
    try {
        # Recovery partition GPT GUID: de94bba4-06d1-4d40-a16a-bfd50179d6ac
        $recParts = @(Get-Partition -DiskNumber $osDiskNumber -ErrorAction Stop | Where-Object {
            $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or $_.Type -eq 'Recovery'
        })

        if ($recParts.Count -gt 0) {
            $recPartFound = $true
            # Take the last recovery partition (typically at the end of the disk)
            $recPart = $recParts[$recParts.Count - 1]
            $recSizeMB = [math]::Round($recPart.Size / 1MB, 0)

            # Try to read volume free space (may fail if partition is hidden/locked)
            $volInfo = $null
            try { $volInfo = Get-Volume -Partition $recPart -ErrorAction Stop } catch { }

            if ($null -ne $volInfo -and $null -ne $volInfo.SizeRemaining) {
                $freeMB = [math]::Round($volInfo.SizeRemaining / 1MB, 0)
                Write-Output "[i]   Recovery Partition Found: Size $recSizeMB MB (Free: $freeMB MB)"

                if ($freeMB -lt 250) {
                    Write-Output '[!!]  WinRE Partition Exhaustion Risk (CVE-2024-20666)'
                    Write-Output "       Less than 250 MB of free space available ($freeMB MB)."
                    Write-Output '       Windows Security Updates for WinRE (e.g. KB5034441) will fail.'
                    Write-Output '       A failed WinRE update disables WinRE, which permanently blocks'
                    Write-Output '       BitLocker silent encryption (Event 854).'
                    Write-Output '       Remediation: resize the recovery partition or use the Microsoft'
                    Write-Output '       Safe OS Dynamic Update (SODU) tool to extend it.'
                    $issueCount++
                }
                else {
                    Write-Output '[OK]  Recovery Partition has sufficient free space for WinRE updates.'
                }
            }
            else {
                Write-Output "[i]   Recovery Partition Found: Size $recSizeMB MB"
                Write-Output '       Could not calculate free space (expected if partition is hidden/locked).'
                if ($recSizeMB -lt 500) {
                    Write-Output '[!]   Partition is below 500 MB. WinRE updates may fail.'
                    Write-Output '       Monitor for Event 854 and WinRE disabled state.'
                    $warnCount++
                }
            }
        }
    } catch { }
}

if (-not $recPartFound) {
    Write-Output '[!]   No dedicated Recovery Partition found.'
    Write-Output '       WinRE might be residing on the OS partition (C:\Recovery).'
    Write-Output '       This is non-standard but BitLocker may still function.'
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Modern Standby / InstantGo
# ---------------------------------------------------------------
Write-Output '--- Modern Standby ---'

$modernStandbySupported = $false
$csEnabled = $null
$aoAcOverride = $null

# Check CsEnabled registry
$powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
try {
    $powerReg = Get-ItemProperty -Path $powerPath -ErrorAction Stop
    if ($null -ne $powerReg -and ($powerReg.PSObject.Properties.Name -contains 'CsEnabled')) {
        $csEnabled = [int]$powerReg.CsEnabled
    }
} catch { }

# Check PlatformAoAcOverride
try {
    if ($null -ne $powerReg -and ($powerReg.PSObject.Properties.Name -contains 'PlatformAoAcOverride')) {
        $aoAcOverride = [int]$powerReg.PlatformAoAcOverride
    }
} catch { }

# Verify via powercfg /a
try {
    $powercfgOutput = & powercfg /a 2>&1
    $powercfgText = ($powercfgOutput | Out-String)
    if ($powercfgText -match 'Standby \(S0 Low Power Idle\)') {
        $modernStandbySupported = $true
    }
} catch { }

if ($modernStandbySupported -or $csEnabled -eq 1) {
    if ($null -ne $aoAcOverride -and $aoAcOverride -eq 0) {
        Write-Output '[!]   Modern Standby'
        Write-Output '       Hardware supports Modern Standby, but it has been forcefully DISABLED'
        Write-Output '       via registry override (PlatformAoAcOverride = 0).'
        Write-Output '       This may impede background Intune policy delivery.'
        $warnCount++
    } else {
        Write-Output '[OK]  Modern Standby'
        Write-Output '       Supported and active (CsEnabled = 1).'
        Write-Output '       Background Intune policy delivery will work optimally.'
    }
} else {
    Write-Output '[i]   Modern Standby'
    Write-Output '       Not supported on this hardware (or not enabled).'
    Write-Output '       Intune policies will apply only during active use or scheduled sync.'
    Write-Output '       This is common on desktops and older laptops. Not a blocker for BitLocker.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 6: Machine Manufacturer & Model + OEM Quirks
# ---------------------------------------------------------------
Write-Output '--- Machine Identification ---'

$manufacturer = $null
$model = $null
$biosVersion = $null
$biosDate = $null

try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = $cs.Manufacturer
    $model = $cs.Model
} catch { }

try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $biosVersion = $bios.SMBIOSBIOSVersion
    $biosDate = $bios.ReleaseDate
} catch { }

$mfgStr = if ([string]::IsNullOrWhiteSpace($manufacturer)) { 'Unknown' } else { $manufacturer.Trim() }
$modelStr = if ([string]::IsNullOrWhiteSpace($model)) { 'Unknown' } else { $model.Trim() }
$biosStr = if ([string]::IsNullOrWhiteSpace($biosVersion)) { 'Unknown' } else { $biosVersion.Trim() }

$dateStr = ''
if ($null -ne $biosDate) {
    try { $dateStr = " (Released: $($biosDate.ToString('yyyy-MM-dd')))" } catch { }
}

Write-Output "[i]   Manufacturer: $mfgStr"
Write-Output "       Model: $modelStr"
Write-Output "       BIOS Version: $biosStr$dateStr"

# OEM quirk detection
$oemWarnings = 0

# Dell quirks
if ($mfgStr -match 'Dell') {
    Write-Output ''
    Write-Output '[!]   Dell System Advisory'
    Write-Output '       Dell systems may have "UEFI Bluetooth Stack" enabled in BIOS, which causes'
    Write-Output '       PCR measurement drift and prompts for the BitLocker recovery key after reboots.'
    Write-Output '       If this occurs, check BIOS > Connection > Disable "Enable UEFI Bluetooth Stack".'
    Write-Output '       Also verify TPM Physical Presence Interface (PPI) overrides are enabled'
    Write-Output '       in BIOS for silent TPM provisioning.'
    Write-Output '       These settings cannot be fixed by a script -- tech must enter BIOS setup.'
    $oemWarnings++
    $warnCount++
}

# Lenovo quirks
if ($mfgStr -match 'Lenovo') {
    Write-Output ''
    Write-Output '[!]   Lenovo System Advisory'
    Write-Output '       Lenovo firmware updates (especially ThinkPads) can update the Secure Boot'
    Write-Output '       certificate database, causing the TPM PCR 7 measurement to change.'
    Write-Output '       This triggers BitLocker recovery key prompts across the fleet after BIOS updates.'
    Write-Output '       Best practice: Suspend BitLocker protection BEFORE applying Lenovo firmware updates.'
    Write-Output '       This cannot be fixed by a script -- process change required.'
    $oemWarnings++
    $warnCount++
}

# HP quirks
if ($mfgStr -match 'HP\b|Hewlett') {
    Write-Output ''
    Write-Output '[!]   HP System Advisory'
    Write-Output '       HP systems with "Fast Boot" enabled in BIOS may enter a loop where the'
    Write-Output '       BitLocker recovery key is required after every cold boot or hibernation resume.'
    Write-Output '       If this occurs, disable Fast Boot in the HP BIOS configuration utility'
    Write-Output '       or update to the latest HP firmware version.'
    Write-Output '       This cannot be fixed by a script -- tech must enter BIOS setup.'
    $oemWarnings++
    $warnCount++
}

# Virtual machine detection
if ($mfgStr -match 'Microsoft Corporation' -and $modelStr -match 'Virtual Machine') {
    Write-Output ''
    Write-Output '[i]   Virtual Machine Detected'
    Write-Output '       Running on Hyper-V. BitLocker works with virtual TPM.'
    Write-Output '       No OEM-specific hardware quirks apply.'
}
if ($mfgStr -match 'VMware') {
    Write-Output ''
    Write-Output '[i]   Virtual Machine Detected'
    Write-Output '       Running on VMware. BitLocker works if virtual TPM is enabled.'
    Write-Output '       No OEM-specific hardware quirks apply.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 7: DMA Bus Security (Un-Allowed DMA Bus Detection)
# On pre-24H2 builds, un-allowed DMA-capable buses silently block
# automatic/silent BitLocker encryption. This is one of the most
# common causes of "everything looks healthy but it won't encrypt."
# Ref: Microsoft Learn - BitLocker OEM requirements (ref 27);
#      HKLM\SYSTEM\CurrentControlSet\Control\DmaSecurity\AllowedBuses
# ---------------------------------------------------------------
Write-Output '--- DMA Bus Security ---'

$osBuildDMA = 0
try {
    $ntVer = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $osBuildDMA = [int]$ntVer.CurrentBuildNumber
} catch { }

# Windows 11 24H2 = build 26100: DMA bus check officially deprecated as a
# prerequisite for automatic device encryption.
if ($osBuildDMA -ge 26100) {
    Write-Output "[OK]  DMA Bus Security (OS build $osBuildDMA)"
    Write-Output '       Windows 11 24H2 or later. The DMA bus prerequisite for automatic device'
    Write-Output '       encryption has been officially removed. No DMA bus blocking possible.'
} else {
    $dmaSecPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DmaSecurity'
    $allowedPath = "$dmaSecPath\AllowedBuses"

    if (-not (Test-Path $dmaSecPath)) {
        Write-Output "[i]   DMA Bus Security (OS build $osBuildDMA)"
        Write-Output '       DmaSecurity registry path not present. Kernel DMA Protection may not be'
        Write-Output '       enabled on this hardware. This is not a blocker unless the OS decides to'
        Write-Output '       enforce DMA checks at encryption time.'
    }
    elseif (Test-Path $allowedPath) {
        $busEntries = [System.Collections.Generic.List[string]]::new()
        try {
            $busProps = Get-ItemProperty -Path $allowedPath -ErrorAction Stop
            if ($busProps) {
                foreach ($prop in $busProps.PSObject.Properties) {
                    # AllowedBuses entries have PCI device IDs as value names
                    if ($prop.Name -notmatch '^PS') {
                        $null = $busEntries.Add($prop.Name)
                    }
                }
            }
        } catch { }

        if ($busEntries.Count -gt 0) {
            Write-Output "[i]   DMA Bus Security: $($busEntries.Count) whitelisted bus(es)"
            Write-Output '       Kernel DMA Protection is active. The following internal buses are'
            Write-Output '       explicitly allowed in the DMA security allowlist:'
            $showMax = [math]::Min($busEntries.Count, 10)
            for ($bi = 0; $bi -lt $showMax; $bi++) {
                Write-Output "       - $($busEntries[$bi])"
            }
            if ($busEntries.Count -gt 10) {
                Write-Output "       ... and $($busEntries.Count - 10) more"
            }
            Write-Output '       If silent encryption fails with no clear cause on this pre-24H2 build,'
            Write-Output '       internal PCI bridges not on this list may be the blocker.'
            Write-Output '       Run: msinfo32 > System Summary > Kernel DMA Protection to confirm state.'
        }
        else {
            Write-Output "[i]   DMA Bus Security (OS build $osBuildDMA)"
            Write-Output '       AllowedBuses key exists but is empty. If DMA protection is active,'
            Write-Output '       ALL DMA-capable buses are treated as un-allowed -- this will block'
            Write-Output '       silent encryption on any machine with PCIe bridges or Thunderbolt ports.'
            Write-Output '       Run: msinfo32 > System Summary > Kernel DMA Protection to confirm.'
            $warnCount++
        }
    }
    else {
        Write-Output "[i]   DMA Bus Security (OS build $osBuildDMA)"
        Write-Output '       DmaSecurity path exists but AllowedBuses subkey not found.'
        Write-Output '       DMA protection may not be actively enforcing bus restrictions.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 8: Virtualization-Based Security (VBS)
# VBS is not a direct BitLocker prerequisite, but on pre-24H2 builds
# HSTI compliance (which includes VBS) was required for auto-device-
# encryption. Also underpins Kernel DMA Protection and HVCI.
# ---------------------------------------------------------------
Write-Output '--- Virtualization-Based Security (VBS) ---'

try {
    $dg = Get-CimInstance -Namespace 'ROOT\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    if ($null -ne $dg) {
        $vbsStatus = $dg.VirtualizationBasedSecurityStatus
        $secProps  = $dg.AvailableSecurityProperties

        $vbsMap = @{ 0 = 'Disabled'; 1 = 'Enabled but not running'; 2 = 'Running' }
        $vbsStr = if ($vbsMap.ContainsKey([int]$vbsStatus)) { $vbsMap[[int]$vbsStatus] } else { "Unknown ($vbsStatus)" }

        if ($vbsStatus -eq 2) {
            Write-Output "[OK]  VBS Status: $vbsStr"

            $props = [System.Collections.Generic.List[string]]::new()
            if ($secProps -contains 1) { $null = $props.Add('Hypervisor Support') }
            if ($secProps -contains 2) { $null = $props.Add('Secure Boot') }
            if ($secProps -contains 3) { $null = $props.Add('DMA Protection') }
            if ($props.Count -gt 0) {
                Write-Output "       Available Hardware Security: $($props -join ', ')"
            }
        }
        elseif ($vbsStatus -eq 1) {
            Write-Output "[!]   VBS Status: $vbsStr"
            Write-Output '       Virtualization features are enabled in OS but the hypervisor is not running.'
            Write-Output '       Check BIOS for Intel VT-x / AMD-V / SVM enablement.'
            Write-Output '       Not a BitLocker blocker, but required for Kernel DMA Protection and HVCI.'
            $warnCount++
        }
        else {
            Write-Output "[i]   VBS Status: $vbsStr"
            Write-Output '       Virtualization-Based Security is disabled. BitLocker encryption itself'
            Write-Output '       does not require VBS, but pre-24H2 auto-device-encryption relied on'
            Write-Output '       HSTI attestation which includes VBS. Kernel DMA Protection also requires VBS.'
        }
    }
    else {
        Write-Output '[i]   VBS / DeviceGuard: WMI class returned no data.'
    }
} catch {
    Write-Output '[i]   VBS / DeviceGuard: WMI class not available on this OS build.'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. All hardware and firmware prerequisites are met.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review the flagged items above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Hardware prerequisites need attention."
}

Write-Output ''
Write-Output 'NEXT:   If Legacy BIOS        -> convert to UEFI (MBR2GPT.exe) -- requires planning'
Write-Output '        If Secure Boot off    -> enable in BIOS settings'
Write-Output '        If MBR disk           -> convert to GPT before enabling BitLocker'
Write-Output '        If all prereqs met    -> run BL004 BLIntunePolicy to check MDM configuration'
