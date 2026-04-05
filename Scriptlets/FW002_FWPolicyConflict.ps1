# FW002_FWPolicyConflict.ps1
# Scriptlet: FW002 - Firewall Policy Source & Conflict Detection
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Firewall Policy Source & Conflict Detection ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Registry path definitions
# ---------------------------------------------------------------
$localBase = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
$gpoBase   = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall'
$mdmBase   = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Firewall'
$mdmConflictPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'

# Profile mapping: DisplayName => LocalSubkey, GpoSubkey, MdmValueSuffix
$profileMap = @(
    @{ Display = 'Domain';  LocalKey = 'DomainProfile';   GpoKey = 'DomainProfile';  MdmSuffix = 'Domain' }
    @{ Display = 'Private'; LocalKey = 'StandardProfile';  GpoKey = 'PrivateProfile'; MdmSuffix = 'Private' }
    @{ Display = 'Public';  LocalKey = 'PublicProfile';    GpoKey = 'PublicProfile';  MdmSuffix = 'Public' }
)

# ---------------------------------------------------------------
# Helper: Read EnableFirewall from a registry path
# Returns: 1 (enabled), 0 (disabled), or $null (not configured)
# ---------------------------------------------------------------
function Get-EnableFirewall {
    param([string]$Path, [string]$ValueName)
    $val = $null
    try {
        $regObj = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($null -ne $regObj -and ($regObj.PSObject.Properties.Name -contains $ValueName)) {
            $val = [int]$regObj.$ValueName
        }
    } catch { }
    return $val
}

# ---------------------------------------------------------------
# Pre-read: MDMWinsOverGP (needed for conflict explanation)
# ---------------------------------------------------------------
$mdmWinsValue = $null
$mdmWinsProviderSet = $null
$mdmWinsWinningProvider = $null
$mdmWinsActive = $false

try {
    $conflictReg = Get-ItemProperty -Path $mdmConflictPath -ErrorAction Stop
    if ($null -ne $conflictReg) {
        if ($conflictReg.PSObject.Properties.Name -contains 'MDMWinsOverGP') {
            $mdmWinsValue = [int]$conflictReg.MDMWinsOverGP
        }
        if ($conflictReg.PSObject.Properties.Name -contains 'MDMWinsOverGP_ProviderSet') {
            $mdmWinsProviderSet = $conflictReg.MDMWinsOverGP_ProviderSet
        }
        if ($conflictReg.PSObject.Properties.Name -contains 'MDMWinsOverGP_WinningProvider') {
            $mdmWinsWinningProvider = $conflictReg.MDMWinsOverGP_WinningProvider
        }
    }
} catch { }

if ($mdmWinsValue -eq 1 -and $null -ne $mdmWinsProviderSet -and $null -ne $mdmWinsWinningProvider) {
    $mdmWinsActive = $true
}

# ---------------------------------------------------------------
# Pre-read: Domain join status (needed for orphaned GPO check)
# ---------------------------------------------------------------
$isDomainJoined = $false
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($null -ne $cs -and $cs.PartOfDomain -eq $true) {
        $isDomainJoined = $true
    }
} catch { }

# ---------------------------------------------------------------
# Collect all EnableFirewall=0 findings for summary (Check 2)
# ---------------------------------------------------------------
$disabledFindings = [System.Collections.Generic.List[string]]::new()

# Track whether any GPO keys exist (for Check 4)
$gpoKeysExist = $false

# ---------------------------------------------------------------
# Check 1: Side-by-Side Policy Comparison (per profile)
# ---------------------------------------------------------------
foreach ($profile in $profileMap) {
    $dispName = $profile.Display
    Write-Output "--- $dispName Profile: Policy Sources ---"

    # Read from each source
    $localPath = Join-Path $localBase $profile.LocalKey
    $localVal  = Get-EnableFirewall -Path $localPath -ValueName 'EnableFirewall'

    $gpoPath = Join-Path $gpoBase $profile.GpoKey
    $gpoVal  = Get-EnableFirewall -Path $gpoPath -ValueName 'EnableFirewall'

    # Check if GPO subkey exists at all
    if (Test-Path $gpoPath) {
        $gpoKeysExist = $true
    }

    # MDM uses flat value names: EnableFirewall_Domain, EnableFirewall_Private, EnableFirewall_Public
    $mdmValName = "EnableFirewall_$($profile.MdmSuffix)"
    $mdmVal = $null
    try {
        $mdmReg = Get-ItemProperty -Path $mdmBase -ErrorAction Stop
        if ($null -ne $mdmReg -and ($mdmReg.PSObject.Properties.Name -contains $mdmValName)) {
            $mdmVal = [int]$mdmReg.$mdmValName
        }
    } catch { }

    # Format display strings
    $localStr = if ($null -eq $localVal) { 'Not configured (default: Enabled)' }
                elseif ($localVal -eq 1)  { '1 (Enabled)' }
                elseif ($localVal -eq 0)  { '0 (DISABLED)' }
                else { "$localVal (Unknown)" }

    $gpoStr = if ($null -eq $gpoVal)  { 'Not configured' }
              elseif ($gpoVal -eq 1)   { '1 (Enabled)' }
              elseif ($gpoVal -eq 0)   { '0 (DISABLED)' }
              else { "$gpoVal (Unknown)" }

    $mdmStr = if ($null -eq $mdmVal)  { 'Not configured' }
              elseif ($mdmVal -eq 1)   { '1 (Enabled)' }
              elseif ($mdmVal -eq 0)   { '0 (DISABLED)' }
              else { "$mdmVal (Unknown)" }

    # Collect EnableFirewall=0 findings for Check 2
    if ($localVal -eq 0) {
        $null = $disabledFindings.Add("Local disables $dispName Profile ($localPath\EnableFirewall = 0)")
    }
    if ($gpoVal -eq 0) {
        $null = $disabledFindings.Add("GPO disables $dispName Profile ($gpoPath\EnableFirewall = 0)")
    }
    if ($mdmVal -eq 0) {
        $null = $disabledFindings.Add("MDM disables $dispName Profile ($mdmBase\$mdmValName = 0)")
    }

    # Determine conflict status
    $hasConflict = $false
    $allDisabled = $false

    # Normalize: treat null as "enabled" (default) for conflict detection
    $effectiveLocal = if ($null -eq $localVal) { 1 } else { $localVal }
    $effectiveGpo   = if ($null -eq $gpoVal)   { -1 } else { $gpoVal }  # -1 = not configured (no opinion)
    $effectiveMdm   = if ($null -eq $mdmVal)   { -1 } else { $mdmVal }

    # Conflict: sources that have an opinion disagree
    $opinions = [System.Collections.Generic.List[int]]::new()
    $null = $opinions.Add($effectiveLocal)
    if ($effectiveGpo -ne -1) { $null = $opinions.Add($effectiveGpo) }
    if ($effectiveMdm -ne -1) { $null = $opinions.Add($effectiveMdm) }

    $uniqueOpinions = @($opinions | Sort-Object -Unique)
    if ($uniqueOpinions.Count -gt 1) {
        $hasConflict = $true
    }

    # Check if all sources that have an opinion say disabled
    $allDisabled = ($uniqueOpinions.Count -eq 1 -and $uniqueOpinions[0] -eq 0)

    if ($hasConflict) {
        Write-Output "[!!]  $dispName Profile -- Policy CONFLICT"
        Write-Output "       Local:  EnableFirewall = $localStr"
        Write-Output "       GPO:    EnableFirewall = $gpoStr"
        Write-Output "       MDM:    EnableFirewall = $mdmStr"

        # Specific scenario: GPO disables, MDM enables, MDMWinsOverGP not active
        if ($gpoVal -eq 0 -and ($mdmVal -eq 1 -or $effectiveMdm -eq -1)) {
            Write-Output ''
            Write-Output '       ROOT CAUSE: GPO is explicitly disabling this profile.'
            if (-not $mdmWinsActive) {
                Write-Output '       MDMWinsOverGP is NOT set to 1, so GPO takes precedence over MDM.'
                Write-Output '       RESULT: The firewall stays DISABLED despite Intune wanting it enabled.'
                Write-Output '       Intune reports non-compliant, but the GPO silently overrides the MDM policy.'
                Write-Output '       FIX: Set MDMWinsOverGP=1 via Intune policy, or remove the GPO.'
            } else {
                Write-Output '       MDMWinsOverGP IS active, so MDM should override this GPO setting.'
                Write-Output '       If the profile is still disabled, a reboot may be needed.'
            }
        } elseif ($gpoVal -eq 0 -and $mdmVal -eq 0) {
            Write-Output '       Both GPO and MDM are disabling this profile. This appears intentional.'
        } elseif ($localVal -eq 0) {
            Write-Output '       The local configuration is disabling this profile.'
            Write-Output '       A local change or script may have set EnableFirewall to 0.'
        }
        $issueCount++
    } elseif ($allDisabled) {
        Write-Output "[!!]  $dispName Profile -- All Sources Say DISABLED"
        Write-Output "       Local:  EnableFirewall = $localStr"
        Write-Output "       GPO:    EnableFirewall = $gpoStr"
        Write-Output "       MDM:    EnableFirewall = $mdmStr"
        Write-Output '       All configured sources agree: firewall is disabled for this profile.'
        Write-Output '       This appears to be an intentional configuration.'
        $issueCount++
    } else {
        Write-Output "[OK]  $dispName Profile -- No Conflict"
        Write-Output "       Local:  EnableFirewall = $localStr"
        Write-Output "       GPO:    EnableFirewall = $gpoStr"
        Write-Output "       MDM:    EnableFirewall = $mdmStr"
    }
    Write-Output ''
}

# ---------------------------------------------------------------
# Check 2: EnableFirewall=0 Summary
# ---------------------------------------------------------------
Write-Output '--- EnableFirewall=0 Summary ---'

if ($disabledFindings.Count -eq 0) {
    Write-Output '[OK]  No EnableFirewall=0 Found'
    Write-Output '       No source is explicitly disabling any firewall profile.'
} else {
    foreach ($finding in $disabledFindings) {
        Write-Output "[!!]  $finding"

        # Special callout for GPO Domain profile disable
        if ($finding -like '*GPO disables Domain*') {
            Write-Output '       Legacy GPO artifact detected. This GPO disables the firewall when the machine'
            Write-Output '       connects to the corporate network. This was common practice over a decade ago'
            Write-Output '       but is incompatible with modern Zero Trust security models.'
            if (-not $isDomainJoined) {
                Write-Output '       This machine is NOT domain-joined. The GPO key is a tattooed remnant.'
            }
        }
        # No separate $issueCount++ here -- already counted in Check 1 conflict detection
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: MDMWinsOverGP Conflict Resolution
# ---------------------------------------------------------------
Write-Output '--- MDMWinsOverGP ---'

if ($mdmWinsValue -eq 1) {
    if ($mdmWinsActive) {
        Write-Output '[OK]  MDMWinsOverGP = 1 (Active)'
        Write-Output '       MDM policy takes precedence over GPO. Confirmation keys present.'
        Write-Output '       GPO firewall settings are silently ignored by the Group Policy Client.'
    } else {
        Write-Output '[!]   MDMWinsOverGP = 1 (Not Yet Confirmed)'
        Write-Output '       MDMWinsOverGP is set to 1, but the OS confirmation keys are missing.'
        Write-Output '       MDMWinsOverGP_ProviderSet and MDMWinsOverGP_WinningProvider not found.'
        Write-Output '       The setting may not be active yet. A reboot is likely required.'
        $warnCount++
    }
} elseif ($mdmWinsValue -eq 0) {
    if ($gpoKeysExist) {
        Write-Output '[!]   MDMWinsOverGP = 0 (GPO Wins)'
        Write-Output '       MDMWinsOverGP is explicitly set to 0. GPO settings take precedence over MDM.'
        Write-Output '       If Intune should control the firewall, set MDMWinsOverGP=1 via Intune policy.'
        $warnCount++
    } else {
        Write-Output '[i]   MDMWinsOverGP = 0'
        Write-Output '       No GPO firewall settings detected, so this has no practical effect.'
    }
} else {
    # null / not configured
    if ($gpoKeysExist) {
        Write-Output '[!]   MDMWinsOverGP Not Configured (GPO Wins by Default)'
        Write-Output '       MDMWinsOverGP is not set. In hybrid environments, GPO takes precedence by default.'
        Write-Output '       GPO firewall registry keys ARE present on this machine.'
        Write-Output '       If Intune should control the firewall, deploy MDMWinsOverGP=1 via Intune.'
        $warnCount++
    } else {
        Write-Output '[i]   MDMWinsOverGP Not Configured'
        Write-Output '       No GPO firewall settings detected. No conflict to resolve.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Orphaned GPO Detection
# ---------------------------------------------------------------
Write-Output '--- Orphaned GPO Check ---'

if ($gpoKeysExist) {
    if ($isDomainJoined) {
        Write-Output '[i]   GPO Firewall Keys Present (Domain-Joined)'
        Write-Output '       GPO firewall settings found at:'
        Write-Output "       $gpoBase"
        Write-Output '       Machine is domain-joined, so these keys are expected.'
        Write-Output '       Verify the GPO settings are intentional with the GPO owner.'
    } else {
        Write-Output '[!!]  ORPHANED GPO Detected'
        Write-Output '       Machine is NOT domain-joined, but GPO firewall registry keys are present at:'
        Write-Output "       $gpoBase"
        Write-Output '       These are tattooed remnants from a previous domain membership.'
        Write-Output '       They will continue to override local settings and MDM policy.'
        Write-Output '       Options:'
        Write-Output '         1. Remove the GPO registry keys manually (delete the subkeys under the path above)'
        Write-Output '         2. Set MDMWinsOverGP=1 via Intune to force MDM precedence'
        Write-Output '       WARNING: Do NOT remove GPO keys if the machine is being re-joined to a domain.'
        $issueCount++
    }
} else {
    Write-Output '[OK]  No GPO Firewall Keys'
    Write-Output '       No GPO firewall settings detected in the registry.'
    Write-Output '       No risk of GPO-vs-MDM conflict for firewall profiles.'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. No firewall policy conflicts found.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review the flagged items."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Policy conflicts need attention."
}

Write-Output ''
Write-Output 'NEXT:   If GPO is intentionally disabling firewall -> escalate to GPO owner, do NOT override'
Write-Output '        If stale GPO -> remove the registry keys or set MDMWinsOverGP=1'
Write-Output '        If MDM policy missing -> check Intune policy assignment and force sync'
Write-Output '        If no conflicts -> run FW003 FWThirdParty to check for third-party interference'
