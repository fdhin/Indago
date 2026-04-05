# FW001_FWStatusTriage.ps1
# Scriptlet: FW001 - Firewall Status Triage
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Firewall Status Triage ==='
Write-Output ''

$issueCount = 0
$warnCount = 0

# State tracking for cross-reference (Check 2)
$anyProfileDisabled = $false
$allProfilesEnabled = $true
$profileStates = @{}

# --- Check 1: Firewall Profile Status ---
# Get active network connections for correlation
$connections = @()
try {
    $connections = @(Get-NetConnectionProfile -ErrorAction Stop)
} catch { }

# Build a lookup: which profiles have active adapters
$activeProfileAdapters = @{}
$activeProfileAdapters['Domain'] = [System.Collections.Generic.List[string]]::new()
$activeProfileAdapters['Private'] = [System.Collections.Generic.List[string]]::new()
$activeProfileAdapters['Public'] = [System.Collections.Generic.List[string]]::new()

foreach ($conn in $connections) {
    $cat = $conn.NetworkCategory.ToString()
    $alias = $conn.InterfaceAlias
    if ($cat -eq 'DomainAuthenticated') {
        $null = $activeProfileAdapters['Domain'].Add($alias)
    } elseif ($cat -eq 'Private') {
        $null = $activeProfileAdapters['Private'].Add($alias)
    } elseif ($cat -eq 'Public') {
        $null = $activeProfileAdapters['Public'].Add($alias)
    }
}

try {
    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    foreach ($p in $profiles) {
        $pName = $p.Name
        $enabled = $p.Enabled
        $inAction = $p.DefaultInboundAction.ToString()
        $outAction = $p.DefaultOutboundAction.ToString()

        $profileStates[$pName] = $enabled

        if (-not $enabled) {
            $anyProfileDisabled = $true
            $allProfilesEnabled = $false
        }

        $adapters = $activeProfileAdapters[$pName]
        $hasAdapters = ($null -ne $adapters -and $adapters.Count -gt 0)
        $adapterStr = if ($hasAdapters) { $adapters -join ', ' } else { 'None' }

        if ($enabled -and $hasAdapters) {
            Write-Output "[OK]  $pName Profile"
            Write-Output "       Enabled. Active on: $adapterStr."
        } elseif ($enabled -and -not $hasAdapters) {
            Write-Output "[OK]  $pName Profile"
            Write-Output "       Enabled. No adapters currently using this profile."
        } elseif (-not $enabled -and $hasAdapters) {
            Write-Output "[!!]  $pName Profile"
            Write-Output "       DISABLED -- but adapter(s) are connected: $adapterStr."
            Write-Output "       Traffic on these adapters is UNFILTERED."
            Write-Output "       Run FW002 FWPolicyConflict to find what disabled it."
            $issueCount++
        } else {
            # Disabled, no active adapters
            Write-Output "[!]   $pName Profile"
            Write-Output "       Disabled. No adapters currently using this profile."
            Write-Output "       Risk: if an adapter connects to a $pName network, traffic will be unfiltered."
            $warnCount++
        }

        # Flag non-standard default actions (only deviations)
        if ($inAction -eq 'Allow') {
            Write-Output "[!]   $pName Profile -- Inbound Default Action"
            Write-Output "       DefaultInboundAction is ALLOW. All inbound traffic is permitted unless explicitly blocked."
            Write-Output "       The expected setting is Block. This is a significant security risk."
            $warnCount++
        }
        if ($outAction -eq 'Block') {
            Write-Output "[i]   $pName Profile -- Outbound Default Action"
            Write-Output "       DefaultOutboundAction is BLOCK. All outbound traffic is denied unless explicitly allowed."
            Write-Output "       This is a restrictive configuration. Expected default is Allow."
        }
    }
} catch {
    Write-Output '[!!]  Firewall Profiles'
    Write-Output "       Could not query firewall profiles: $($_.Exception.Message)"
    Write-Output '       The NetSecurity module may not be available.'
    $issueCount++
}

# --- Check 2: Security Center Cross-Reference ---
$secCenterFirewallOn = $false
$hasThirdPartyFW = $false

try {
    $fwProducts = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop)
    if ($null -eq $fwProducts -or $fwProducts.Count -eq 0) {
        Write-Output '[i]   Security Center Firewall Products'
        Write-Output '       No firewall products registered in Security Center.'
        Write-Output '       Intune may report firewall as non-compliant due to missing registration.'
    } else {
        $nativeGuid = '{D68DDC3A-831F-4fae-9E44-DA132C1ACF46}'

        foreach ($fw in $fwProducts) {
            $pState = [UInt32]$fw.productState
            $engineBits = $pState -band 0xF000

            $engineState = switch ($engineBits) {
                0x1000 { 'On' }
                0x0000 { 'Off' }
                0x2000 { 'Snoozed' }
                0x3000 { 'Expired' }
                default { "Unknown (0x$($engineBits.ToString('X4')))" }
            }

            $isNative = ($fw.instanceGuid -eq $nativeGuid)

            if ($isNative) {
                if ($engineState -eq 'On') {
                    $secCenterFirewallOn = $true
                    Write-Output "[OK]  Security Center: $($fw.displayName)"
                    Write-Output "       State: $engineState. Native Windows Firewall registered and active."
                } else {
                    Write-Output "[!!]  Security Center: $($fw.displayName)"
                    Write-Output "       State: $engineState. Native Windows Firewall registered but reporting as $engineState."
                    Write-Output "       Intune will see the firewall as non-compliant."
                    $issueCount++
                }
            } else {
                $hasThirdPartyFW = $true
                # Ghost detection: check if executable exists
                $isGhost = $false
                $exePath = $fw.pathToSignedReportingExe
                if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                    if ($exePath -notlike 'windowsdefender://*' -and $exePath -notlike '%*') {
                        if (-not (Test-Path $exePath)) {
                            $isGhost = $true
                        }
                    }
                }

                if ($isGhost) {
                    Write-Output "[!!]  Security Center: $($fw.displayName)"
                    Write-Output "       GHOST REGISTRATION -- product registered but executable not found on disk."
                    Write-Output "       Path: $exePath"
                    Write-Output "       Intune reads this stale entry and may report firewall non-compliant."
                    Write-Output "       Run FW003 FWThirdParty to investigate and FW006 FWRemediation to clean up."
                    $issueCount++
                } elseif ($engineState -eq 'On') {
                    $secCenterFirewallOn = $true
                    Write-Output "[i]   Security Center: $($fw.displayName)"
                    Write-Output "       State: $engineState. Third-party firewall is active."
                    Write-Output "       Windows Firewall may be correctly deferred to this product."
                } else {
                    Write-Output "[!!]  Security Center: $($fw.displayName)"
                    Write-Output "       State: $engineState. Third-party firewall registered but not active."
                    Write-Output "       If this product was uninstalled, this is a ghost registration."
                    Write-Output "       Run FW003 FWThirdParty to investigate."
                    $issueCount++
                }
            }
        }

        # Multiple products warning
        if ($fwProducts.Count -gt 1) {
            Write-Output "[!]   Security Center Product Count"
            Write-Output "       $($fwProducts.Count) firewall products registered. Ghost registration is probable."
            Write-Output "       Run FW003 FWThirdParty for detailed analysis."
            $warnCount++
        }

        # Cross-reference: Security Center vs profile ground truth
        if ($secCenterFirewallOn -and $anyProfileDisabled) {
            Write-Output '[!!]  Security Center vs Profile Desync'
            Write-Output '       Security Center reports firewall ON, but one or more profiles are DISABLED.'
            Write-Output '       Intune sees the firewall as compliant, but traffic may be unfiltered.'
            Write-Output '       This is a false sense of security.'
            $issueCount++
        } elseif (-not $secCenterFirewallOn -and $allProfilesEnabled -and -not $hasThirdPartyFW) {
            Write-Output '[!!]  Security Center vs Profile Desync'
            Write-Output '       All firewall profiles are ENABLED, but Security Center reports firewall OFF.'
            Write-Output '       Intune will incorrectly flag this machine as non-compliant.'
            Write-Output '       Run FW003 FWThirdParty to check for ghost registrations.'
            $issueCount++
        }
    }
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -like '*Invalid namespace*' -or $errMsg -like '*not found*') {
        Write-Output '[i]   Security Center Firewall Products'
        Write-Output '       SecurityCenter2 namespace not available (normal on Windows Server).'
        Write-Output '       Skipping Security Center cross-reference.'
    } else {
        Write-Output '[i]   Security Center Firewall Products'
        Write-Output "       Could not query Security Center: $errMsg"
    }
}

# --- Check 3: MpsSvc Service Health ---
$mpssvc = Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue
if ($null -eq $mpssvc) {
    Write-Output '[!!]  Firewall Service (MpsSvc)'
    Write-Output '       Service not found. This is a critical system component that should always exist.'
    $issueCount++
} else {
    $mpsStatus = $mpssvc.Status.ToString()
    $mpsStart  = $mpssvc.StartType.ToString()

    if ($mpsStatus -eq 'Running' -and $mpsStart -eq 'Automatic') {
        Write-Output '[OK]  Firewall Service (MpsSvc)'
        Write-Output "       Running, start type: Automatic. Operational."
    } elseif ($mpsStatus -eq 'Running' -and $mpsStart -ne 'Automatic') {
        Write-Output '[!]   Firewall Service (MpsSvc)'
        Write-Output "       Running but start type is $mpsStart (expected: Automatic)."
        Write-Output '       Service is operational now but may not survive a reboot.'
        $warnCount++
    } elseif ($mpsStart -eq 'Disabled') {
        Write-Output '[!!]  Firewall Service (MpsSvc)'
        Write-Output '       DISABLED. The firewall cannot start. All network filtering is inactive.'
        Write-Output '       Run FW006 FWRemediation to re-enable the service.'
        $issueCount++
    } else {
        Write-Output '[!!]  Firewall Service (MpsSvc)'
        Write-Output "       $mpsStatus, start type: $mpsStart. MpsSvc should always be Running."
        Write-Output '       Unlike demand-start services (BITS, BDESVC), MpsSvc must run at all times.'
        Write-Output '       Run FW006 FWRemediation to restart the service.'
        $issueCount++
    }
}

# --- Check 4: Active Network Adapters ---
if ($connections.Count -eq 0) {
    Write-Output '[i]   Active Network Adapters'
    Write-Output '       No active network connections found. Machine may be offline or disconnected.'
} else {
    foreach ($conn in $connections) {
        $netName  = $conn.Name
        $alias    = $conn.InterfaceAlias
        $category = $conn.NetworkCategory.ToString()
        $ipv4     = $conn.IPv4Connectivity.ToString()
        $ipv6     = $conn.IPv6Connectivity.ToString()

        # Map DomainAuthenticated back to readable name
        $catDisplay = $category
        if ($category -eq 'DomainAuthenticated') { $catDisplay = 'Domain' }

        Write-Output "[i]   Network: $netName ($alias)"
        Write-Output "       Profile: $catDisplay. IPv4: $ipv4. IPv6: $ipv6."
    }
}

# --- Summary ---
Write-Output ''
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. Firewall appears healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] and [!] above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}
Write-Output ''
Write-Output 'NEXT:   If firewall disabled by policy    -> run FW002 FWPolicyConflict to find the source'
Write-Output '        If third-party firewall detected   -> run FW003 FWThirdParty for details'
Write-Output '        If MpsSvc stopped/disabled         -> run FW006 FWRemediation to restart'
Write-Output '        If Security Center mismatch        -> run FW003 FWThirdParty (likely ghost registration)'
