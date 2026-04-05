# WU007_WUEnvironmentAudit.ps1
# Scriptlet: WU007 - Windows Update Agent & Environment Audit
# Context: System | Version: 1.1

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== Windows Update Agent & Environment Audit ==='

# ============================================================
# Check 1 -- WU Agent Version
# ============================================================
Write-Output ''
Write-Output '--- WU Agent ---'

$agentVersion = $null
$agentSource = ''

# Primary: wuaueng.dll file version (reliable on all Windows 10/11 builds)
try {
    $wuDllPath = Join-Path $env:SystemRoot 'System32\wuaueng.dll'
    if (Test-Path $wuDllPath) {
        $dllInfo = (Get-Item $wuDllPath).VersionInfo
        if ($dllInfo.FileVersion) {
            $agentVersion = $dllInfo.FileVersion
            $agentSource = 'wuaueng.dll'
        }
    }
} catch { }

# Fallback 1: Registry AgentVersion
if (-not $agentVersion) {
    try {
        $auPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        if (Test-Path $auPath) {
            $auProps = Get-ItemProperty -Path $auPath -ErrorAction SilentlyContinue
            if ($auProps.PSObject.Properties['AgentVersion']) {
                $agentVersion = $auProps.AgentVersion
                $agentSource = 'registry'
            }
        }
    } catch { }
}

# Fallback 2: Registry SetupVersion
if (-not $agentVersion) {
    try {
        $setupPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
        $setupProps = Get-ItemProperty -Path $setupPath -ErrorAction SilentlyContinue
        if ($setupProps.PSObject.Properties['SetupVersion']) {
            $agentVersion = $setupProps.SetupVersion
            $agentSource = 'registry'
        }
    } catch { }
}

if ($agentVersion) {
    $findings.Add([PSCustomObject]@{
        Check  = 'WU Agent Version'
        Status = 'INFO'
        Detail = "Agent version: $agentVersion (source: $agentSource)."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'WU Agent Version'
        Status = 'WARN'
        Detail = 'Unable to determine WU agent version. wuaueng.dll not found and registry keys are unpopulated.'
    })
}

# ============================================================
# Check 2 -- OS Edition, Build Number, UBR
# ============================================================
Write-Output ''
Write-Output '--- OS Build & Edition ---'

$osBuild = $null
$osUBR = $null
$osDisplayVersion = $null
$osEdition = $null
$osProductName = $null

try {
    $ntPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ntProps = Get-ItemProperty -Path $ntPath -ErrorAction Stop
    $osBuild = $ntProps.CurrentBuildNumber
    if ($ntProps.PSObject.Properties['UBR']) { $osUBR = $ntProps.UBR }
    if ($ntProps.PSObject.Properties['DisplayVersion']) { $osDisplayVersion = $ntProps.DisplayVersion }
    if ($ntProps.PSObject.Properties['EditionID']) { $osEdition = $ntProps.EditionID }
    if ($ntProps.PSObject.Properties['ProductName']) { $osProductName = $ntProps.ProductName }
} catch { }

# CIM fallback for caption
$osCimCaption = $null
try {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osCimCaption = $osInfo.Caption
} catch { }

$buildString = $osBuild
if ($osUBR) { $buildString = "$osBuild.$osUBR" }

$editionDisplay = if ($osCimCaption) { $osCimCaption } elseif ($osProductName) { $osProductName } else { 'Unknown Edition' }

$versionDisplay = ''
if ($osDisplayVersion) { $versionDisplay = " $osDisplayVersion" }

$findings.Add([PSCustomObject]@{
    Check  = 'OS Build & Edition'
    Status = 'INFO'
    Detail = "$editionDisplay$versionDisplay (Build $buildString)"
})

# Check for LTSC/Server editions
if ($osEdition) {
    if ($osEdition -match 'LTSC|LTSB|Server') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Servicing Channel'
            Status = 'INFO'
            Detail = "Edition '$osEdition' uses Long-Term Servicing Channel. Feature updates follow a different cadence than consumer/enterprise GA."
        })
    }
}

# ============================================================
# Check 3 -- .NET Framework Version
# ============================================================
Write-Output ''
Write-Output '--- .NET Framework ---'

$dotNetRelease = $null
$dotNetVersion = 'Unknown'
try {
    $ndpPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (Test-Path $ndpPath) {
        $ndpProps = Get-ItemProperty -Path $ndpPath -ErrorAction Stop
        if ($ndpProps.PSObject.Properties['Release']) {
            $dotNetRelease = [int]$ndpProps.Release

            # Official Microsoft decode table
            if ($dotNetRelease -ge 533325) { $dotNetVersion = '4.8.1' }
            elseif ($dotNetRelease -ge 528040) { $dotNetVersion = '4.8' }
            elseif ($dotNetRelease -ge 461808) { $dotNetVersion = '4.7.2' }
            elseif ($dotNetRelease -ge 461308) { $dotNetVersion = '4.7.1' }
            elseif ($dotNetRelease -ge 460798) { $dotNetVersion = '4.7' }
            elseif ($dotNetRelease -ge 394802) { $dotNetVersion = '4.6.2' }
            elseif ($dotNetRelease -ge 394254) { $dotNetVersion = '4.6.1' }
            elseif ($dotNetRelease -ge 393295) { $dotNetVersion = '4.6' }
            elseif ($dotNetRelease -ge 379893) { $dotNetVersion = '4.5.2' }
            elseif ($dotNetRelease -ge 378675) { $dotNetVersion = '4.5.1' }
            elseif ($dotNetRelease -ge 378389) { $dotNetVersion = '4.5' }
            else { $dotNetVersion = "4.x (Release $dotNetRelease)" }
        }
    }
} catch { }

if ($null -ne $dotNetRelease) {
    if ($dotNetRelease -ge 528040) {
        $findings.Add([PSCustomObject]@{
            Check  = '.NET Framework Version'
            Status = 'OK'
            Detail = ".NET Framework $dotNetVersion (Release $dotNetRelease). Modern version, no WU concerns."
        })
    } elseif ($dotNetRelease -ge 461308) {
        $findings.Add([PSCustomObject]@{
            Check  = '.NET Framework Version'
            Status = 'WARN'
            Detail = ".NET Framework $dotNetVersion (Release $dotNetRelease). Aging version -- some modern WU components and servicing stack elements may expect 4.8+."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = '.NET Framework Version'
            Status = 'ISSUE'
            Detail = ".NET Framework $dotNetVersion (Release $dotNetRelease). Outdated -- can cause WU agent failures and servicing stack incompatibilities."
        })
    }
} else {
    $findings.Add([PSCustomObject]@{
        Check  = '.NET Framework Version'
        Status = 'ISSUE'
        Detail = '.NET Framework 4.x not detected. The WU agent and servicing stack require .NET Framework 4.x for proper operation.'
    })
}

# ============================================================
# Check 4 -- PowerShell Version
# ============================================================
Write-Output ''
Write-Output '--- PowerShell ---'

$psVer = $PSVersionTable.PSVersion
$clrVer = $PSVersionTable.CLRVersion

if ($psVer.Major -ge 5 -and $psVer.Minor -ge 1) {
    $findings.Add([PSCustomObject]@{
        Check  = 'PowerShell Version'
        Status = 'OK'
        Detail = "PowerShell $($psVer.ToString()) (CLR $($clrVer.ToString())). Expected version for WU management."
    })
} elseif ($psVer.Major -ge 5) {
    $findings.Add([PSCustomObject]@{
        Check  = 'PowerShell Version'
        Status = 'WARN'
        Detail = "PowerShell $($psVer.ToString()). Below 5.1 -- some modern WU cmdlets may not be available."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'PowerShell Version'
        Status = 'ISSUE'
        Detail = "PowerShell $($psVer.ToString()). Below minimum for modern WU management cmdlets. Expected 5.1+."
    })
}
# ============================================================
# Check 5 -- Feature Update Eligibility
# ============================================================
Write-Output ''
Write-Output '--- Feature Update Eligibility ---'

# Hardcoded version table -- no internet queries
# Format: BuildNumber = @{ DisplayVersion; Product; Status; Note }
$versionTable = @{
    '19041' = @{ Display = '2004';  Product = 'Windows 10'; Status = 'EOS';  Note = 'End of service since Dec 2021' }
    '19042' = @{ Display = '20H2';  Product = 'Windows 10'; Status = 'EOS';  Note = 'End of service since May 2022 (Home/Pro), Jun 2023 (Enterprise)' }
    '19043' = @{ Display = '21H1';  Product = 'Windows 10'; Status = 'EOS';  Note = 'End of service since Dec 2022' }
    '19044' = @{ Display = '21H2';  Product = 'Windows 10'; Status = 'EOS';  Note = 'End of service since Jun 2023 (Home/Pro), Jun 2024 (Enterprise)' }
    '19045' = @{ Display = '22H2';  Product = 'Windows 10'; Status = 'EOS';  Note = 'End of service Oct 2025 (Home/Pro). Extended ESU available for Enterprise.' }
    '22000' = @{ Display = '21H2';  Product = 'Windows 11'; Status = 'EOS';  Note = 'End of service since Oct 2023 (Home/Pro), Oct 2024 (Enterprise)' }
    '22621' = @{ Display = '22H2';  Product = 'Windows 11'; Status = 'EXT';  Note = 'Home/Pro EOS Oct 2024. Enterprise extended to Oct 2025.' }
    '22631' = @{ Display = '23H2';  Product = 'Windows 11'; Status = 'OK';   Note = 'In service. Home/Pro EOS Nov 2025, Enterprise Nov 2026.' }
    '26100' = @{ Display = '24H2';  Product = 'Windows 11'; Status = 'OK';   Note = 'In service. Home/Pro EOS Oct 2026, Enterprise Oct 2027.' }
    '26200' = @{ Display = '25H2';  Product = 'Windows 11'; Status = 'OK';   Note = 'In service (2025 Update). Delivered as enablement package from 24H2.' }
    '28000' = @{ Display = '26H1';  Product = 'Windows 11'; Status = 'OK';   Note = 'In service. ARM64-only release for next-gen Snapdragon X2 hardware.' }
}

if ($osBuild -and $versionTable.ContainsKey($osBuild)) {
    $ver = $versionTable[$osBuild]
    $dispVer = if ($osDisplayVersion) { $osDisplayVersion } else { $ver.Display }

    switch ($ver.Status) {
        'OK' {
            $findings.Add([PSCustomObject]@{
                Check  = 'Build Eligibility'
                Status = 'OK'
                Detail = "Build $osBuild ($($ver.Product) $dispVer) is in service and receiving security updates. $($ver.Note)"
            })
        }
        'EXT' {
            $findings.Add([PSCustomObject]@{
                Check  = 'Build Eligibility'
                Status = 'WARN'
                Detail = "Build $osBuild ($($ver.Product) $dispVer) -- $($ver.Note). Plan a feature update soon."
            })
        }
        'EOS' {
            $findings.Add([PSCustomObject]@{
                Check  = 'Build Eligibility'
                Status = 'ISSUE'
                Detail = "Build $osBuild ($($ver.Product) $dispVer) is OUT OF SERVICE -- no longer receiving security updates. $($ver.Note). Feature update required immediately."
            })
        }
    }
} elseif ($osBuild) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Build Eligibility'
        Status = 'INFO'
        Detail = "Build $osBuild is not in the known lookup table. This may be a Windows Server, Insider, or very new build. Verify support status manually."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Build Eligibility'
        Status = 'WARN'
        Detail = 'Unable to determine OS build number. Cannot assess feature update eligibility.'
    })
}

# ============================================================
# Check 6 -- Third-Party AV / Security Software Detection
# ============================================================
Write-Output ''
Write-Output '--- Third-Party AV ---'

# Known-problematic products and their WU interference mechanisms
$problematicAV = @{
    'Symantec'    = 'File locks on SoftwareDistribution folder. Can cause HRESULT 0x80240022.'
    'Kaspersky'   = 'Web filter and CAPI2 certificate interception. Can block authrootstl.cab extraction.'
    'McAfee'      = 'CAPI2 hooking causes authrootstl.cab extraction failure (Event ID 11). Blocks WU certificate chain validation.'
    'Trend Micro' = 'Real-time scan blocks CBS file operations during servicing.'
    'ZoneAlarm'   = 'CAPI2 certificate interception. Can cause false certificate errors.'
    'Webroot'     = 'Kernel driver file locks on system files during update staging.'
    'Norton'      = 'File locks and schedule conflicts with WU orchestrator.'
    'Sophos'      = 'Web filter and download scanning can interfere with BITS transfers.'
    'ESET'        = 'Generally compatible but may delay BITS transfers during real-time scanning.'
    'Bitdefender' = 'Filter driver file locks in some versions. Can block CBS operations.'
}

$avProducts = @()
$avDetected = $false

# 6a -- SecurityCenter2 WMI (workstation only)
$isServer = $false
try {
    $osInfo2 = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($osInfo2.ProductType -ne 1) { $isServer = $true }
} catch { }

if (-not $isServer) {
    try {
        $secProducts = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
        foreach ($p in $secProducts) {
            if ($p.displayName -and $p.displayName -ne 'Windows Defender') {
                $avProducts += $p.displayName
                $avDetected = $true
            }
        }
    } catch {
        # SecurityCenter2 may not be available on some editions
    }
}

# 6b -- Uninstall registry scan
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$avSearchTerms = @('Symantec', 'Kaspersky', 'McAfee', 'Trend Micro', 'ZoneAlarm', 'Webroot', 'Norton', 'Sophos', 'ESET', 'Bitdefender', 'Avast', 'AVG', 'CrowdStrike', 'SentinelOne', 'Carbon Black', 'Cylance', 'Malwarebytes')

foreach ($regPath in $uninstallPaths) {
    if (Test-Path $regPath) {
        try {
            $items = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                try {
                    $props = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
                    if ($props.DisplayName) {
                        foreach ($term in $avSearchTerms) {
                            if ($props.DisplayName -match [regex]::Escape($term)) {
                                if ($avProducts -notcontains $props.DisplayName) {
                                    $avProducts += $props.DisplayName
                                    $avDetected = $true
                                }
                                break
                            }
                        }
                    }
                } catch { }
            }
        } catch { }
    }
}

if ($avDetected) {
    foreach ($product in $avProducts) {
        $isProblematic = $false
        $mechanism = ''
        foreach ($key in $problematicAV.Keys) {
            if ($product -match [regex]::Escape($key)) {
                $isProblematic = $true
                $mechanism = $problematicAV[$key]
                break
            }
        }

        if ($isProblematic) {
            $findings.Add([PSCustomObject]@{
                Check  = "Known WU Interference: $product"
                Status = 'ISSUE'
                Detail = "$mechanism Consider adding SoftwareDistribution exclusion or temporarily disabling real-time scan during update cycles."
            })
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = "Third-Party AV: $product"
                Status = 'INFO'
                Detail = "$product detected. Not on the known-problematic list, but third-party AV can still interfere with WU. Note for troubleshooting if issues persist."
            })
        }
    }
} else {
    if ($isServer) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Third-Party AV'
            Status = 'INFO'
            Detail = 'Server OS detected. SecurityCenter2 not available. Scanned Uninstall registry -- no known third-party AV found.'
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Third-Party AV'
            Status = 'OK'
            Detail = 'No third-party AV detected. Only Windows Defender active. No WU interference expected from AV.'
        })
    }
}
# ============================================================
# Check 7 -- Third-Party Update Management
# ============================================================
Write-Output ''
Write-Output '--- Update Management ---'

$mgmtTools = [System.Collections.Generic.List[string]]::new()

# SCCM / MECM
$sccmDetected = $false
try {
    $ccm = Get-Service -Name 'ccmexec' -ErrorAction Stop
    $sccmDetected = $true
    $sccmStatus = $ccm.Status
    $findings.Add([PSCustomObject]@{
        Check  = 'SCCM Client (ccmexec)'
        Status = 'INFO'
        Detail = "SCCM/MECM client installed (Service: $sccmStatus). SCCM may control update scheduling and source. If WU issues persist, escalate to SCCM admin."
    })
    $null = $mgmtTools.Add('SCCM')
} catch { }

# Intune MDM enrollment
$intuneDetected = $false
try {
    $enrollPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $enrollPath) {
        $enrollKeys = Get-ChildItem -Path $enrollPath -ErrorAction SilentlyContinue
        foreach ($ek in $enrollKeys) {
            try {
                $ekProps = Get-ItemProperty -Path $ek.PSPath -ErrorAction SilentlyContinue
                if ($ekProps.ProviderID -eq 'MS DM Server') {
                    $intuneDetected = $true
                    break
                }
            } catch { }
        }
    }
} catch { }

if ($intuneDetected) {
    $null = $mgmtTools.Add('Intune')

    # Check if Intune is actively managing update policies via Update Rings
    $mdmUpdatePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $mdmPolicyCount = 0
    $mdmPolicySummary = [System.Collections.Generic.List[string]]::new()

    if (Test-Path $mdmUpdatePath) {
        try {
            $mdmProps = Get-ItemProperty -Path $mdmUpdatePath -ErrorAction SilentlyContinue
            if ($null -ne $mdmProps) {
                $checkValues = @(
                    @{ Name = 'AllowAutoUpdate';                     Label = 'AutoUpdate' }
                    @{ Name = 'DeferFeatureUpdatesPeriodInDays';     Label = 'FeatureDeferral' }
                    @{ Name = 'DeferQualityUpdatesPeriodInDays';     Label = 'QualityDeferral' }
                    @{ Name = 'PauseFeatureUpdatesStartTime';        Label = 'FeaturePause' }
                    @{ Name = 'PauseQualityUpdatesStartTime';        Label = 'QualityPause' }
                    @{ Name = 'ConfigureDeadlineForFeatureUpdates';  Label = 'FeatureDeadline' }
                    @{ Name = 'ConfigureDeadlineForQualityUpdates';  Label = 'QualityDeadline' }
                    @{ Name = 'ExcludeWUDriversInQualityUpdate';     Label = 'DriverExclude' }
                    @{ Name = 'ProductVersion';                      Label = 'TargetVersion' }
                )
                foreach ($cv in $checkValues) {
                    if ($mdmProps.PSObject.Properties[$cv.Name]) {
                        $val = $mdmProps.($cv.Name)
                        if ($null -ne $val -and $val -ne '') {
                            $mdmPolicyCount++
                            $null = $mdmPolicySummary.Add("$($cv.Label)=$val")
                        }
                    }
                }
            }
        } catch { }
    }

    if ($mdmPolicyCount -gt 0) {
        $summaryStr = $mdmPolicySummary -join ', '
        $findings.Add([PSCustomObject]@{
            Check  = 'Intune MDM Enrollment'
            Status = 'INFO'
            Detail = "Device is enrolled in Intune MDM. Update Rings ACTIVE -- $mdmPolicyCount policy value(s) detected ($summaryStr). Run WU002 WUPolicyAudit for full MDM policy breakdown."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Intune MDM Enrollment'
            Status = 'INFO'
            Detail = 'Device is enrolled in Intune MDM, but no Update Ring policies are currently applied. Updates follow default OS behavior. If policies are expected, check Intune assignment and device sync.'
        })
    }
}

# Co-management detection (SCCM + Intune)
if ($sccmDetected -and $intuneDetected) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Co-Management Detected'
        Status = 'WARN'
        Detail = 'Both SCCM and Intune are present. This is a co-managed device. Verify the co-management workload slider to determine which system controls Windows Update. Misconfigured co-management is a top cause of update policy conflicts.'
    })
}

# Patch My PC
try {
    $pmpcs = Get-Service -Name 'PatchMyPC*' -ErrorAction SilentlyContinue
    if ($pmpcs) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Patch My PC Agent'
            Status = 'INFO'
            Detail = "Patch My PC agent detected (Service: $($pmpcs[0].Status)). Third-party patching is managed externally."
        })
        $null = $mgmtTools.Add('PatchMyPC')
    }
} catch { }

# ManageEngine
try {
    $meServices = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ManageEngine|DesktopCentral|UEMS' }
    if ($meServices) {
        $svcName = ($meServices | Select-Object -First 1).Name
        $findings.Add([PSCustomObject]@{
            Check  = 'ManageEngine Agent'
            Status = 'INFO'
            Detail = "ManageEngine agent detected (Service: $svcName). Patching may be managed externally."
        })
        $null = $mgmtTools.Add('ManageEngine')
    }
} catch { }

# Automox
try {
    $automox = Get-Service -Name 'amagent' -ErrorAction Stop
    $findings.Add([PSCustomObject]@{
        Check  = 'Automox Agent'
        Status = 'INFO'
        Detail = "Automox agent detected (Service: $($automox.Status)). Patching may be managed externally."
    })
    $null = $mgmtTools.Add('Automox')
} catch { }

# WSUS cross-reference
$wsusManaged = $false
try {
    $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (Test-Path $wuPath) {
        $wuProps = Get-ItemProperty -Path $wuPath -ErrorAction SilentlyContinue
        if ($wuProps.PSObject.Properties['WUServer'] -and $wuProps.WUServer) {
            $wsusManaged = $true
            $findings.Add([PSCustomObject]@{
                Check  = 'WSUS Managed'
                Status = 'INFO'
                Detail = "WUServer registry key present: $($wuProps.WUServer). Updates may be sourced from WSUS."
            })
            $null = $mgmtTools.Add('WSUS')
        }
    }
} catch { }

# Summary if multiple tools
if ($mgmtTools.Count -gt 1) {
    $toolList = $mgmtTools -join ', '
    $findings.Add([PSCustomObject]@{
        Check  = 'Multiple Management Tools'
        Status = 'WARN'
        Detail = "Multiple update management tools detected: $toolList. This increases the risk of conflicting schedules, sources, and deferral policies."
    })
} elseif ($mgmtTools.Count -eq 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Update Management'
        Status = 'INFO'
        Detail = 'No third-party update management tools detected. Updates are controlled locally via Windows Update settings.'
    })
}

# ============================================================
# Check 8 -- Pending .NET / Visual C++ Prerequisite Updates
# ============================================================
Write-Output ''
Write-Output '--- Prerequisites ---'

# Visual C++ Redistributable check
$vcRedists = @()
foreach ($regPath in $uninstallPaths) {
    if (Test-Path $regPath) {
        try {
            $items = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                try {
                    $props = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
                    if ($props.DisplayName -and $props.DisplayName -match 'Microsoft Visual C\+\+.*Redistributable') {
                        if ($vcRedists -notcontains $props.DisplayName) {
                            $vcRedists += $props.DisplayName
                        }
                    }
                } catch { }
            }
        } catch { }
    }
}

$hasModernVC = $false
$hasLegacyVC = $false
foreach ($vc in $vcRedists) {
    if ($vc -match '201[5-9]|202[0-9]') { $hasModernVC = $true }
    elseif ($vc -match '200[5-9]|201[0-4]') { $hasLegacyVC = $true }
}

if ($hasModernVC) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Visual C++ Redistributable'
        Status = 'OK'
        Detail = "Modern Visual C++ Redistributable (2015-2022) installed. $($vcRedists.Count) package(s) total."
    })
} elseif ($hasLegacyVC) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Visual C++ Redistributable'
        Status = 'WARN'
        Detail = "Only legacy Visual C++ Redistributable versions detected ($($vcRedists.Count) package(s)). No modern 2015+ redistributable found. Some servicing operations may fail."
    })
} elseif ($vcRedists.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Visual C++ Redistributable'
        Status = 'INFO'
        Detail = "$($vcRedists.Count) Visual C++ Redistributable package(s) found."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Visual C++ Redistributable'
        Status = 'WARN'
        Detail = 'No Visual C++ Redistributable packages detected. Some servicing stack extensions and WU-related components depend on vcruntime.'
    })
}

# .NET pending updates
$dotNetPending = $false
try {
    $cbsReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if ($cbsReboot) {
        # Check if any .NET-related packages are pending
        try {
            $pendingPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
            if (Test-Path $pendingPath) {
                $pendingItems = Get-ChildItem -Path $pendingPath -ErrorAction SilentlyContinue
                foreach ($pi in $pendingItems) {
                    if ($pi.Name -match 'NetFx|NDP') {
                        $dotNetPending = $true
                        break
                    }
                }
            }
        } catch { }
    }
} catch { }

if ($dotNetPending) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Pending .NET Update'
        Status = 'WARN'
        Detail = 'A .NET Framework update is pending CBS commit. A reboot may be required before WU can install further updates.'
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
    Write-Output 'RESULT: No environment issues detected. WU agent and machine environment look healthy.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] above."
}

Write-Output ''
Write-Output 'NEXT:   If third-party AV flagged  -> consider temporarily disabling or excluding WU from AV scanning'
Write-Output '        If SCCM/Intune managing    -> escalate to the MDM admin, not WU directly'
Write-Output '        If no issues found         -> run WU008 WUDatastoreRepair for deeper repair'
Write-Output ''
