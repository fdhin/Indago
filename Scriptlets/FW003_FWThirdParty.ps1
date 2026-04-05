# FW003_FWThirdParty.ps1
# Scriptlet: FW003 - Third-Party Firewall Detection
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Third-Party Firewall Detection ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# State tracking for cross-reference between checks
# ---------------------------------------------------------------
$scEntries    = [System.Collections.Generic.List[PSCustomObject]]::new()
$regProducts  = [System.Collections.Generic.List[PSCustomObject]]::new()
$remnants     = [System.Collections.Generic.List[PSCustomObject]]::new()
$hasActiveThirdParty = $false
$scAvailable  = $true

# ---------------------------------------------------------------
# Vendor definitions: name, match patterns, install paths, registry
# ---------------------------------------------------------------
$vendorDefs = @(
    @{ Vendor = 'Symantec / Broadcom'; Patterns = @('*Symantec*','*Endpoint Protection*'); InstallPath = 'C:\Program Files\Symantec\Symantec Endpoint Protection'; RegKey = 'HKLM:\SOFTWARE\Symantec\InstalledApps'; Filters = @('SymEFA','SRTSP','BHDrvx64') }
    @{ Vendor = 'McAfee / Trellix'; Patterns = @('*McAfee*','*Trellix*'); InstallPath = 'C:\Program Files\McAfee\Endpoint Security'; RegKey = 'HKLM:\SOFTWARE\McAfee\Endpoint Security'; Filters = @('mfehidk','mfefirek') }
    @{ Vendor = 'Sophos'; Patterns = @('*Sophos*'); InstallPath = 'C:\Program Files\Sophos'; RegKey = 'HKLM:\SOFTWARE\Sophos'; Filters = @('SophosED','SAVOnAccess') }
    @{ Vendor = 'ESET'; Patterns = @('*ESET*'); InstallPath = 'C:\Program Files\ESET\ESET Security'; RegKey = 'HKLM:\SOFTWARE\ESET'; Filters = @('eamonm','ekrn') }
    @{ Vendor = 'Comodo'; Patterns = @('*Comodo*','*COMODO*'); InstallPath = 'C:\Program Files\COMODO\COMODO Internet Security'; RegKey = 'HKLM:\SOFTWARE\ComodoGroup'; Filters = @() }
    @{ Vendor = 'ZoneAlarm'; Patterns = @('*ZoneAlarm*','*Zone Labs*'); InstallPath = 'C:\Program Files\Zone Labs\ZoneAlarm'; RegKey = 'HKLM:\SOFTWARE\Zone Labs'; Filters = @() }
    @{ Vendor = 'GlassWire'; Patterns = @('*GlassWire*'); InstallPath = 'C:\Program Files (x86)\GlassWire'; RegKey = 'HKLM:\SOFTWARE\GlassWire'; Filters = @() }
    @{ Vendor = 'TinyWall'; Patterns = @('*TinyWall*'); InstallPath = 'C:\Program Files\TinyWall'; RegKey = 'HKLM:\SOFTWARE\TinyWall'; Filters = @() }
    @{ Vendor = 'Kaspersky'; Patterns = @('*Kaspersky*'); InstallPath = $null; RegKey = 'HKLM:\SOFTWARE\KasperskyLab'; Filters = @('klif','kneps') }
    @{ Vendor = 'Norton'; Patterns = @('*Norton*'); InstallPath = $null; RegKey = $null; Filters = @('SymEFA','ccSet') }
    @{ Vendor = 'Bitdefender'; Patterns = @('*Bitdefender*'); InstallPath = $null; RegKey = 'HKLM:\SOFTWARE\Bitdefender'; Filters = @('bdselfpr','BDSandBox') }
    @{ Vendor = 'F-Secure / WithSecure'; Patterns = @('*F-Secure*','*WithSecure*'); InstallPath = $null; RegKey = 'HKLM:\SOFTWARE\F-Secure'; Filters = @('F-Secure Gatekeeper') }
    @{ Vendor = 'Trend Micro'; Patterns = @('*Trend Micro*'); InstallPath = $null; RegKey = 'HKLM:\SOFTWARE\TrendMicro'; Filters = @('TmPreFlt','TmFileEncDmk') }
    @{ Vendor = 'CrowdStrike'; Patterns = @('*CrowdStrike*'); InstallPath = 'C:\Program Files\CrowdStrike'; RegKey = 'HKLM:\SYSTEM\CrowdStrike'; Filters = @('CSAgent','csagent') }
)

# ---------------------------------------------------------------
# Check 1: Security Center FirewallProduct Deep Enumeration
# ---------------------------------------------------------------
Write-Output '--- Security Center: Registered Firewall Products ---'

$nativeGuid = '{D68DDC3A-831F-4fae-9E44-DA132C1ACF46}'

try {
    $fwProducts = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop)

    if ($null -eq $fwProducts -or $fwProducts.Count -eq 0) {
        Write-Output '[i]   No Firewall Products Registered'
        Write-Output '       SecurityCenter2 returned no FirewallProduct entries.'
        Write-Output '       This is unusual on client OS -- Intune may flag the firewall as unknown.'
    } else {
        foreach ($fw in $fwProducts) {
            $pState     = [UInt32]$fw.productState
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

            $sigStatus = if ($sigBits -eq 0x00) { 'Up to date' } else { 'Out of date' }
            $ownerStr  = if ($ownerBits -eq 0x0100) { 'Microsoft' } else { 'Third-party' }

            $isNative   = ($fw.instanceGuid -eq $nativeGuid -or $fw.displayName -like '*Windows Defender*' -or $fw.displayName -like '*Windows Firewall*')
            $exePath    = $fw.pathToSignedProductExe
            $rptPath    = $fw.pathToSignedReportingExe

            # Ghost detection: check if executable exists on disk
            $exeExists = $true
            $checkPath = $exePath
            if ([string]::IsNullOrWhiteSpace($checkPath)) { $checkPath = $rptPath }
            if (-not [string]::IsNullOrWhiteSpace($checkPath)) {
                if ($checkPath -notlike 'windowsdefender://*' -and $checkPath -notlike '%*') {
                    $exeExists = Test-Path $checkPath
                }
            }

            $entry = [PSCustomObject]@{
                DisplayName  = $fw.displayName
                GUID         = $fw.instanceGuid
                EngineState  = $engineState
                SigStatus    = $sigStatus
                Owner        = $ownerStr
                IsNative     = $isNative
                ExePath      = $checkPath
                ExeExists    = $exeExists
                ProductState = $pState
            }
            $null = $scEntries.Add($entry)

            if ($isNative) {
                if ($engineState -eq 'On') {
                    Write-Output "[OK]  $($fw.displayName)"
                    Write-Output "       State: $engineState. GUID: $($fw.instanceGuid)."
                    Write-Output "       Owner: $ownerStr. Signatures: $sigStatus."
                } else {
                    Write-Output "[!!]  $($fw.displayName)"
                    Write-Output "       State: $engineState. Native Windows Firewall is not reporting as active."
                    Write-Output "       Intune will see the endpoint firewall as non-compliant."
                    $issueCount++
                }
            } else {
                # Third-party product
                if ($exeExists -and $engineState -eq 'On') {
                    $hasActiveThirdParty = $true
                    Write-Output "[i]   $($fw.displayName)"
                    Write-Output "       State: $engineState. Owner: $ownerStr. Signatures: $sigStatus."
                    Write-Output "       GUID: $($fw.instanceGuid)."
                    if (-not [string]::IsNullOrWhiteSpace($checkPath)) {
                        Write-Output "       Exe: $checkPath"
                    }
                    Write-Output '       Active third-party firewall is managing traffic.'
                    Write-Output '       Windows Firewall may be correctly yielding control to this product.'
                } elseif ($exeExists -and $engineState -ne 'On') {
                    Write-Output "[!!]  $($fw.displayName)"
                    Write-Output "       State: $engineState. Product installed but NOT actively protecting."
                    Write-Output "       Owner: $ownerStr. GUID: $($fw.instanceGuid)."
                    if (-not [string]::IsNullOrWhiteSpace($checkPath)) {
                        Write-Output "       Exe: $checkPath"
                    }
                    Write-Output '       Either reactivate the product or remove it to restore Windows Firewall.'
                    $issueCount++
                } else {
                    # Ghost: exe missing
                    Write-Output "[!!]  $($fw.displayName)"
                    Write-Output "       GHOST REGISTRATION -- product registered but executable NOT found on disk."
                    Write-Output "       GUID: $($fw.instanceGuid). Claimed state: $engineState."
                    if (-not [string]::IsNullOrWhiteSpace($checkPath)) {
                        Write-Output "       Path: $checkPath"
                    }
                    Write-Output '       Windows Firewall cannot reactivate while this ghost persists.'
                    Write-Output '       Run FW006 FWRemediation to remove the ghost registration.'
                    $issueCount++
                }
            }
        }
    }
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -like '*Invalid namespace*' -or $errMsg -like '*not found*' -or $errMsg -like '*not supported*') {
        $scAvailable = $false
        Write-Output '[i]   SecurityCenter2 Not Available'
        Write-Output '       The SecurityCenter2 WMI namespace is not present (normal on Windows Server).'
        Write-Output '       Skipping Security Center enumeration. Remaining checks still apply.'
    } else {
        $scAvailable = $false
        Write-Output '[!]   Security Center Query Failed'
        Write-Output "       Could not query SecurityCenter2: $errMsg"
        Write-Output '       Remaining checks will still run.'
        $warnCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: Third-Party Firewall Remnant Scan
# ---------------------------------------------------------------
Write-Output '--- Third-Party Firewall Remnant Scan ---'

# Build Uninstall registry entries
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$uninstallEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($uPath in $uninstallPaths) {
    try {
        $subkeys = Get-ChildItem -Path $uPath -ErrorAction Stop
        foreach ($sk in $subkeys) {
            try {
                $props = Get-ItemProperty -Path $sk.PSPath -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($props.DisplayName)) {
                    $null = $uninstallEntries.Add([PSCustomObject]@{
                        DisplayName    = $props.DisplayName
                        DisplayVersion = $props.DisplayVersion
                        Publisher      = $props.Publisher
                        UninstallPath  = $props.UninstallString
                        InstallPath    = $props.InstallLocation
                        RegPath        = $sk.PSPath
                    })
                }
            } catch { }
        }
    } catch { }
}

$foundAnyRemnant = $false

foreach ($vDef in $vendorDefs) {
    $vendorName = $vDef.Vendor
    $foundInUninstall = $false
    $foundInstallDir  = $false
    $foundVendorReg   = $false
    $matchedEntry     = $null

    # Check Uninstall registry
    foreach ($pattern in $vDef.Patterns) {
        $matches = @($uninstallEntries | Where-Object { $_.DisplayName -like $pattern })
        if ($matches.Count -gt 0) {
            $foundInUninstall = $true
            $matchedEntry = $matches[0]
            break
        }
    }

    # Check known install path
    if (-not [string]::IsNullOrWhiteSpace($vDef.InstallPath)) {
        if (Test-Path $vDef.InstallPath) {
            $foundInstallDir = $true
        }
    }

    # Check vendor-specific registry key
    if (-not [string]::IsNullOrWhiteSpace($vDef.RegKey)) {
        if (Test-Path $vDef.RegKey) {
            $foundVendorReg = $true
        }
    }

    # Report findings
    if ($foundInUninstall) {
        $foundAnyRemnant = $true
        $verStr = if (-not [string]::IsNullOrWhiteSpace($matchedEntry.DisplayVersion)) { " v$($matchedEntry.DisplayVersion)" } else { '' }
        $null = $regProducts.Add([PSCustomObject]@{
            Vendor         = $vendorName
            ProductName    = $matchedEntry.DisplayName
            Version        = $matchedEntry.DisplayVersion
            InUninstall    = $true
            HasInstallDir  = $foundInstallDir
            HasVendorReg   = $foundVendorReg
        })
        Write-Output "[i]   $vendorName -- Installed"
        Write-Output "       Product: $($matchedEntry.DisplayName)$verStr"
        if (-not [string]::IsNullOrWhiteSpace($matchedEntry.Publisher)) {
            Write-Output "       Publisher: $($matchedEntry.Publisher)"
        }
    } elseif ($foundInstallDir -or $foundVendorReg) {
        $foundAnyRemnant = $true
        $null = $remnants.Add([PSCustomObject]@{
            Vendor        = $vendorName
            HasInstallDir = $foundInstallDir
            HasVendorReg  = $foundVendorReg
        })
        Write-Output "[!]   $vendorName -- Remnant Detected"
        if ($foundInstallDir) {
            Write-Output "       Install directory found: $($vDef.InstallPath)"
        }
        if ($foundVendorReg) {
            Write-Output "       Vendor registry key found: $($vDef.RegKey)"
        }
        Write-Output '       No Uninstall entry found -- product may be partially uninstalled.'
        Write-Output '       Run vendor cleanup tool to fully remove remnants.'
        $warnCount++
    }
}

if (-not $foundAnyRemnant) {
    Write-Output '[OK]  No Third-Party Firewall Remnants'
    Write-Output '       No known third-party firewall products or remnants found in registry or on disk.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: "Managed by Vendor" State Detection
# ---------------------------------------------------------------
Write-Output '--- "Managed by Vendor" State ---'

$fwPolicyBase = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'

$profileDefs = @(
    @{ Display = 'Domain';  SubKey = 'DomainProfile' }
    @{ Display = 'Private'; SubKey = 'StandardProfile' }
    @{ Display = 'Public';  SubKey = 'PublicProfile' }
)

$anyManagedByVendor = $false

foreach ($pd in $profileDefs) {
    $regPath = Join-Path $fwPolicyBase $pd.SubKey
    $enableFw = $null
    try {
        $regObj = Get-ItemProperty -Path $regPath -ErrorAction Stop
        if ($null -ne $regObj -and ($regObj.PSObject.Properties.Name -contains 'EnableFirewall')) {
            $enableFw = [int]$regObj.EnableFirewall
        }
    } catch { }

    if ($null -eq $enableFw -or $enableFw -eq 1) {
        Write-Output "[OK]  $($pd.Display) Profile: EnableFirewall = 1"
        Write-Output '       Windows Firewall is not yielding on this profile.'
    } elseif ($enableFw -eq 0) {
        $anyManagedByVendor = $true
        if ($hasActiveThirdParty) {
            Write-Output "[i]   $($pd.Display) Profile: EnableFirewall = 0"
            Write-Output '       Windows Firewall is yielding to an active third-party firewall.'
            Write-Output '       This is expected behavior when a third-party product manages the firewall.'
        } else {
            Write-Output "[!!]  $($pd.Display) Profile: EnableFirewall = 0"
            Write-Output '       Windows Firewall is set to yield to a third-party product.'
            Write-Output '       BUT no active third-party firewall was detected in Security Center.'
            Write-Output '       RESULT: This profile has ZERO active firewalls.'
            Write-Output '       Run FW006 FWRemediation to restore Windows Firewall.'
            $issueCount++
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Ghost Registration Analysis
# ---------------------------------------------------------------
Write-Output '--- Ghost Registration Analysis ---'

$ghostFound  = $false
$thirdPartySCEntries = @($scEntries | Where-Object { -not $_.IsNative })

if (-not $scAvailable) {
    Write-Output '[i]   Security Center Not Available'
    Write-Output '       Cannot perform ghost analysis without SecurityCenter2.'
} elseif ($thirdPartySCEntries.Count -eq 0) {
    Write-Output '[OK]  No Third-Party Security Center Entries'
    Write-Output '       No third-party firewall products registered. No ghost risk.'
} else {
    foreach ($scEntry in $thirdPartySCEntries) {
        $productName = $scEntry.DisplayName
        $exeOK       = $scEntry.ExeExists
        $scState     = $scEntry.EngineState

        # Cross-reference with Uninstall registry
        $inUninstall = $false
        foreach ($rp in $regProducts) {
            foreach ($vDef in $vendorDefs) {
                foreach ($pattern in $vDef.Patterns) {
                    if ($productName -like $pattern -or $rp.ProductName -like $pattern) {
                        $inUninstall = $rp.InUninstall
                        break
                    }
                }
                if ($inUninstall) { break }
            }
            if ($inUninstall) { break }
        }

        # Determine ghost confidence
        if (-not $exeOK -and -not $inUninstall) {
            $ghostFound = $true
            Write-Output "[!!]  CONFIRMED GHOST: $productName"
            Write-Output '       Security Center registration present but product is NOT installed.'
            Write-Output "       - Executable: MISSING ($($scEntry.ExePath))"
            Write-Output '       - Uninstall entry: MISSING'
            # Check if vendor remnants exist
            $hasRemnant = $false
            foreach ($rem in $remnants) {
                foreach ($vDef in $vendorDefs) {
                    foreach ($pattern in $vDef.Patterns) {
                        if ($productName -like $pattern) {
                            $hasRemnant = $true
                            break
                        }
                    }
                    if ($hasRemnant) { break }
                }
                if ($hasRemnant) { break }
            }
            if ($hasRemnant) {
                Write-Output '       - Vendor remnants: PRESENT (orphaned registry/files)'
            }
            Write-Output '       Windows Firewall cannot reactivate while this ghost persists.'
            Write-Output '       Run FW006 FWRemediation to remove the ghost registration.'
            $issueCount++
        } elseif (-not $exeOK -and $inUninstall) {
            $ghostFound = $true
            Write-Output "[!!]  PARTIAL UNINSTALL: $productName"
            Write-Output '       Security Center entry AND Uninstall key present, but executable is MISSING.'
            Write-Output "       - Executable: MISSING ($($scEntry.ExePath))"
            Write-Output '       - Uninstall entry: PRESENT'
            Write-Output '       The uninstaller may have failed to complete. Re-run the vendor uninstaller'
            Write-Output '       or use the vendor cleanup tool, then run FW006 FWRemediation.'
            $issueCount++
        } elseif ($exeOK -and $scState -ne 'On') {
            Write-Output "[!]   INACTIVE PRODUCT: $productName"
            Write-Output "       Product installed but reporting state: $scState."
            Write-Output '       Either reactivate the product or fully uninstall it.'
            Write-Output '       While inactive, Windows Firewall may still be yielding control.'
            $warnCount++
        } elseif ($exeOK -and $scState -eq 'On') {
            Write-Output "[OK]  $productName -- Active and Installed"
            Write-Output '       Product executable found on disk and Security Center reports active.'
            Write-Output '       No ghost concern.'
        }
    }
}

# Check for orphaned remnants with no SC entry
if ($remnants.Count -gt 0) {
    foreach ($rem in $remnants) {
        # Check if this vendor has a matching SC entry
        $hasSCMatch = $false
        foreach ($scEntry in $thirdPartySCEntries) {
            foreach ($vDef in $vendorDefs) {
                if ($vDef.Vendor -eq $rem.Vendor) {
                    foreach ($pattern in $vDef.Patterns) {
                        if ($scEntry.DisplayName -like $pattern) {
                            $hasSCMatch = $true
                            break
                        }
                    }
                }
                if ($hasSCMatch) { break }
            }
            if ($hasSCMatch) { break }
        }
        if (-not $hasSCMatch) {
            Write-Output "[!]   ORPHANED REMNANT: $($rem.Vendor)"
            Write-Output '       Vendor files or registry keys remain but no Security Center entry.'
            Write-Output '       Not causing compliance issues, but indicates incomplete uninstallation.'
            Write-Output '       Clean up with vendor removal tool for hygiene.'
            $warnCount++
        }
    }
}

if (-not $ghostFound -and $thirdPartySCEntries.Count -gt 0) {
    $allOK = $true
    foreach ($scEntry in $thirdPartySCEntries) {
        if (-not $scEntry.ExeExists -or $scEntry.EngineState -ne 'On') {
            $allOK = $false
            break
        }
    }
    if ($allOK -and $remnants.Count -eq 0) {
        # Already reported per-entry OK above, no extra line needed
    }
} elseif (-not $ghostFound -and $thirdPartySCEntries.Count -eq 0 -and $remnants.Count -eq 0 -and $scAvailable) {
    # Already reported OK in the SC entries section
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: WFP Callout Driver Detection (via fltmc instances)
# ---------------------------------------------------------------
Write-Output '--- WFP Filter Driver Check ---'

$knownVendorFilters = [System.Collections.Generic.List[string]]::new()
foreach ($vDef in $vendorDefs) {
    foreach ($f in $vDef.Filters) {
        if (-not [string]::IsNullOrWhiteSpace($f)) {
            $null = $knownVendorFilters.Add($f)
        }
    }
}

# Known Microsoft filter driver names to exclude
$msFilters = @('WdFilter','storqosflt','bindflt','Wof','FileCrypt','luafv','npsvctrig','CldFlt','wcifs','Cldflt','DfsrRo','FsDepends','MsSecFlt','SysmonDrv')

$fltmcOutput = $null
try {
    $fltmcOutput = & fltmc instances 2>&1
} catch { }

$detectedFilters = [System.Collections.Generic.List[PSCustomObject]]::new()
$orphanedFilters = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($null -ne $fltmcOutput -and $fltmcOutput.Count -gt 0) {
    $fltmcStr = $fltmcOutput | Out-String
    $lines = $fltmcStr -split "`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -like 'Filter*' -or $trimmed -like '---*') { continue }

        # Parse fltmc instances output: FilterName  Volume  InstanceName  Altitude  Frame
        $parts = $trimmed -split '\s{2,}'
        if ($parts.Count -ge 1) {
            $filterName = $parts[0].Trim()
            if ([string]::IsNullOrWhiteSpace($filterName)) { continue }

            # Skip known Microsoft filters
            $isMsFilter = $false
            foreach ($msf in $msFilters) {
                if ($filterName -eq $msf) {
                    $isMsFilter = $true
                    break
                }
            }
            if ($isMsFilter) { continue }

            # Check if it is a known vendor filter
            $matchedVendor = $null
            foreach ($vDef in $vendorDefs) {
                foreach ($vf in $vDef.Filters) {
                    if ($filterName -eq $vf) {
                        $matchedVendor = $vDef.Vendor
                        break
                    }
                }
                if ($null -ne $matchedVendor) { break }
            }

            # Deduplicate
            $alreadyListed = $false
            foreach ($df in $detectedFilters) {
                if ($df.FilterName -eq $filterName) {
                    $alreadyListed = $true
                    break
                }
            }
            if ($alreadyListed) { continue }

            if ($null -ne $matchedVendor) {
                # Known vendor filter -- check if product is installed
                $isInstalled = $false
                foreach ($rp in $regProducts) {
                    if ($rp.Vendor -eq $matchedVendor) {
                        $isInstalled = $true
                        break
                    }
                }
                # Also check if active in SC
                $isActiveInSC = $false
                foreach ($scEntry in $scEntries) {
                    if (-not $scEntry.IsNative) {
                        foreach ($vDef2 in $vendorDefs) {
                            if ($vDef2.Vendor -eq $matchedVendor) {
                                foreach ($pattern in $vDef2.Patterns) {
                                    if ($scEntry.DisplayName -like $pattern) {
                                        $isActiveInSC = $true
                                        break
                                    }
                                }
                            }
                            if ($isActiveInSC) { break }
                        }
                        if ($isActiveInSC) { break }
                    }
                }

                $null = $detectedFilters.Add([PSCustomObject]@{
                    FilterName = $filterName
                    Vendor     = $matchedVendor
                    Installed  = $isInstalled
                    ActiveInSC = $isActiveInSC
                })

                if (-not $isInstalled -and -not $isActiveInSC) {
                    $null = $orphanedFilters.Add([PSCustomObject]@{
                        FilterName = $filterName
                        Vendor     = $matchedVendor
                    })
                }
            } else {
                # Unknown non-Microsoft filter -- informational
                $null = $detectedFilters.Add([PSCustomObject]@{
                    FilterName = $filterName
                    Vendor     = 'Unknown'
                    Installed  = $false
                    ActiveInSC = $false
                })
            }
        }
    }
}

if ($orphanedFilters.Count -gt 0) {
    foreach ($of in $orphanedFilters) {
        Write-Output "[!!]  Orphaned Filter Driver: $($of.FilterName)"
        Write-Output "       Vendor: $($of.Vendor). Product is NOT installed but a kernel filter driver remains."
        Write-Output '       This may cause network issues or prevent Windows Firewall from functioning properly.'
        Write-Output '       Manual removal required (driver-level). Contact vendor for cleanup tool.'
        $issueCount++
    }
}

$installedVendorFilters = @($detectedFilters | Where-Object { $_.Vendor -ne 'Unknown' -and ($_.Installed -or $_.ActiveInSC) })
if ($installedVendorFilters.Count -gt 0) {
    foreach ($ivf in $installedVendorFilters) {
        Write-Output "[i]   Vendor Filter Driver: $($ivf.FilterName)"
        Write-Output "       Vendor: $($ivf.Vendor). Expected -- product is installed."
    }
}

$unknownFilters = @($detectedFilters | Where-Object { $_.Vendor -eq 'Unknown' })
if ($unknownFilters.Count -gt 0) {
    $uNames = ($unknownFilters | ForEach-Object { $_.FilterName }) -join ', '
    Write-Output "[i]   Non-Microsoft Filter Drivers Detected"
    Write-Output "       $uNames"
    Write-Output '       May be VPN, EDR, backup, or other legitimate software. Not necessarily a firewall issue.'
}

if ($detectedFilters.Count -eq 0) {
    Write-Output '[OK]  No Third-Party WFP Filter Drivers Detected'
    Write-Output '       Only Microsoft filter drivers are active.'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. No third-party firewall interference found.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If ghost registration found     -> run FW006 FWRemediation to clean up'
Write-Output '        If active third-party firewall   -> coordinate with vendor for proper configuration'
Write-Output '        If WFP filter drivers orphaned   -> manual removal required (driver-level)'
Write-Output '        If no third-party issues         -> run FW004 FWServiceHealth for deeper plumbing checks'
Write-Output ''
