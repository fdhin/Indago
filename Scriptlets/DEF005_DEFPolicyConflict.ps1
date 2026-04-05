# DEF005_DEFPolicyConflict.ps1
# Scriptlet: DEF005 - Defender Policy Source Conflict Detection
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Defender Policy Source Conflict Detection ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Registry base paths
# ---------------------------------------------------------------
$gpoBase  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$mdmBase  = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender'
$localBase = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'

# Helper: read registry value safely
function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($null -ne $item) {
            $val = $item.$Name
            if ($null -ne $val) { return $val }
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------
# Get effective preferences via Get-MpPreference
# ---------------------------------------------------------------
$mpPref = $null
try { $mpPref = Get-MpPreference -ErrorAction Stop } catch { }

$mpStatus = $null
try { $mpStatus = Get-MpComputerStatus -ErrorAction Stop } catch { }

# ---------------------------------------------------------------
# Check 1: Core Protection Settings (Side-by-Side)
# ---------------------------------------------------------------
Write-Output '--- Core Protection Settings ---'

# Define settings to compare
# Format: DisplayName, GPO subpath, GPO value name, GPO invert (1=disable->0=enable),
#         MDM value name, MDM invert, MpPref property name, Description of enabled state
$settings = @(
    @('Real-Time Protection',    '\Real-Time Protection', 'DisableRealtimeMonitoring', $true,  'AllowRealtimeMonitoring', $false, 'DisableRealtimeMonitoring', 'RTP'),
    @('Behavior Monitoring',     '\Real-Time Protection', 'DisableBehaviorMonitoring', $true,  'AllowBehaviorMonitoring', $false, 'DisableBehaviorMonitoring', 'Behavior monitoring'),
    @('IOAV Protection',         '\Real-Time Protection', 'DisableIOAVProtection',     $true,  'AllowIOAVProtection',     $false, 'DisableIOAVProtection',     'Download/attachment scanning'),
    @('Cloud Protection (MAPS)', '\Spynet',               'SpynetReporting',           $false, 'AllowCloudProtection',    $false, 'MAPSReporting',             'Cloud-delivered protection'),
    @('Sample Submission',       '\Spynet',               'SubmitSamplesConsent',       $false, 'SubmitSamplesConsent',    $false, 'SubmitSamplesConsent',      'Sample auto-submission'),
    @('Network Protection',      '\Windows Defender Exploit Guard\Network Protection', 'EnableNetworkProtection', $false, 'EnableNetworkProtection', $false, 'EnableNetworkProtection', 'Network protection'),
    @('PUA Protection',          '',                      'PUAProtection',             $false, 'PUAProtection',           $false, 'PUAProtection',             'PUA detection'),
    @('Controlled Folder Access', '\Windows Defender Exploit Guard\Controlled Folder Access', 'EnableControlledFolderAccess', $false, 'EnableControlledFolderAccess', $false, 'EnableControlledFolderAccess', 'Ransomware folder protection'),
    @('Scan Schedule Day',       '\Scan',                 'ScanScheduleDay',           $false, 'ScanScheduleDay',         $false, 'ScanScheduleDay',           'Scheduled scan day')
)

$dayNames = @('Everyday','Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Never')

foreach ($s in $settings) {
    $displayName = $s[0]
    $gpoSubkey   = $s[1]
    $gpoValName  = $s[2]
    $gpoInvert   = $s[3]
    $mdmValName  = $s[4]
    $mdmInvert   = $s[5]
    $prefProp    = $s[6]
    $desc        = $s[7]

    $gpoPath = $gpoBase
    if ($gpoSubkey.Length -gt 0) { $gpoPath = $gpoBase + $gpoSubkey }

    $gpoVal = Get-RegVal -Path $gpoPath -Name $gpoValName
    $mdmVal = Get-RegVal -Path $mdmBase -Name $mdmValName
    $effVal = $null
    if ($null -ne $mpPref) {
        try { $effVal = $mpPref.$prefProp } catch { }
    }

    # Build GPO string
    $gpoStr = 'Not set'
    if ($null -ne $gpoVal) {
        if ($displayName -eq 'Scan Schedule Day') {
            $dayIdx = [int]$gpoVal
            if ($dayIdx -ge 0 -and $dayIdx -lt $dayNames.Count) { $gpoStr = "$gpoValName = $gpoVal ($($dayNames[$dayIdx]))" }
            else { $gpoStr = "$gpoValName = $gpoVal" }
        } elseif ($gpoInvert) {
            if ($gpoVal -eq 1) { $gpoStr = "$gpoValName = 1 (DISABLED)" }
            elseif ($gpoVal -eq 0) { $gpoStr = "$gpoValName = 0 (Enabled)" }
            else { $gpoStr = "$gpoValName = $gpoVal" }
        } else {
            $gpoStr = "$gpoValName = $gpoVal"
        }
    }

    # Build MDM string
    $mdmStr = 'Not set'
    if ($null -ne $mdmVal) {
        if ($displayName -eq 'Scan Schedule Day') {
            $dayIdx = [int]$mdmVal
            if ($dayIdx -ge 0 -and $dayIdx -lt $dayNames.Count) { $mdmStr = "$mdmValName = $mdmVal ($($dayNames[$dayIdx]))" }
            else { $mdmStr = "$mdmValName = $mdmVal" }
        } elseif ($mdmInvert) {
            if ($mdmVal -eq 1) { $mdmStr = "$mdmValName = 1 (DISABLED)" }
            elseif ($mdmVal -eq 0) { $mdmStr = "$mdmValName = 0 (Enabled)" }
            else { $mdmStr = "$mdmValName = $mdmVal" }
        } else {
            $mdmStr = "$mdmValName = $mdmVal"
        }
    }

    # Build effective string
    $effStr = 'Unknown'
    if ($null -ne $effVal) {
        if ($displayName -eq 'Scan Schedule Day') {
            $dayIdx = [int]$effVal
            if ($dayIdx -ge 0 -and $dayIdx -lt $dayNames.Count) { $effStr = "$effVal ($($dayNames[$dayIdx]))" }
            else { $effStr = "$effVal" }
        } elseif ($gpoInvert) {
            if ($effVal -eq $true -or $effVal -eq 1) { $effStr = 'DISABLED' }
            else { $effStr = 'Enabled' }
        } else {
            $effStr = "$effVal"
        }
    }

    # Detect conflict
    $isConflict = $false
    $isDangerous = $false

    if ($null -ne $gpoVal -and $null -ne $mdmVal) {
        if ($gpoInvert -and $mdmInvert) {
            if ($gpoVal -ne $mdmVal) { $isConflict = $true }
        } elseif ($gpoInvert -and (-not $mdmInvert)) {
            # GPO disable=1 vs MDM allow=1 -> both say opposite things
            if ($gpoVal -eq 1 -and $mdmVal -eq 1) { $isConflict = $true }
            if ($gpoVal -eq 0 -and $mdmVal -eq 0) { $isConflict = $true }
        } elseif ((-not $gpoInvert) -and (-not $mdmInvert)) {
            if ($gpoVal -ne $mdmVal) { $isConflict = $true }
        }
    }

    # Dangerous pattern: GPO disabling critical protection
    if ($gpoInvert -and $null -ne $gpoVal -and $gpoVal -eq 1) {
        $isDangerous = $true
    }
    # Dangerous: MAPS/cloud set to 0 by GPO
    if ($displayName -eq 'Cloud Protection (MAPS)' -and $null -ne $gpoVal -and $gpoVal -eq 0) {
        $isDangerous = $true
    }

    if ($isConflict) {
        Write-Output "[!!]  $displayName -- CONFLICT"
        Write-Output "       GPO: $gpoStr. MDM: $mdmStr. Effective: $effStr."
        Write-Output "       GPO takes precedence over MDM unless MDMWinsOverGP is set"
        Write-Output "       (and even then, it does NOT apply to Defender CSP settings)."
        $issueCount++
    } elseif ($isDangerous) {
        Write-Output "[!!]  $displayName -- DANGEROUS"
        Write-Output "       GPO: $gpoStr. MDM: $mdmStr. Effective: $effStr."
        Write-Output "       GPO is disabling $desc. This overrides any MDM/Intune policy."
        $issueCount++
    } else {
        Write-Output "[OK]  $displayName"
        Write-Output "       GPO: $gpoStr. MDM: $mdmStr. Effective: $effStr."
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: Exclusion Source Comparison
# ---------------------------------------------------------------
Write-Output '--- Exclusion Source Comparison ---'

$exclTypes = @(
    @('Path',      'Paths',      'ExcludedPaths',      'ExclusionPath'),
    @('Extension', 'Extensions', 'ExcludedExtensions', 'ExclusionExtension'),
    @('Process',   'Processes',  'ExcludedProcesses',  'ExclusionProcess')
)

$exclIssues = 0
$totalGpo = 0
$totalMdm = 0
$totalLocal = 0

foreach ($et in $exclTypes) {
    $typeName  = $et[0]
    $gpoSub    = $et[1]
    $mdmName   = $et[2]
    $prefName  = $et[3]

    $gpoExclPath = "$gpoBase\Exclusions\$gpoSub"
    $gpoCount = 0
    if (Test-Path -Path $gpoExclPath) {
        try {
            $gpoItems = Get-Item -Path $gpoExclPath -ErrorAction Stop
            $gpoCount = @($gpoItems.Property).Count
        } catch { }
    }

    $mdmCount = 0
    $mdmExclVal = Get-RegVal -Path $mdmBase -Name $mdmName
    if ($null -ne $mdmExclVal -and "$mdmExclVal".Length -gt 0) {
        $mdmCount = @("$mdmExclVal" -split '\|').Count
    }

    $localCount = 0
    if ($null -ne $mpPref) {
        try {
            $localItems = $mpPref.$prefName
            if ($null -ne $localItems) { $localCount = @($localItems).Count }
        } catch { }
    }

    $totalGpo   += $gpoCount
    $totalMdm   += $mdmCount
    $totalLocal += $localCount

    if ($gpoCount -gt 0 -and $mdmCount -gt 0) {
        Write-Output "[!]   $typeName Exclusions -- Multi-source"
        Write-Output "       GPO: $gpoCount. MDM: $mdmCount. Effective (merged): $localCount."
        Write-Output "       Both GPO and MDM define $typeName exclusions. Check for conflicts."
        $exclIssues++
        $warnCount++
    } else {
        Write-Output "[OK]  $typeName Exclusions"
        Write-Output "       GPO: $gpoCount. MDM: $mdmCount. Effective: $localCount."
    }
}

# Check DisableLocalAdminMerge
$localMerge = Get-RegVal -Path $gpoBase -Name 'DisableLocalAdminMerge'
if ($null -ne $localMerge -and $localMerge -eq 1) {
    Write-Output '[!]   DisableLocalAdminMerge = 1'
    Write-Output '       Local exclusions are IGNORED. Only GPO/MDM exclusions apply.'
    Write-Output '       Any exclusions set via Set-MpPreference or the GUI are not active.'
    $warnCount++
} else {
    Write-Output '[OK]  DisableLocalAdminMerge'
    Write-Output '       Not set or = 0. Local exclusions merge with GPO/MDM (default).'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: ASR Rule Source Comparison
# ---------------------------------------------------------------
Write-Output '--- ASR Rule Source Comparison ---'

$gpoAsrPath = "$gpoBase\Windows Defender Exploit Guard\ASR\Rules"
$gpoAsrRules = @{}
if (Test-Path -Path $gpoAsrPath) {
    try {
        $gpoAsrItem = Get-Item -Path $gpoAsrPath -ErrorAction Stop
        foreach ($prop in $gpoAsrItem.Property) {
            $val = Get-RegVal -Path $gpoAsrPath -Name $prop
            if ($null -ne $val) { $gpoAsrRules[$prop.ToLower()] = $val }
        }
    } catch { }
}

$effAsrIds = @()
$effAsrActions = @()
if ($null -ne $mpPref) {
    try {
        if ($null -ne $mpPref.AttackSurfaceReductionRules_Ids) {
            $effAsrIds = @($mpPref.AttackSurfaceReductionRules_Ids)
        }
        if ($null -ne $mpPref.AttackSurfaceReductionRules_Actions) {
            $effAsrActions = @($mpPref.AttackSurfaceReductionRules_Actions)
        }
    } catch { }
}

$asrActionNames = @{ 0 = 'Disabled'; 1 = 'Block'; 2 = 'Audit'; 6 = 'Warn' }

$asrConflicts = 0
$allGuids = [System.Collections.Generic.List[string]]::new()
foreach ($k in $gpoAsrRules.Keys) { if (-not $allGuids.Contains($k)) { $null = $allGuids.Add($k) } }
for ($i = 0; $i -lt $effAsrIds.Count; $i++) {
    $g = "$($effAsrIds[$i])".ToLower()
    if (-not $allGuids.Contains($g)) { $null = $allGuids.Add($g) }
}

if ($allGuids.Count -eq 0) {
    Write-Output '[i]   ASR Rules: Not configured'
    Write-Output '       No ASR rules found in GPO or effective policy.'
} else {
    foreach ($guid in $allGuids) {
        $gpoAction = $null
        if ($gpoAsrRules.ContainsKey($guid)) { $gpoAction = $gpoAsrRules[$guid] }

        $effAction = $null
        for ($i = 0; $i -lt $effAsrIds.Count; $i++) {
            if ("$($effAsrIds[$i])".ToLower() -eq $guid) {
                if ($i -lt $effAsrActions.Count) { $effAction = $effAsrActions[$i] }
                break
            }
        }

        $shortGuid = $guid.Substring(0, 8)

        if ($null -ne $gpoAction -and $null -ne $effAction) {
            $gpoActInt = [int]$gpoAction
            $effActInt = [int]$effAction
            $gpoName = if ($asrActionNames.ContainsKey($gpoActInt)) { $asrActionNames[$gpoActInt] } else { "$gpoActInt" }
            $effName = if ($asrActionNames.ContainsKey($effActInt)) { $asrActionNames[$effActInt] } else { "$effActInt" }
            if ($gpoActInt -ne $effActInt) {
                Write-Output "[!]   ASR $shortGuid -- GPO=$gpoName, Effective=$effName"
                Write-Output "       GPO action differs from effective. Possible MDM/local override."
                $asrConflicts++
                $warnCount++
            }
        } elseif ($null -ne $gpoAction) {
            $gpoActInt = [int]$gpoAction
            $gpoName = if ($asrActionNames.ContainsKey($gpoActInt)) { $asrActionNames[$gpoActInt] } else { "$gpoActInt" }
            Write-Output "[i]   ASR $shortGuid -- GPO=$gpoName, Effective=Not in list"
        }
    }

    if ($asrConflicts -eq 0) {
        $gpoAsrCount = $gpoAsrRules.Count
        Write-Output "[OK]  ASR Rules: $($allGuids.Count) rule(s), GPO defines $gpoAsrCount."
        Write-Output '       No GPO vs effective action conflicts detected.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: ForceDefenderPassiveMode
# ---------------------------------------------------------------
Write-Output '--- ForceDefenderPassiveMode ---'

$atpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
$forcePassive = Get-RegVal -Path $atpPath -Name 'ForceDefenderPassiveMode'

if ($null -ne $forcePassive -and $forcePassive -eq 1) {
    # Check if third-party AV is registered
    $thirdPartyAV = $false
    try {
        $avProducts = @(Get-CimInstance -Namespace 'ROOT\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop)
        foreach ($av in $avProducts) {
            $state = $av.productState
            $origin = ($state -band 0x0F00)
            if ($origin -ne 0x0100) {
                $thirdPartyAV = $true
                break
            }
        }
    } catch {
        # SecurityCenter2 unavailable (Server) - check AMRunningMode instead
        if ($null -ne $mpStatus) {
            $mode = "$($mpStatus.AMRunningMode)"
            if ($mode -eq 'Passive Mode') {
                # On Server, passive + ForcePassive=1 could be intentional
                Write-Output '[!]   ForceDefenderPassiveMode = 1'
                Write-Output "       Defender is in Passive Mode. SecurityCenter2 unavailable (Server?)."
                Write-Output '       Cannot verify third-party AV presence. Confirm a third-party AV is active.'
                Write-Output '       If no other AV is installed, remove this key to restore active protection.'
                $warnCount++
                $forcePassive = $null  # skip further processing
            }
        }
    }

    if ($null -ne $forcePassive) {
        if ($thirdPartyAV) {
            Write-Output '[i]   ForceDefenderPassiveMode = 1'
            Write-Output '       Third-party AV is registered. Passive mode is expected.'
        } else {
            Write-Output '[!!]  ForceDefenderPassiveMode = 1 -- NO THIRD-PARTY AV DETECTED'
            Write-Output '       Defender is FORCED into passive mode but no third-party AV is registered.'
            Write-Output '       This machine may have NO active real-time protection.'
            Write-Output '       Remove the ForceDefenderPassiveMode key or install a third-party AV.'
            $issueCount++
        }
    }
} elseif ($null -ne $forcePassive -and $forcePassive -eq 0) {
    Write-Output '[OK]  ForceDefenderPassiveMode = 0'
    Write-Output '       Explicitly set to active mode. Defender will run in Normal mode.'
} else {
    Write-Output '[OK]  ForceDefenderPassiveMode'
    Write-Output '       Not set. Defender mode determined by Security Center (default behavior).'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: MDMWinsOverGP Assessment
# ---------------------------------------------------------------
Write-Output '--- MDMWinsOverGP Assessment ---'

$mdmWinsPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'
$mdmWinsVal = Get-RegVal -Path $mdmWinsPath -Name 'MDMWinsOverGP'

# Check if any GPO Defender settings exist
$gpoDefenderExists = $false
if (Test-Path -Path $gpoBase) {
    try {
        $gpoItem = Get-Item -Path $gpoBase -ErrorAction Stop
        if ($null -ne $gpoItem.Property -and @($gpoItem.Property).Count -gt 0) {
            $gpoDefenderExists = $true
        }
        # Also check subkeys
        $subKeys = @(Get-ChildItem -Path $gpoBase -ErrorAction Stop)
        if ($subKeys.Count -gt 0) { $gpoDefenderExists = $true }
    } catch { }
}

if ($null -ne $mdmWinsVal -and $mdmWinsVal -eq 1) {
    if ($gpoDefenderExists) {
        Write-Output '[!!]  MDMWinsOverGP = 1 -- FALSE SENSE OF SECURITY'
        Write-Output '       MDMWinsOverGP is enabled, but this setting does NOT apply to'
        Write-Output '       Defender CSP settings. It only applies to Policy CSP settings.'
        Write-Output '       GPO Defender settings still take precedence over Intune/MDM.'
        Write-Output '       Conflicting GPO Defender settings (above) are NOT overridden.'
        Write-Output '       Remove the conflicting GPO settings manually to let Intune apply.'
        $issueCount++
    } else {
        Write-Output '[i]   MDMWinsOverGP = 1'
        Write-Output '       Enabled, but no GPO Defender settings detected.'
        Write-Output '       No Defender policy conflicts to worry about.'
    }
} else {
    Write-Output '[OK]  MDMWinsOverGP'
    Write-Output '       Not set or = 0. GPO takes precedence over MDM (default behavior).'
    if ($gpoDefenderExists) {
        Write-Output '       GPO Defender settings exist. They override any Intune/MDM Defender policies.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No policy conflicts detected. GPO, MDM, and local settings are consistent.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount conflict(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount conflict(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If GPO conflicts found      -> remove conflicting GPO or migrate settings to Intune'
Write-Output '        If ForcePassiveMode set      -> remove if no third-party AV is present'
Write-Output '        If MDMWinsOverGP misleading  -> remove conflicting Defender GPO settings manually'
Write-Output '        If exclusion merge conflict  -> review DisableLocalAdminMerge setting'
Write-Output '        If no conflicts              -> run DEF006 DEFPlatformVersion to check platform health'
Write-Output ''
