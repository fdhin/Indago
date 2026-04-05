# FW005_FWRuleDiagnostic.ps1
# Scriptlet: FW005 - Rule Corruption & Bloat Diagnostics
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# Check 1 -- Total Rule Count (CIM with registry fallback)
# ============================================================
$totalRuleCount = 0
$countSource = 'CIM'
$cimFailed = $false

try {
    $job = Start-Job -ScriptBlock {
        @(Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetFirewallRule -ErrorAction Stop).Count
    }
    $completed = $job | Wait-Job -Timeout 30
    if ($null -ne $completed -and $completed.State -eq 'Completed') {
        $totalRuleCount = Receive-Job -Job $job
        if ($null -eq $totalRuleCount) { $totalRuleCount = 0; $cimFailed = $true }
    } else {
        $cimFailed = $true
        $job | Stop-Job -ErrorAction SilentlyContinue
    }
    $job | Remove-Job -Force -ErrorAction SilentlyContinue
} catch {
    $cimFailed = $true
}

if ($cimFailed) {
    $countSource = 'Registry (local rules only)'
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
    try {
        $regKey = Get-Item -Path $regPath -ErrorAction Stop
        $totalRuleCount = @($regKey.GetValueNames()).Count
    } catch {
        $totalRuleCount = -1
    }
}

if ($totalRuleCount -lt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Total Rule Count'
        Status = 'ERROR'
        Detail = 'Could not enumerate firewall rules from CIM or registry.'
    })
} elseif ($totalRuleCount -gt 10000) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Total Rule Count'
        Status = 'ISSUE'
        Detail = "$totalRuleCount rules (source: $countSource). EXTREME BLOAT -- likely causing MpsSvc startup delays, Security Center timeout, and Intune non-compliance. Consider a firewall reset via FW006 FWRemediation."
    })
} elseif ($totalRuleCount -gt 3000) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Total Rule Count'
        Status = 'WARN'
        Detail = "$totalRuleCount rules (source: $countSource). Elevated -- manageable but worth investigating. Check for duplicate or orphaned rules below."
    })
} elseif ($totalRuleCount -gt 500) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Total Rule Count'
        Status = 'INFO'
        Detail = "$totalRuleCount rules (source: $countSource). Normal for managed environments."
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Total Rule Count'
        Status = 'OK'
        Detail = "$totalRuleCount rules (source: $countSource). Healthy rule count."
    })
}

# ============================================================
# Parse registry rules once -- reused by Checks 2-6
# ============================================================
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
$parsedRules = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalStoreBytes = 0
$registryParseOK = $false

try {
    $regKey = Get-Item -Path $regPath -ErrorAction Stop
    $valueNames = $regKey.GetValueNames()
    foreach ($vn in $valueNames) {
        $raw = $regKey.GetValue($vn)
        if ($null -eq $raw) { continue }
        $rawStr = [string]$raw
        $totalStoreBytes += ($rawStr.Length * 2)

        $fields = @{}
        $parts = $rawStr -split '\|'
        foreach ($p in $parts) {
            $eqIdx = $p.IndexOf('=')
            if ($eqIdx -gt 0) {
                $k = $p.Substring(0, $eqIdx)
                $v = $p.Substring($eqIdx + 1)
                $fields[$k] = $v
            }
        }

        $ruleName = if ($fields.ContainsKey('Name')) { $fields['Name'] } else { '' }
        $dir = if ($fields.ContainsKey('Dir')) { $fields['Dir'] } else { '' }
        $action = if ($fields.ContainsKey('Action')) { $fields['Action'] } else { '' }
        $app = if ($fields.ContainsKey('App')) { $fields['App'] } else { '' }
        $protocol = if ($fields.ContainsKey('Protocol')) { $fields['Protocol'] } else { '' }
        $lport = if ($fields.ContainsKey('LPort')) { $fields['LPort'] } else { '' }
        $profile = if ($fields.ContainsKey('Profile')) { $fields['Profile'] } else { 'All' }
        $active = if ($fields.ContainsKey('Active')) { $fields['Active'] } else { 'TRUE' }

        $parsedRules.Add([PSCustomObject]@{
            ValueName   = $vn
            RuleName    = $ruleName
            Direction   = $dir
            Action      = $action
            App         = $app
            Protocol    = $protocol
            LocalPort   = $lport
            Profile     = $profile
            Active      = $active.ToUpper()
            Fingerprint = "$ruleName|$dir|$action|$app|$protocol|$lport"
        })
    }
    $registryParseOK = $true
} catch {
    $findings.Add([PSCustomObject]@{
        Check  = 'Registry Parse'
        Status = 'ERROR'
        Detail = "Could not parse firewall rule registry: $($_.Exception.Message)"
    })
}

if ($registryParseOK) {
    $localRuleCount = $parsedRules.Count

    # ============================================================
    # Check 2 -- Rules Per Profile
    # ============================================================
    $domainCount = 0
    $privateCount = 0
    $publicCount = 0
    $allCount = 0

    foreach ($r in $parsedRules) {
        $prof = $r.Profile
        if ($prof -eq 'Domain') { $domainCount++ }
        elseif ($prof -eq 'Private') { $privateCount++ }
        elseif ($prof -eq 'Public') { $publicCount++ }
        else { $allCount++ }
    }

    $profileDetail = "Domain: $domainCount, Private: $privateCount, Public: $publicCount, All: $allCount (of $localRuleCount local)"
    $maxProfile = [Math]::Max($domainCount, [Math]::Max($privateCount, $publicCount))
    $profileThreshold = [Math]::Floor($localRuleCount * 0.7)

    if ($localRuleCount -gt 0 -and $maxProfile -gt 5000) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rules Per Profile'
            Status = 'WARN'
            Detail = "$profileDetail. A single profile has $maxProfile rules -- likely auto-generated application rules."
        })
    } elseif ($localRuleCount -gt 0 -and $maxProfile -gt $profileThreshold -and $maxProfile -gt 200) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rules Per Profile'
            Status = 'WARN'
            Detail = "$profileDetail. One profile has >70% of all rules -- disproportionate concentration."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rules Per Profile'
            Status = 'OK'
            Detail = "$profileDetail. Distribution is balanced."
        })
    }

    # ============================================================
    # Check 3 -- Duplicate Rule Detection
    # ============================================================
    $fingerprintGroups = @{}
    foreach ($r in $parsedRules) {
        $fp = $r.Fingerprint
        if (-not $fingerprintGroups.ContainsKey($fp)) {
            $fingerprintGroups[$fp] = [System.Collections.Generic.List[string]]::new()
        }
        $fingerprintGroups[$fp].Add($r.RuleName)
    }

    $dupGroups = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($key in $fingerprintGroups.Keys) {
        $names = $fingerprintGroups[$key]
        if ($names.Count -gt 1) {
            $dupGroups.Add([PSCustomObject]@{
                Count = $names.Count
                Name  = $names[0]
            })
        }
    }

    $totalDupGroups = $dupGroups.Count
    $totalDupRules = 0
    foreach ($dg in $dupGroups) { $totalDupRules += ($dg.Count - 1) }

    if ($totalDupGroups -eq 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Duplicate Rules'
            Status = 'OK'
            Detail = 'No duplicate rules found. Each rule has a unique fingerprint (Name+Direction+Action+Program+Protocol+Port).'
        })
    } else {
        $sortedDups = $dupGroups | Sort-Object -Property Count -Descending
        $topN = if ($sortedDups.Count -gt 5) { $sortedDups[0..4] } else { $sortedDups }
        $topList = ($topN | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join ', '

        if ($totalDupGroups -gt 500) {
            $dupStatus = 'ISSUE'
            $dupAdvice = 'Extreme duplication -- likely runaway auto-rule generator. Consider reset via FW006.'
        } elseif ($totalDupGroups -gt 50) {
            $dupStatus = 'WARN'
            $dupAdvice = 'Significant bloat from duplicate rules. Clean up via policy tool or targeted removal.'
        } else {
            $dupStatus = 'INFO'
            $dupAdvice = 'Minor duplication, common in managed environments.'
        }

        $findings.Add([PSCustomObject]@{
            Check  = 'Duplicate Rules'
            Status = $dupStatus
            Detail = "$totalDupGroups duplicate groups, $totalDupRules redundant rules. Top: $topList. $dupAdvice"
        })
    }

    # ============================================================
    # Check 4 -- Invalid Application Paths
    # ============================================================
    $orphanedCount = 0
    $orphanedExamples = [System.Collections.Generic.List[string]]::new()
    $rulesWithApp = @($parsedRules | Where-Object { $_.App -ne '' -and $_.App -ne '*' })

    $userProfiles = [System.Collections.Generic.List[string]]::new()
    try {
        $userDirs = Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction Stop |
            Where-Object { $_.Name -ne 'Public' -and $_.Name -ne 'Default' -and $_.Name -ne 'Default User' -and $_.Name -ne 'All Users' }
        foreach ($ud in $userDirs) { $userProfiles.Add($ud.FullName) }
    } catch { }

    foreach ($r in $rulesWithApp) {
        $appPath = $r.App
        $exists = $false

        if ($appPath -match '%LocalAppData%' -or $appPath -match '%APPDATA%' -or $appPath -match '%USERPROFILE%') {
            foreach ($up in $userProfiles) {
                $expanded = $appPath
                $expanded = $expanded -replace '%LocalAppData%', (Join-Path $up 'AppData\Local')
                $expanded = $expanded -replace '%APPDATA%', (Join-Path $up 'AppData\Roaming')
                $expanded = $expanded -replace '%USERPROFILE%', $up
                if (Test-Path -Path $expanded -PathType Leaf) { $exists = $true; break }
            }
        } elseif ($appPath -match '^C:\\Users\\([^\\]+)\\') {
            if (Test-Path -Path $appPath -PathType Leaf) {
                $exists = $true
            } else {
                foreach ($up in $userProfiles) {
                    $rebuilt = $appPath -replace '^C:\\Users\\[^\\]+', $up
                    if (Test-Path -Path $rebuilt -PathType Leaf) { $exists = $true; break }
                }
            }
        } else {
            $expanded = [Environment]::ExpandEnvironmentVariables($appPath)
            if (Test-Path -Path $expanded -PathType Leaf) { $exists = $true }
        }

        if (-not $exists) {
            $orphanedCount++
            if ($orphanedExamples.Count -lt 5) {
                $dp = if ($appPath.Length -gt 80) { $appPath.Substring(0, 77) + '...' } else { $appPath }
                $orphanedExamples.Add($dp)
            }
        }
    }

    $appRuleTotal = $rulesWithApp.Count
    if ($orphanedCount -eq 0) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Orphaned Application Paths'
            Status = 'OK'
            Detail = "All $appRuleTotal rules with application paths point to valid executables."
        })
    } else {
        $pct = if ($appRuleTotal -gt 0) { [Math]::Round(($orphanedCount / $appRuleTotal) * 100, 1) } else { 0 }
        $exLines = ''
        foreach ($ex in $orphanedExamples) { $exLines += "`n       - $ex" }

        if ($orphanedCount -gt 500) {
            $orphStatus = 'ISSUE'
            $orphAdvice = 'Major cause of MpsSvc startup delay. These cause parsing errors on every boot.'
        } elseif ($orphanedCount -gt 50) {
            $orphStatus = 'WARN'
            $orphAdvice = 'Significant bloat from stale rules. Consider cleanup.'
        } else {
            $orphStatus = 'INFO'
            $orphAdvice = 'Minor orphan count, routine cleanup recommended.'
        }

        $findings.Add([PSCustomObject]@{
            Check  = 'Orphaned Application Paths'
            Status = $orphStatus
            Detail = "$orphanedCount of $appRuleTotal rules point to missing executables ($pct%). $orphAdvice$exLines"
        })
    }

    # ============================================================
    # Check 5 -- Firewall Rule Store Size
    # ============================================================
    $storeMB = [Math]::Round($totalStoreBytes / 1MB, 2)

    if ($storeMB -gt 10) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rule Store Size'
            Status = 'ISSUE'
            Detail = "$storeMB MB. Approaching MpsSvc payload limit (~14 MB). Service may fail to compile rules into WFP. Reset via FW006."
        })
    } elseif ($storeMB -gt 5) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rule Store Size'
            Status = 'WARN'
            Detail = "$storeMB MB. Large rule store -- may cause startup delays."
        })
    } elseif ($storeMB -gt 2) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rule Store Size'
            Status = 'INFO'
            Detail = "$storeMB MB. Growing. Monitor for further bloat."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Rule Store Size'
            Status = 'OK'
            Detail = "$storeMB MB. Rule store size is healthy."
        })
    }

    # ============================================================
    # Check 6 -- Enabled vs Disabled Ratio
    # ============================================================
    $enabledCount = @($parsedRules | Where-Object { $_.Active -eq 'TRUE' }).Count
    $disabledCount = $localRuleCount - $enabledCount

    if ($enabledCount -gt 5000) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Enabled vs Disabled Rules'
            Status = 'ISSUE'
            Detail = "$enabledCount enabled, $disabledCount disabled (of $localRuleCount local). Extreme -- every enabled rule is evaluated per-packet."
        })
    } elseif ($enabledCount -gt 2000) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Enabled vs Disabled Rules'
            Status = 'WARN'
            Detail = "$enabledCount enabled, $disabledCount disabled (of $localRuleCount local). Heavy enabled count may slow per-packet evaluation."
        })
    } elseif ($enabledCount -gt 500) {
        $findings.Add([PSCustomObject]@{
            Check  = 'Enabled vs Disabled Rules'
            Status = 'INFO'
            Detail = "$enabledCount enabled, $disabledCount disabled (of $localRuleCount local). Normal for managed environments."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Enabled vs Disabled Rules'
            Status = 'OK'
            Detail = "$enabledCount enabled, $disabledCount disabled (of $localRuleCount local). Healthy."
        })
    }
}

# ============================================================
# Check 7 -- Event ID 4953 (Rule Corruption, 7-day window)
# ============================================================
$corruptionEvents = @()
try {
    $startTime = (Get-Date).AddDays(-7)
    $corruptionEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4953
        StartTime = $startTime
    } -ErrorAction Stop)
} catch { }

if ($corruptionEvents.Count -gt 0) {
    $lastEvent = $corruptionEvents[0]
    $lastTime = $lastEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $msg = ''
    try {
        $rawMsg = $lastEvent.Message
        if ($null -ne $rawMsg -and $rawMsg.Length -gt 0) {
            $cleanMsg = $rawMsg -replace '[\r\n]+', ' '
            $msg = if ($cleanMsg.Length -gt 120) { $cleanMsg.Substring(0, 117) + '...' } else { $cleanMsg }
        }
    } catch { }

    $findings.Add([PSCustomObject]@{
        Check  = 'Rule Corruption Events (4953)'
        Status = 'ISSUE'
        Detail = "$($corruptionEvents.Count) events in last 7 days. A rule was ignored because it could not be parsed. Last: $lastTime. $msg"
    })
} else {
    $findings.Add([PSCustomObject]@{
        Check  = 'Rule Corruption Events (4953)'
        Status = 'OK'
        Detail = 'No Event 4953 (unparseable rule) in last 7 days. No rule corruption detected.'
    })
}

# ============================================================
# Output
# ============================================================
Write-Output ''
Write-Output '=== Rule Corruption & Bloat Diagnostics ==='
Write-Output ''

$issueCount = @($findings | Where-Object { $_.Status -eq 'ISSUE' -or $_.Status -eq 'ERROR' }).Count
$warnCount = @($findings | Where-Object { $_.Status -eq 'WARN' }).Count

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
    $detailLines = $f.Detail -split "`n"
    foreach ($dl in $detailLines) {
        Write-Output "       $dl"
    }
}

Write-Output ''
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No rule bloat or corruption issues detected.'
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If rule count extreme        -> consider a firewall reset via FW006 FWRemediation'
Write-Output '        If many duplicates           -> clean up via policy management tool or reset'
Write-Output '        If orphaned paths            -> remove stale rules manually or via script'
Write-Output '        If Event 4953 detected       -> identify the malformed rule from event detail'
Write-Output '        If all clean                 -> the issue is likely policy or service-level (FW001-FW004)'
Write-Output ''
