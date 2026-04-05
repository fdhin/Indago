# DEF003_DEFThirdPartyAV.ps1
# Scriptlet: DEF003 - Third-Party AV Conflict & Coexistence
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Third-Party AV Conflict & Coexistence ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Helper: decode productState bitmask
# ---------------------------------------------------------------
function Decode-ProductState {
    param([uint32]$State)
    $engineBits = $State -band 0xF000
    $sigBits    = $State -band 0x00F0
    $originBits = $State -band 0x0F00

    $engineStr = switch ($engineBits) {
        0x0000 { 'Off' }
        0x1000 { 'On' }
        0x2000 { 'Snoozed' }
        0x3000 { 'Expired' }
        default { "Unknown (0x$($engineBits.ToString('X4')))" }
    }
    $sigStr = switch ($sigBits) {
        0x0000 { 'Current' }
        0x0010 { 'Outdated' }
        default { "Unknown (0x$($sigBits.ToString('X4')))" }
    }
    $originStr = switch ($originBits) {
        0x0100 { 'Microsoft' }
        0x0000 { 'Third-party' }
        default { "Unknown (0x$($originBits.ToString('X4')))" }
    }
    return @{ Engine = $engineStr; Signatures = $sigStr; Origin = $originStr }
}

# ---------------------------------------------------------------
# Check 1: Security Center Deep Enumeration
# ---------------------------------------------------------------
Write-Output '--- Security Center AV Products ---'

$avProducts = $null
$secCenterAvailable = $true
try {
    $avProducts = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)
} catch {
    $secCenterAvailable = $false
}

# Store products for cross-reference in Check 3
$thirdPartyProducts = [System.Collections.Generic.List[PSCustomObject]]::new()
$defenderProduct = $null
$ghostProducts = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $secCenterAvailable) {
    Write-Output '[i]   Security Center'
    Write-Output '       SecurityCenter2 WMI namespace not available.'
    Write-Output '       This is expected on Windows Server. Skipping to remaining checks.'
    Write-Output ''
} elseif ($null -eq $avProducts -or $avProducts.Count -eq 0) {
    Write-Output '[!!]  Security Center'
    Write-Output '       No antivirus products registered. The system may be unprotected.'
    $issueCount++
    Write-Output ''
} else {
    foreach ($av in $avProducts) {
        $name = $av.displayName
        $guid = $av.instanceGuid
        $productExe = $av.pathToSignedProductExe
        $reportingExe = $av.pathToSignedReportingExe
        $stateRaw = [uint32]$av.productState
        $decoded = Decode-ProductState -State $stateRaw

        $isDefender = ($decoded.Origin -eq 'Microsoft')
        $productExeExists = $false
        $reportingExeExists = $false

        if (-not [string]::IsNullOrWhiteSpace($productExe)) {
            $productExeExists = Test-Path -Path $productExe -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($reportingExe)) {
            $reportingExeExists = Test-Path -Path $reportingExe -ErrorAction SilentlyContinue
        }

        $info = [PSCustomObject]@{
            Name        = $name
            GUID        = $guid
            Engine      = $decoded.Engine
            Signatures  = $decoded.Signatures
            Origin      = $decoded.Origin
            ProductExe  = $productExe
            ProdExeOK   = $productExeExists
            ReportExe   = $reportingExe
            RptExeOK    = $reportingExeExists
            IsDefender  = $isDefender
            IsGhost     = $false
        }

        if ($isDefender) {
            $defenderProduct = $info
            if ($decoded.Engine -eq 'On') {
                Write-Output "[OK]  $name"
                Write-Output "       State: $($decoded.Engine), Signatures: $($decoded.Signatures), Origin: $($decoded.Origin)."
            } else {
                Write-Output "[!]   $name"
                Write-Output "       State: $($decoded.Engine), Signatures: $($decoded.Signatures)."
                Write-Output "       Defender engine is not in the On state."
                $warnCount++
            }
            if (-not [string]::IsNullOrWhiteSpace($productExe)) {
                Write-Output "       Exe: $productExe ($(if($productExeExists){'found'}else{'MISSING'}))."
            }
        } else {
            # Third-party product
            $isGhost = (-not $productExeExists) -or (-not $reportingExeExists)
            $info.IsGhost = $isGhost

            if ($isGhost) {
                Write-Output "[!!]  $name -- GHOST REGISTRATION"
                Write-Output "       Product is registered in Security Center but executable(s) are MISSING."
                if (-not [string]::IsNullOrWhiteSpace($productExe)) {
                    Write-Output "       Product exe: $productExe ($(if($productExeExists){'found'}else{'MISSING'}))."
                }
                if (-not [string]::IsNullOrWhiteSpace($reportingExe)) {
                    Write-Output "       Reporting exe: $reportingExe ($(if($reportingExeExists){'found'}else{'MISSING'}))."
                }
                Write-Output "       Instance GUID: $guid"
                Write-Output "       This ghost may force Defender into passive mode while providing no protection."
                $null = $ghostProducts.Add($info)
                $issueCount++
            } elseif ($decoded.Engine -eq 'On') {
                Write-Output "[i]   $name"
                Write-Output "       State: $($decoded.Engine), Signatures: $($decoded.Signatures), Origin: $($decoded.Origin)."
                Write-Output "       Exe: $productExe (found)."
                Write-Output "       Instance GUID: $guid"
            } elseif ($decoded.Engine -eq 'Off' -or $decoded.Engine -eq 'Snoozed' -or $decoded.Engine -eq 'Expired') {
                Write-Output "[!]   $name"
                Write-Output "       State: $($decoded.Engine), Signatures: $($decoded.Signatures)."
                Write-Output "       Product is registered but NOT actively protecting."
                Write-Output "       Exe: $productExe ($(if($productExeExists){'found'}else{'MISSING'}))."
                Write-Output "       Instance GUID: $guid"
                $warnCount++
            } else {
                Write-Output "[i]   $name"
                Write-Output "       State: $($decoded.Engine), Signatures: $($decoded.Signatures), Origin: $($decoded.Origin)."
                Write-Output "       Instance GUID: $guid"
            }
            $null = $thirdPartyProducts.Add($info)
        }
    }
    Write-Output ''
}

# ---------------------------------------------------------------
# Check 2: AV Remnant Scan
# ---------------------------------------------------------------
Write-Output '--- AV Remnant Scan ---'

# Build a set of active vendor names from Security Center for cross-reference
$activeVendors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($tp in $thirdPartyProducts) {
    $n = $tp.Name
    # Map display names to vendor keys
    if ($n -match 'Norton|Symantec|Broadcom') { $null = $activeVendors.Add('Symantec') }
    if ($n -match 'McAfee|Trellix')           { $null = $activeVendors.Add('McAfee') }
    if ($n -match 'Kaspersky')                { $null = $activeVendors.Add('Kaspersky') }
    if ($n -match 'ESET')                     { $null = $activeVendors.Add('ESET') }
    if ($n -match 'Sophos')                   { $null = $activeVendors.Add('Sophos') }
    if ($n -match 'Trend\s*Micro')            { $null = $activeVendors.Add('TrendMicro') }
    if ($n -match 'Avast|AVG')                { $null = $activeVendors.Add('Avast') }
    if ($n -match 'Bitdefender')              { $null = $activeVendors.Add('Bitdefender') }
    if ($n -match 'Webroot')                  { $null = $activeVendors.Add('Webroot') }
    if ($n -match 'Malwarebytes')             { $null = $activeVendors.Add('Malwarebytes') }
}

# 2a: Vendor-specific registry remnants
$vendorRegPaths = @(
    @{ Vendor = 'Symantec';      Key = 'Norton / Symantec';  Paths = @('HKLM:\SOFTWARE\Symantec') }
    @{ Vendor = 'McAfee';        Key = 'McAfee / Trellix';   Paths = @('HKLM:\SOFTWARE\McAfee') }
    @{ Vendor = 'Kaspersky';     Key = 'Kaspersky';          Paths = @('HKLM:\SOFTWARE\KasperskyLab') }
    @{ Vendor = 'ESET';          Key = 'ESET';               Paths = @('HKLM:\SOFTWARE\ESET') }
    @{ Vendor = 'Sophos';        Key = 'Sophos';             Paths = @('HKLM:\SOFTWARE\Sophos') }
    @{ Vendor = 'TrendMicro';    Key = 'Trend Micro';        Paths = @('HKLM:\SOFTWARE\TrendMicro', 'HKLM:\SOFTWARE\WOW6432Node\TrendMicro') }
    @{ Vendor = 'Avast';         Key = 'Avast / AVG';        Paths = @('HKLM:\SOFTWARE\AVAST Software', 'HKLM:\SOFTWARE\AVG') }
    @{ Vendor = 'Bitdefender';   Key = 'Bitdefender';        Paths = @('HKLM:\SOFTWARE\Bitdefender') }
    @{ Vendor = 'Webroot';       Key = 'Webroot';            Paths = @('HKLM:\SOFTWARE\WRData') }
    @{ Vendor = 'Malwarebytes';  Key = 'Malwarebytes';       Paths = @('HKLM:\SOFTWARE\Malwarebytes') }
)

$regRemnants = [System.Collections.Generic.List[string]]::new()
foreach ($v in $vendorRegPaths) {
    if ($activeVendors.Contains($v.Vendor)) { continue }
    foreach ($p in $v.Paths) {
        if (Test-Path -Path $p -ErrorAction SilentlyContinue) {
            $null = $regRemnants.Add($v.Key)
            Write-Output "[!]   Registry Remnant: $($v.Key)"
            Write-Output "       Path: $p"
            Write-Output "       Product is not registered in Security Center but registry keys remain."
            Write-Output "       May need vendor-specific removal tool to clean up."
            $warnCount++
            break
        }
    }
}

if ($regRemnants.Count -eq 0) {
    Write-Output '[OK]  Registry Remnants'
    Write-Output '       No third-party AV remnant registry keys detected.'
}

Write-Output ''

# 2b: Leftover services
Write-Output '--- Leftover AV Services ---'

$vendorSvcPatterns = @(
    @{ Vendor = 'McAfee';      Key = 'McAfee / Trellix';  Patterns = @('mcshield', 'mfemms', 'McAfee*') }
    @{ Vendor = 'Symantec';    Key = 'Norton / Symantec';  Patterns = @('Norton*', 'Symantec*', 'NortonSecurity') }
    @{ Vendor = 'Kaspersky';   Key = 'Kaspersky';          Patterns = @('AVP*', 'klnagent', 'kavfs*') }
    @{ Vendor = 'ESET';        Key = 'ESET';               Patterns = @('ekrn', 'ESET*') }
    @{ Vendor = 'Sophos';      Key = 'Sophos';             Patterns = @('Sophos*', 'SAVService') }
    @{ Vendor = 'TrendMicro';  Key = 'Trend Micro';        Patterns = @('Trend*', 'TMBM*', 'PccNT*') }
    @{ Vendor = 'Avast';       Key = 'Avast / AVG';        Patterns = @('avast*', 'avg*', 'AvastSvc') }
    @{ Vendor = 'Bitdefender'; Key = 'Bitdefender';        Patterns = @('bdservicehost', 'EPSecurityService', 'EPProtectedService') }
    @{ Vendor = 'Webroot';     Key = 'Webroot';            Patterns = @('WRSVC', 'WRCoreService') }
    @{ Vendor = 'Malwarebytes';Key = 'Malwarebytes';       Patterns = @('MBAMService', 'mbam*') }
)

$svcRemnants = 0
foreach ($v in $vendorSvcPatterns) {
    if ($activeVendors.Contains($v.Vendor)) { continue }
    foreach ($pattern in $v.Patterns) {
        $svcs = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($svc in $svcs) {
            $svcRemnants++
            if ($svc.StartType -eq 'Disabled') {
                Write-Output "[!]   Leftover Service: $($svc.Name) ($($v.Key))"
                Write-Output "       Status: $($svc.Status), Start type: Disabled."
                Write-Output "       Service remains from uninstalled $($v.Key)."
                $warnCount++
            } elseif ($svc.Status -ne 'Running' -and $svc.StartType -match 'Auto') {
                Write-Output "[!!]  Orphaned Service: $($svc.Name) ($($v.Key))"
                Write-Output "       Status: $($svc.Status), Start type: $($svc.StartType)."
                Write-Output "       Service is trying to start but failing. Product is no longer installed."
                $issueCount++
            } elseif ($svc.Status -eq 'Running') {
                Write-Output "[!]   Running Service: $($svc.Name) ($($v.Key))"
                Write-Output "       Service is running but product is not registered in Security Center."
                Write-Output "       Investigate whether the product is partially installed."
                $warnCount++
            } else {
                Write-Output "[i]   Leftover Service: $($svc.Name) ($($v.Key))"
                Write-Output "       Status: $($svc.Status), Start type: $($svc.StartType)."
            }
        }
    }
}

if ($svcRemnants -eq 0) {
    Write-Output '[OK]  Leftover AV Services'
    Write-Output '       No orphaned third-party AV services found.'
}

Write-Output ''

# 2c: Leftover filter drivers
Write-Output '--- Leftover Filter Drivers ---'

$vendorDrivers = @(
    @{ Vendor = 'McAfee';      Key = 'McAfee / Trellix';  Files = @('mfehidk.sys', 'mfefirek.sys', 'mfencbdc.sys') }
    @{ Vendor = 'ESET';        Key = 'ESET';               Files = @('ehdrv.sys', 'epfwwfp.sys') }
    @{ Vendor = 'Kaspersky';   Key = 'Kaspersky';          Files = @('klif.sys', 'klhk.sys', 'klboot.sys') }
    @{ Vendor = 'Sophos';      Key = 'Sophos';             Files = @('savonaccess.sys', 'SophosED.sys') }
    @{ Vendor = 'TrendMicro';  Key = 'Trend Micro';        Files = @('tmwfp.sys', 'TmXPflt.sys') }
    @{ Vendor = 'Avast';       Key = 'Avast / AVG';        Files = @('aswSP.sys', 'avgmfx64.sys', 'aswids.sys') }
    @{ Vendor = 'Bitdefender'; Key = 'Bitdefender';        Files = @('trufos.sys', 'bdsandbox.sys') }
    @{ Vendor = 'Webroot';     Key = 'Webroot';            Files = @('WRkrn.sys') }
    @{ Vendor = 'Malwarebytes';Key = 'Malwarebytes';       Files = @('mbam.sys', 'MBAMSwissArmy.sys', 'farflt.sys') }
    @{ Vendor = 'Symantec';    Key = 'Norton / Symantec';  Files = @('n360drv.sys', 'srtsp64.sys') }
)

$driverDir = Join-Path $env:SystemRoot 'System32\drivers'
$drvRemnants = 0
foreach ($v in $vendorDrivers) {
    if ($activeVendors.Contains($v.Vendor)) { continue }
    foreach ($file in $v.Files) {
        $fullPath = Join-Path $driverDir $file
        if (Test-Path -Path $fullPath -ErrorAction SilentlyContinue) {
            $drvRemnants++
            Write-Output "[!]   Leftover Driver: $file ($($v.Key))"
            Write-Output "       Path: $fullPath"
            Write-Output "       $($v.Key) is no longer active but this kernel driver remains."
            Write-Output "       May cause I/O conflicts or BSODs. Use vendor removal tool to clean up."
            $warnCount++
        }
    }
}

if ($drvRemnants -eq 0) {
    Write-Output '[OK]  Leftover Filter Drivers'
    Write-Output '       No orphaned third-party AV filter drivers found in the drivers directory.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Ghost Registration Analysis
# ---------------------------------------------------------------
Write-Output '--- Ghost Registration Analysis ---'

$defenderMode = $null
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $defenderMode = $mpStatus.AMRunningMode
} catch { }

if (-not $secCenterAvailable) {
    Write-Output '[i]   Ghost Registration Analysis'
    Write-Output '       Skipped -- Security Center not available on this OS.'
} elseif ($ghostProducts.Count -gt 0) {
    foreach ($ghost in $ghostProducts) {
        if ($defenderMode -eq 'Passive Mode' -or $defenderMode -eq 'SxS Passive Mode') {
            Write-Output "[!!]  CRITICAL: Endpoint may be UNPROTECTED"
            Write-Output "       Ghost product: $($ghost.Name)"
            Write-Output "       Instance GUID: $($ghost.GUID)"
            Write-Output "       Defender is in $defenderMode because Windows thinks $($ghost.Name) is protecting."
            Write-Output "       But the product executable is MISSING -- nobody is scanning."
            Write-Output "       -> Run DEF008 DEFRemediation to remove the ghost registration (GUID above)."
            $issueCount++
        } else {
            Write-Output "[!]   Ghost Registration (non-critical)"
            Write-Output "       Ghost product: $($ghost.Name)"
            Write-Output "       Instance GUID: $($ghost.GUID)"
            Write-Output "       Defender is in $defenderMode mode -- it has recovered despite the ghost."
            Write-Output "       Still recommended to remove the stale registration via DEF008."
            $warnCount++
        }
    }
} else {
    # Check for the subtle case: no ghost, but third-party registered + Off/Snoozed/Expired + Defender passive
    $dangerousCoexist = $false
    foreach ($tp in $thirdPartyProducts) {
        if (-not $tp.IsGhost -and ($tp.Engine -eq 'Off' -or $tp.Engine -eq 'Snoozed' -or $tp.Engine -eq 'Expired')) {
            if ($defenderMode -eq 'Passive Mode' -or $defenderMode -eq 'SxS Passive Mode') {
                Write-Output "[!!]  Protection Gap Detected"
                Write-Output "       $($tp.Name): registered and installed, but engine is $($tp.Engine)."
                Write-Output "       Defender is in $defenderMode -- it is not scanning because it defers to $($tp.Name)."
                Write-Output "       But $($tp.Name) is not actively protecting. Nobody is scanning."
                Write-Output "       -> Activate $($tp.Name), or uninstall it and let Defender take over."
                $issueCount++
                $dangerousCoexist = $true
            }
        }
    }

    if (-not $dangerousCoexist) {
        $activeThirdParty = @($thirdPartyProducts | Where-Object { $_.Engine -eq 'On' -and (-not $_.IsGhost) })
        if ($activeThirdParty.Count -gt 0) {
            if ($defenderMode -eq 'Passive Mode' -or $defenderMode -eq 'EDR Block Mode' -or $defenderMode -eq 'SxS Passive Mode') {
                Write-Output '[OK]  Coexistence'
                Write-Output "       $($activeThirdParty[0].Name) is the active AV protector."
                Write-Output "       Defender is correctly in $defenderMode. No ghost registrations."
            } elseif ($defenderMode -eq 'Normal') {
                Write-Output '[!]   Potential Dual-Engine Conflict'
                Write-Output "       $($activeThirdParty[0].Name) is registered and On."
                Write-Output "       But Defender is also in Normal (active) mode."
                Write-Output "       Both engines scanning simultaneously may cause severe performance issues."
                $warnCount++
            } else {
                Write-Output "[i]   Coexistence state: Defender mode = $defenderMode."
                Write-Output "       Third-party AV: $($activeThirdParty[0].Name) (On)."
            }
        } else {
            if ($null -ne $defenderMode -and $defenderMode -eq 'Normal') {
                Write-Output '[OK]  No Ghost Registrations'
                Write-Output '       Defender is the sole and active protector. No third-party conflicts.'
            } elseif ($null -ne $defenderMode) {
                Write-Output "[i]   Defender mode: $defenderMode. No third-party AV registered."
            } else {
                Write-Output '[i]   Could not determine Defender running mode (Get-MpComputerStatus failed).'
            }
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Defender Policy Overrides
# ---------------------------------------------------------------
Write-Output '--- Defender Policy Overrides ---'

$gpoPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$mdmPolicyPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender'

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

# DisableAntiSpyware
$dasGPO = Get-RegValue -Path $gpoPolicyPath -Name 'DisableAntiSpyware'
$dasSource = $null
if ($null -ne $dasGPO -and $dasGPO -eq 1) {
    $dasSource = 'GPO'
    Write-Output '[!!]  DisableAntiSpyware = 1 (GPO)'
    Write-Output "       Path: $gpoPolicyPath\DisableAntiSpyware"
    Write-Output '       Defender is administratively disabled by Group Policy.'
    Write-Output '       If this machine should use Defender, remove this key or update the GPO.'
    Write-Output '       Note: Ignored on platform >= 4.18.2108.4 with Tamper Protection enabled,'
    Write-Output '       but its presence still causes Intune compliance confusion.'
    $issueCount++
} else {
    Write-Output '[OK]  DisableAntiSpyware (GPO)'
    Write-Output '       Not set or set to 0. Defender is allowed by Group Policy.'
}

# DisableAntiVirus
$davGPO = Get-RegValue -Path $gpoPolicyPath -Name 'DisableAntiVirus'
if ($null -ne $davGPO -and $davGPO -eq 1) {
    Write-Output '[!!]  DisableAntiVirus = 1 (GPO)'
    Write-Output "       Path: $gpoPolicyPath\DisableAntiVirus"
    Write-Output '       Defender AV component is administratively disabled by Group Policy.'
    $issueCount++
} else {
    Write-Output '[OK]  DisableAntiVirus (GPO)'
    Write-Output '       Not set or set to 0. Defender AV component is allowed.'
}

# MDM: Check for conflicting policy
$mdmAllowRTP = Get-RegValue -Path $mdmPolicyPath -Name 'AllowRealtimeMonitoring'
if ($null -ne $mdmAllowRTP) {
    if ($mdmAllowRTP -eq 0) {
        Write-Output '[!!]  MDM: AllowRealtimeMonitoring = 0'
        Write-Output "       Path: $mdmPolicyPath\AllowRealtimeMonitoring"
        Write-Output '       MDM/Intune policy is disabling real-time monitoring.'
        $issueCount++
    } else {
        Write-Output '[i]   MDM: AllowRealtimeMonitoring = 1'
        Write-Output '       MDM/Intune policy allows real-time monitoring.'
    }
}

# Cross-reference: GPO disables + MDM enables = entanglement
if ($dasSource -eq 'GPO' -and $null -ne $mdmAllowRTP -and $mdmAllowRTP -ne 0) {
    Write-Output ''
    Write-Output '[!!]  Policy Entanglement Detected'
    Write-Output '       GPO sets DisableAntiSpyware = 1 (disable Defender).'
    Write-Output '       MDM sets AllowRealtimeMonitoring = 1 (enable Defender).'
    Write-Output '       These policies conflict. The GPO path takes precedence unless'
    Write-Output '       MDMWinsOverGP is configured or Tamper Protection overrides the GPO key.'
    Write-Output '       -> Remove the legacy GPO key or set MDMWinsOverGP = 1.'
    Write-Output '       -> If Tamper Protection is active, the GPO key may already be ignored,'
    Write-Output '          but remove it anyway to prevent compliance reporting confusion.'
    $issueCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. No third-party AV conflicts or remnants found.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review the flagged items above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Third-party AV conflicts need attention."
}

Write-Output ''
Write-Output 'NEXT:   If ghost registration found       -> run DEF008 DEFRemediation to clean up'
Write-Output '        If third-party AV active + working -> Defender passive mode is correct; verify'
Write-Output '          compliance policy accepts this configuration'
Write-Output '        If DisableAntiSpyware present      -> run DEF008 DEFRemediation to remove (if not policy-managed)'
Write-Output '        If remnant drivers/services found  -> may need vendor-specific removal tool'
