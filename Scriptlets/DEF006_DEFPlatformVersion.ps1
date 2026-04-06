# DEF006_DEFPlatformVersion.ps1
# Scriptlet: DEF006 - Defender Platform & Engine Version Check
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Defender Platform & Engine Version Check ==='
Write-Output ''
$issueCount = 0
$warnCount  = 0
function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $Name)) { return $item.$Name }
    } catch { }
    return $null
}
function Compare-VerString {
    param([string]$Current, [string]$Baseline)
    try {
        $cParts = $Current -split '\.'
        $bParts = $Baseline -split '\.'
        $maxLen = [math]::Max($cParts.Count, $bParts.Count)
        for ($i = 0; $i -lt $maxLen; $i++) {
            $cVal = 0; $bVal = 0
            if ($i -lt $cParts.Count) { $cVal = [int]$cParts[$i] }
            if ($i -lt $bParts.Count) { $bVal = [int]$bParts[$i] }
            if ($cVal -gt $bVal) { return 1 }
            if ($cVal -lt $bVal) { return -1 }
        }
        return 0
    } catch { return 0 }
}
$platformWarnBaseline = '4.18.26010.0'
$platformCritBaseline = '4.18.25100.0'
$engineWarnBaseline   = '1.1.26010.0'
$engineCritBaseline   = '1.1.25100.0'
Write-Output '--- Component Versions ---'
$mpStatus = $null; $statusOK = $false
try { $mpStatus = Get-MpComputerStatus -ErrorAction Stop; if ($null -ne $mpStatus) { $statusOK = $true } } catch { }
if (-not $statusOK) { try { $mpStatus = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpComputerStatus -ErrorAction Stop; if ($null -ne $mpStatus) { $statusOK = $true } } catch { } }
if (-not $statusOK) {
    Write-Output '[ERR] Cannot Query Defender Status'
    Write-Output '       Get-MpComputerStatus and CIM fallback both failed.'
    Write-Output '       Run DEF001 DEFStatusTriage to check service health first.'
    $issueCount++
} else {
    $platVer = "$($mpStatus.AMProductVersion)"; $engineVer = "$($mpStatus.AMEngineVersion)"; $nisVer = "$($mpStatus.NISEngineVersion)"
    if ([string]::IsNullOrWhiteSpace($platVer) -or $platVer -eq '0.0.0.0') {
        Write-Output '[!!]  Platform Version (AMProductVersion)'
        Write-Output '       Could not retrieve. Defender may be broken.'; $issueCount++
    } else {
        $platCmp = Compare-VerString -Current $platVer -Baseline $platformCritBaseline
        $platWarnCmp = Compare-VerString -Current $platVer -Baseline $platformWarnBaseline
        if ($platCmp -lt 0) {
            Write-Output '[!!]  Platform Version (AMProductVersion)'
            Write-Output "       $platVer -- CRITICALLY OUTDATED."
            Write-Output "       Below N-2 threshold ($platformCritBaseline). This endpoint is in a"
            Write-Output '       deprecated and unsupported state. The engine may fail to ingest'
            Write-Output '       modern Security Intelligence payloads silently.'
            Write-Output '       -> Force update: MpCmdRun.exe -SignatureUpdate -MMPC'; $issueCount++
        } elseif ($platWarnCmp -lt 0) {
            Write-Output '[!]   Platform Version (AMProductVersion)'
            Write-Output "       $platVer -- behind baseline ($platformWarnBaseline). Approaching N-2. Update soon."
            $warnCount++
        } else {
            Write-Output '[OK]  Platform Version (AMProductVersion)'
            Write-Output "       $platVer. Current (at or above baseline $platformWarnBaseline)."
        }
    }
    if ([string]::IsNullOrWhiteSpace($engineVer) -or $engineVer -eq '0.0.0.0') {
        Write-Output '[!!]  Engine Version (AMEngineVersion)'
        Write-Output '       Could not retrieve. Defender may be broken.'; $issueCount++
    } else {
        $engCmp = Compare-VerString -Current $engineVer -Baseline $engineCritBaseline
        $engWarnCmp = Compare-VerString -Current $engineVer -Baseline $engineWarnBaseline
        if ($engCmp -lt 0) {
            Write-Output '[!!]  Engine Version (AMEngineVersion)'
            Write-Output "       $engineVer -- CRITICALLY OUTDATED."
            Write-Output "       Below threshold ($engineCritBaseline). Engine cannot process"
            Write-Output '       modern definition payloads. Platform update needed first.'
            Write-Output '       -> Force update: MpCmdRun.exe -SignatureUpdate -MMPC'; $issueCount++
        } elseif ($engWarnCmp -lt 0) {
            Write-Output '[!]   Engine Version (AMEngineVersion)'
            Write-Output "       $engineVer -- behind baseline ($engineWarnBaseline)."; $warnCount++
        } else {
            Write-Output '[OK]  Engine Version (AMEngineVersion)'
            Write-Output "       $engineVer. Current."
        }
    }
    if ([string]::IsNullOrWhiteSpace($nisVer) -or $nisVer -eq '0.0.0.0') {
        Write-Output '[i]   NIS Engine Version'
        Write-Output '       Not available or not applicable.'
    } else {
        Write-Output '[i]   NIS Engine Version'
        Write-Output "       $nisVer. (NIS engine does not have an independent deprecation threshold.)"
    }
}
Write-Output ''
Write-Output '--- Update Channel & Ring ---'
$channelMap = @{ 0 = 'Not Configured (default -- immediate GA)'; 2 = 'Beta Channel (earliest adopter)'; 3 = 'Current Channel (Preview)'; 4 = 'Current Channel (Staged -- pilot production)'; 5 = 'Current Channel (Broad -- most conservative GA)'; 6 = 'Critical -- Time Delay (48-hour intentional delay)' }
$gpoUpdPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Updates'
$mdmDefPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender'
$localDefPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
$channelSettings = @( @{ Display = 'Platform Update Channel'; Name = 'PlatformUpdatesChannel' }, @{ Display = 'Engine Update Channel'; Name = 'EngineUpdatesChannel' } )
foreach ($cs in $channelSettings) {
    $gpoVal = Get-RegVal -Path $gpoUpdPath -Name $cs.Name
    $mdmVal = Get-RegVal -Path $mdmDefPath -Name $cs.Name
    $localVal = Get-RegVal -Path $localDefPath -Name $cs.Name
    $gpoStr = 'Not set'; $mdmStr = 'Not set'; $localStr = 'Not set'
    if ($null -ne $gpoVal) { $gpoInt = [int]$gpoVal; $gpoDesc = "Unknown ($gpoInt)"; if ($channelMap.ContainsKey($gpoInt)) { $gpoDesc = $channelMap[$gpoInt] }; $gpoStr = "$gpoInt ($gpoDesc)" }
    if ($null -ne $mdmVal) { $mdmInt = [int]$mdmVal; $mdmDesc = "Unknown ($mdmInt)"; if ($channelMap.ContainsKey($mdmInt)) { $mdmDesc = $channelMap[$mdmInt] }; $mdmStr = "$mdmInt ($mdmDesc)" }
    if ($null -ne $localVal) { $localInt = [int]$localVal; $localDesc = "Unknown ($localInt)"; if ($channelMap.ContainsKey($localInt)) { $localDesc = $channelMap[$localInt] }; $localStr = "$localInt ($localDesc)" }
    $isDelayed = $false; $delayedSource = ''
    if ($null -ne $gpoVal -and ([int]$gpoVal -ge 4)) { $isDelayed = $true; $delayedSource = 'GPO' }
    if ($null -ne $mdmVal -and ([int]$mdmVal -ge 4)) { $isDelayed = $true; if ($delayedSource.Length -gt 0) { $delayedSource += '/MDM' } else { $delayedSource = 'MDM' } }
    if ($isDelayed) {
        Write-Output "[i]   $($cs.Display) -- Delayed Ring"
        Write-Output "       GPO: $gpoStr. MDM: $mdmStr. Local: $localStr."
        Write-Output "       Machine is on a delayed update ring (set by $delayedSource)."
        Write-Output '       This is intentional in managed environments but may explain why'
        Write-Output '       the platform version appears behind.'
    } else {
        Write-Output "[OK]  $($cs.Display)"
        Write-Output "       GPO: $gpoStr. MDM: $mdmStr. Local: $localStr."
    }
}
$siChannel = Get-RegVal -Path $gpoUpdPath -Name 'DefinitionUpdatesChannel'
if ($null -ne $siChannel) { $siInt = [int]$siChannel; $siDesc = "Unknown ($siInt)"; if ($channelMap.ContainsKey($siInt)) { $siDesc = $channelMap[$siInt] }; Write-Output "[i]   Security Intelligence Channel (GPO): $siInt ($siDesc)" }
$gradualPct = Get-RegVal -Path $gpoUpdPath -Name 'PlatformUpdatesGradualRolloutPercentage'
if ($null -ne $gradualPct) { Write-Output "[i]   Gradual Rollout Percentage: ${gradualPct}%"; Write-Output '       Platform updates are throttled to a subset of the fleet.' }
Write-Output ''
Write-Output '--- Platform Update Events (last 30 days) ---'
$lookbackDays = 30; $startTime = (Get-Date).AddDays(-$lookbackDays)
$eventLog = 'Microsoft-Windows-Windows Defender/Operational'
$hresultMap = @{ '0x80310059' = 'BitLocker encryption conflict blocking platform update (PCR 7 / Secure Boot)'; '0x80070643' = 'Fatal installation error -- .NET corruption or insufficient WinRE partition (<250 MB)'; '0x80240016' = 'Update locked -- another installation in progress'; '0x80508007' = 'Out of memory -- platform payload failed to unpack'; '0x80290401' = 'TPM Platform Crypto Device not ready'; '0x80508023' = 'Platform too old -- update rejected by the engine (N-2 exceeded)'; '0x80070005' = 'Access denied -- permissions issue during update'; '0x80508026' = 'Engine update failed'; '0x800F0922' = 'CBS session error -- insufficient WinRE partition or pending reboot'; '0x80240022' = 'All updates failed -- payload corrupted in transit' }
$succEvents = $null
try { $succEvents = Get-WinEvent -FilterHashtable @{ LogName = $eventLog; Id = 2002; StartTime = $startTime } -MaxEvents 10 -ErrorAction Stop } catch { }
$succCount = 0; if ($null -ne $succEvents) { $succCount = @($succEvents).Count }
if ($succCount -gt 0) {
    $latestSucc = @($succEvents)[0]; $succTimeStr = $latestSucc.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    Write-Output '[OK]  Platform/Engine Update Success (Event 2002)'
    Write-Output "       $succCount successful update(s) in last $lookbackDays days. Most recent: $succTimeStr."
} else {
    Write-Output '[!]   Platform/Engine Updates (Event 2002)'
    Write-Output "       No successful platform/engine updates in the last $lookbackDays days."
    Write-Output '       The platform update pipeline may be stalled.'; $warnCount++
}
$warnEventIds = @(2007, 5100, 5101)
$warnEventNames = @{ 2007 = 'MALWAREPROTECTION_PLATFORM_ALMOSTOUTOFDATE -- platform approaching deprecation'; 5100 = 'MALWAREPROTECTION_EXPIRATION_WARNING_STATE -- grace period ending'; 5101 = 'MALWAREPROTECTION_DISABLED_EXPIRED_STATE -- platform expired, protection force-disabled' }
foreach ($eid in $warnEventIds) {
    $evts = $null
    try { $evts = Get-WinEvent -FilterHashtable @{ LogName = $eventLog; Id = $eid; StartTime = $startTime } -MaxEvents 5 -ErrorAction Stop } catch { }
    if ($null -ne $evts -and @($evts).Count -gt 0) {
        $latestEvt = @($evts)[0]; $evtTimeStr = $latestEvt.TimeCreated.ToString('yyyy-MM-dd HH:mm'); $evtDesc = $warnEventNames[$eid]
        if ($eid -eq 5101) {
            Write-Output "[!!]  Event ${eid}: $evtDesc"; Write-Output "       Last occurrence: $evtTimeStr."
            Write-Output '       Defender has entered an expired state and protection is disabled.'
            Write-Output '       Immediate platform update required.'; $issueCount++
        } elseif ($eid -eq 5100) {
            Write-Output "[!!]  Event ${eid}: $evtDesc"; Write-Output "       Last occurrence: $evtTimeStr."
            Write-Output '       The platform is about to expire. Update now to avoid protection loss.'; $issueCount++
        } else {
            Write-Output "[]   Event ${eid}: $evtDesc"; Write-Output "       Last occurrence: $evtTimeStr."
            Write-Output '       The platform is approaching the N-2 deprecation threshold.'
            Write-Output '       -> Force platform update or approve KB4052623 on WSUS.'; $warnCount++
        }
    }
}
$failEvents = $null
try { $failEvents = Get-WinEvent -FilterHashtable @{ LogName = $eventLog; Id = 2001, 2003; StartTime = $startTime } -MaxEvents 20 -ErrorAction Stop } catch { }
$platformFailCount = 0; $latestPlatformFail = $null
if ($null -ne $failEvents) {
    foreach ($fe in @($failEvents)) {
        $feMsg = "$($fe.Message)"; $isPlatform = $false
        if ($feMsg -match '(?i)platform|engine update|MoCAMP') { $isPlatform = $true }
        if ($feMsg -match '0x80508023|0x80310059|0x80070643|0x800F0922') { $isPlatform = $true }
        if ($isPlatform) { $platformFailCount++; if ($null -eq $latestPlatformFail) { $latestPlatformFail = $fe } }
    }
}
if ($platformFailCount -gt 0 -and $null -ne $latestPlatformFail) {
    $failTimeStr = $latestPlatformFail.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $failMsg = "$($latestPlatformFail.Message)"; $hresultCode = ''; $hresultDesc = ''
    if ($failMsg -match '0x[0-9A-Fa-f]{8}') { $hresultCode = $Matches[0].ToUpper(); $lookupKey = '0x' + $hresultCode.Substring(2); if ($hresultMap.ContainsKey($lookupKey)) { $hresultDesc = $hresultMap[$lookupKey] } }
    Write-Output '[!!]  Platform/Engine Update Failure'
    Write-Output "       $platformFailCount platform-related failure(s) in last $lookbackDays days."
    Write-Output "       Most recent: $failTimeStr (Event $($latestPlatformFail.Id))."
    if (-not [string]::IsNullOrWhiteSpace($hresultCode)) {
        if (-not [string]::IsNullOrWhiteSpace($hresultDesc)) {
            Write-Output "       Error: $hresultCode -- $hresultDesc."
        } else {
            Write-Output "       Error: $hresultCode (not in known HRESULT table)."
        }

        # Catch WinRE exhaustion errors and proactively query disk state
        if ($hresultCode -eq '0X80070643' -or $hresultCode -eq '0X800F0922') {
            Write-Output ''
            Write-Output '       --> PROACTIVE DIAGNOSTIC: WinRE Verification <--'
            try {
                $reagentcOutput = & reagentc.exe /info
                Write-Output '       [reagentc.exe /info output]'
                foreach ($line in $reagentcOutput) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Output "       > $line" }
                }
            } catch {
                Write-Output '       [reagentc.exe /info failed to execute]'
            }

            try {
                Write-Output '       [Recovery Partition Free Space]'
                $osDisk = Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1) -ErrorAction Stop
                $recParts = @(Get-Partition -DiskNumber $osDisk.DiskNumber -ErrorAction Stop | Where-Object {
                    $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or $_.Type -eq 'Recovery'
                })
                
                if ($recParts.Count -gt 0) {
                    $recPart = $recParts[$recParts.Count - 1]
                    $recSizeMB = [math]::Round($recPart.Size / 1MB, 0)
                    $volInfo = $null
                    try { $volInfo = Get-Volume -Partition $recPart -ErrorAction Stop } catch { }
                    
                    if ($null -ne $volInfo -and $null -ne $volInfo.SizeRemaining) {
                        $freeMB = [math]::Round($volInfo.SizeRemaining / 1MB, 0)
                        $statusStr = if ($freeMB -lt 250) { 'CRITICAL (WinRE updates blocked)' } else { 'OK' }
                        Write-Output "       > Size: $recSizeMB MB | Free: $freeMB MB ($statusStr)"
                    } else {
                        Write-Output "       > Size: $recSizeMB MB | Free: Unknown (partition locked)"
                    }
                } else {
                    Write-Output '       > No dedicated Recovery Partition found.'
                }
            } catch {
                Write-Output '       > Failed to query disk partition data.'
            }
            Write-Output ''
        }
    }
    $issueCount++
}
$cfgEvents = $null
try { $cfgEvents = Get-WinEvent -FilterHashtable @{ LogName = $eventLog; Id = 5007; StartTime = $startTime } -MaxEvents 5 -ErrorAction Stop } catch { }
$channelChangeCount = 0
if ($null -ne $cfgEvents) { foreach ($ce in @($cfgEvents)) { $ceMsg = "$($ce.Message)"; if ($ceMsg -match '(?i)PlatformUpdatesChannel|EngineUpdatesChannel') { $channelChangeCount++ } } }
if ($channelChangeCount -gt 0) { Write-Output "[i]   Update channel configuration changed $channelChangeCount time(s) in last $lookbackDays days."; Write-Output '       Verify the current channel setting is intentional (see above).' }
Write-Output ''
Write-Output '--- MoCAMP Update Mechanism ---'
$defenderRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
$mocampLock = Get-RegVal -Path $defenderRegPath -Name 'MoCAMPUpdateStarted'
if ($null -ne $mocampLock) {
    Write-Output '[!!]  MoCAMPUpdateStarted Lock: PRESENT'
    Write-Output "       Value: $mocampLock"
    Write-Output '       An orphaned update lock is blocking all platform updates.'
    Write-Output '       A previous update was interrupted (power loss, crash, or forced termination).'
    Write-Output '       -> Run DEF008 DEFRemediation to clear this lock.'; $issueCount++
} else {
    Write-Output '[OK]  MoCAMPUpdateStarted Lock: Not present'
    Write-Output '       No orphaned update lock. Platform update pipeline is clear.'
}
$platformDir = 'C:\ProgramData\Microsoft\Windows Defender\Platform'
if (Test-Path -Path $platformDir) {
    $platFolders = $null
    try { $platFolders = @(Get-ChildItem -Path $platformDir -Directory -ErrorAction Stop) } catch { }
    if ($null -ne $platFolders -and $platFolders.Count -gt 0) {
        $sorted = $platFolders | Sort-Object -Property Name -Descending
        $latestFolder = $sorted[0].Name; $folderCount = $platFolders.Count
        if ($folderCount -gt 3) {
            Write-Output "[!]   Platform Staging Directory: $folderCount version folders"
            Write-Output "       Latest: $latestFolder. Multiple old versions remain."
            Write-Output '       Excessive staging folders may indicate failed cleanup after updates.'; $warnCount++
        } else {
            Write-Output "[OK]  Platform Staging Directory: $folderCount version folder(s)"
            Write-Output "       Latest: $latestFolder."
        }
        if ($statusOK -and -not [string]::IsNullOrWhiteSpace($platVer)) {
            if ($latestFolder -match '^(\d+\.\d+\.\d+\.\d+)') {
                $folderVer = $Matches[1]; $stageCmp = Compare-VerString -Current $folderVer -Baseline $platVer
                if ($stageCmp -gt 0) { Write-Output "[i]   Staged version ($folderVer) is newer than running platform ($platVer)."; Write-Output '       A platform update is staged but not yet active. A reboot may be required.' }
                elseif ($stageCmp -lt 0) { Write-Output "[i]   Staged folder ($folderVer) is older than running platform ($platVer)."; Write-Output '       Old staging folder -- normal after a successful update.' }
            }
        }
    } else { Write-Output '[i]   Platform Staging Directory: Empty or inaccessible' }
} else {
    Write-Output '[!]   Platform Staging Directory: NOT FOUND'
    Write-Output "       Expected path: $platformDir"
    Write-Output '       This directory should exist on all Windows 10/11 machines with Defender.'; $warnCount++
}
$updateSvcs = @( @{ Name = 'wuauserv'; Display = 'Windows Update (wuauserv)' }, @{ Name = 'BITS'; Display = 'Background Intelligent Transfer (BITS)' } )
foreach ($us in $updateSvcs) {
    $svc = Get-Service -Name $us.Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { Write-Output "[]   $($us.Display): Service not found"; $warnCount++ }
    else {
        $svcStart = $svc.StartType.ToString(); $svcStatus = $svc.Status.ToString()
        if ($svcStart -eq 'Disabled') { Write-Output "[!!]  $($us.Display): DISABLED"; Write-Output "       Start type: Disabled. Platform updates cannot be delivered."; Write-Output '       KB4052623 requires Windows Update and BITS to download.'; $issueCount++ }
        elseif ($svcStatus -ne 'Running' -and $svcStart -match 'Manual|Automatic') { Write-Output "[i]   $($us.Display): $svcStatus (start type: $svcStart)"; Write-Output '       Service is not running but will start on demand.' }
        else { Write-Output "[OK]  $($us.Display): $svcStatus (start type: $svcStart)" }
    }
}
Write-Output ''
Write-Output '--- WSUS Pinning Analysis ---'
$wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wuServer = Get-RegVal -Path $wuPath -Name 'WUServer'
$sigUpdPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates'
$fallbackOrder = Get-RegVal -Path $sigUpdPath -Name 'FallbackOrder'
$wsusConfigured = (-not [string]::IsNullOrWhiteSpace($wuServer))
$wsusInFallback = ($null -ne $fallbackOrder -and $fallbackOrder -match 'InternalDefinitionUpdateServer')
if ($wsusConfigured) {
    Write-Output "[i]   WSUS Server: $wuServer"
    if ($statusOK -and -not [string]::IsNullOrWhiteSpace($platVer)) {
        $wsusPlatCmp = Compare-VerString -Current $platVer -Baseline $platformWarnBaseline
        if ($wsusPlatCmp -lt 0) {
            Write-Output '[!]   WSUS + Outdated Platform'
            Write-Output "       Platform version ($platVer) is behind baseline ($platformWarnBaseline)."
            Write-Output '       WSUS is the update server. KB4052623 (Defender platform update) may not'
            Write-Output '       be approved on the WSUS console.'
            Write-Output '       -> Verify KB4052623 approval status on the WSUS server.'
            Write-Output '       -> Or add MicrosoftUpdateServer/MMPC to the signature FallbackOrder.'; $warnCount++
        } else {
            Write-Output '[OK]  WSUS + Platform Version'
            Write-Output '       Platform is current despite WSUS management. KB4052623 appears approved.'
        }
    }
    if ($wsusInFallback) { Write-Output '[i]   WSUS is in the signature FallbackOrder. Platform updates also route through WSUS.' }
} else {
    Write-Output '[OK]  WSUS: Not configured'
    Write-Output '       Platform updates are sourced directly from Microsoft Update (default).'
}
if ($wsusConfigured) {
    $forceFromMU = Get-RegVal -Path $sigUpdPath -Name 'ForceUpdateFromMU'
    if ($null -ne $forceFromMU -and $forceFromMU -eq 1) { Write-Output '[i]   ForceUpdateFromMU: Enabled. Definitions can bypass WSUS to Microsoft Update.' }
}
Write-Output ''
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) { Write-Output 'RESULT: No issues detected. Defender platform and engine are current.' }
elseif ($issueCount -gt 0 -and $warnCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above." }
elseif ($issueCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above." }
else { Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above." }
Write-Output ''
Write-Output 'NEXT:   If platform outdated         -> force update via: MpCmdRun.exe -SignatureUpdate -MMPC'
Write-Output '        If WSUS holding back         -> approve Defender platform updates (KB4052623) on WSUS'
Write-Output '        If MoCAMP lock present       -> run DEF008 DEFRemediation to reset the update path'
Write-Output '        If platform current          -> run DEF007 DEFEventAnalysis for event-level investigation'
Write-Output ''
