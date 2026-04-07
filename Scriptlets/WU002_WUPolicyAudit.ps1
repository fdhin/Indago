# WU002_WUPolicyAudit.ps1
# Scriptlet: WU002 - WU Policy & Configuration Audit
# Context: System | Version: 1.2

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$gpoRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$gpoAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$uxSettings = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$mdmUpdate = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
$doPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
$mdmConflict = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict'
$hasGPOKeys = $false
$hasMDMKeys = $false
function Get-RegValue { param([string]$Path, [string]$Name); try { $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop; return $item.$Name } catch { return $null } }

$wuServer = Get-RegValue -Path $gpoRoot -Name 'WUServer'
$wuStatusServer = Get-RegValue -Path $gpoRoot -Name 'WUStatusServer'
$useWUServer = Get-RegValue -Path $gpoAU -Name 'UseWUServer'
if ([string]::IsNullOrWhiteSpace($wuServer)) {
    $findings.Add([PSCustomObject]@{ Check = 'WSUS Server'; Status = 'OK'; Detail = 'Not configured. Client uses Microsoft Update or MDM for updates.' })
} else {
    $hasGPOKeys = $true
    if ($useWUServer -eq 1) {
        $wsusReachable = $false; $wsusHost = $null; $wsusPort = 8530; $tcp = $null
        try {
            $uri = [System.Uri]$wuServer; $wsusHost = $uri.Host; $wsusPort = $uri.Port
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($wsusHost, $wsusPort, $null, $null)
            $waited = $ar.AsyncWaitHandle.WaitOne(3000, $false)
            if ($waited -and $tcp.Connected) { $wsusReachable = $true }
        } catch { } finally {
            if ($null -ne $tcp) { try { $tcp.Close() } catch { } }
        }
        if ($wsusReachable) { $findings.Add([PSCustomObject]@{ Check = 'WSUS Server'; Status = 'OK'; Detail = "WSUS routing active. Server responds on ${wsusHost}:${wsusPort}. URL: $wuServer" }) }
        else { $findings.Add([PSCustomObject]@{ Check = 'WSUS Server'; Status = 'ISSUE'; Detail = "WSUS server configured but NOT responding on ${wsusHost}:${wsusPort}. All update scans will fail. URL: $wuServer" }) }
    } else {
        $findings.Add([PSCustomObject]@{ Check = 'WSUS Server'; Status = 'WARN'; Detail = "WSUS URL is set ($wuServer) but UseWUServer is not enabled. Client may ignore the WSUS server." })
    }
    if (-not [string]::IsNullOrWhiteSpace($wuStatusServer) -and $wuServer -ne $wuStatusServer) { $findings.Add([PSCustomObject]@{ Check = 'WSUS Status Server'; Status = 'WARN'; Detail = "Status reports go to a different server than update scans. WUServer: $wuServer, WUStatusServer: $wuStatusServer" }) }
}

$noAutoUpdate = Get-RegValue -Path $gpoAU -Name 'NoAutoUpdate'
if ($null -ne $noAutoUpdate -and $noAutoUpdate -eq 1) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Automatic Updates (GPO)'; Status = 'ISSUE'; Detail = 'NoAutoUpdate = 1. Automatic updates are DISABLED by Group Policy. No updates will download or install automatically.' }) }
else { $findings.Add([PSCustomObject]@{ Check = 'Automatic Updates (GPO)'; Status = 'OK'; Detail = 'NoAutoUpdate is not set. Automatic updates are enabled.' }) }

$disableAccess = Get-RegValue -Path $gpoRoot -Name 'DisableWindowsUpdateAccess'
if ($null -ne $disableAccess -and $disableAccess -eq 1) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Windows Update Access (GPO)'; Status = 'ISSUE'; Detail = 'DisableWindowsUpdateAccess = 1. Access to Windows Update is BLOCKED by policy. Common HRESULT: 0x8024002E.' }) }
else { $findings.Add([PSCustomObject]@{ Check = 'Windows Update Access (GPO)'; Status = 'OK'; Detail = 'Access to Windows Update is not blocked by policy.' }) }

$noInternet = Get-RegValue -Path $gpoRoot -Name 'DoNotConnectToWindowsUpdateInternetLocations'
if ($null -ne $noInternet -and $noInternet -eq 1) {
    $hasGPOKeys = $true
    if (-not [string]::IsNullOrWhiteSpace($wuServer)) { $findings.Add([PSCustomObject]@{ Check = 'Internet Locations (GPO)'; Status = 'INFO'; Detail = 'Client is locked to WSUS only. Expected in WSUS-managed environments. If WSUS is down, updates will fail with no fallback.' }) }
    else { $findings.Add([PSCustomObject]@{ Check = 'Internet Locations (GPO)'; Status = 'ISSUE'; Detail = 'DoNotConnectToWindowsUpdateInternetLocations = 1 but NO WSUS server is configured. Updates are completely blocked -- no source available.' }) }
} else { $findings.Add([PSCustomObject]@{ Check = 'Internet Locations (GPO)'; Status = 'OK'; Detail = 'Client can reach Microsoft Update if WSUS is unavailable. No internet blocking policy set.' }) }

$auOptions = Get-RegValue -Path $gpoAU -Name 'AUOptions'
if ($null -ne $auOptions) {
    $hasGPOKeys = $true
    $auDesc = switch ([int]$auOptions) { 1 { 'Keep me updated is disabled. Updates will not be offered automatically.' } 2 { 'Notify before download. User must approve every download.' } 3 { 'Auto-download, notify before install. User must approve installation.' } 4 { 'Auto-download and auto-install on schedule. Fully automated.' } 5 { 'Allow local admin to configure. Defers to local policy.' } default { "Unknown value: $auOptions." } }
    $auStatus = switch ([int]$auOptions) { 1 { 'WARN' } 2 { 'INFO' } 3 { 'INFO' } 4 { 'OK' } 5 { 'INFO' } default { 'WARN' } }
    $findings.Add([PSCustomObject]@{ Check = 'Auto-Update Behavior (GPO)'; Status = $auStatus; Detail = "AUOptions = $auOptions. $auDesc" })
} else { $findings.Add([PSCustomObject]@{ Check = 'Auto-Update Behavior (GPO)'; Status = 'OK'; Detail = 'Not configured by policy. Default OS behavior applies.' }) }

$deferFeature = Get-RegValue -Path $gpoRoot -Name 'DeferFeatureUpdatesPeriodInDays'
$deferQuality = Get-RegValue -Path $gpoRoot -Name 'DeferQualityUpdatesPeriodInDays'
$pauseDefer = Get-RegValue -Path $gpoRoot -Name 'PauseDeferrals'
$pauseFeatureStart = Get-RegValue -Path $gpoRoot -Name 'PauseFeatureUpdatesStartTime'
$pauseQualityStart = Get-RegValue -Path $gpoRoot -Name 'PauseQualityUpdatesStartTime'
if ($null -ne $deferFeature) { $hasGPOKeys = $true; $fStatus = if ([int]$deferFeature -gt 180) { 'WARN' } else { 'INFO' }; $fExtra = if ([int]$deferFeature -gt 180) { ' Over 6 months is aggressive -- machine may miss important feature updates.' } else { '' }; $findings.Add([PSCustomObject]@{ Check = 'Feature Update Deferral (GPO)'; Status = $fStatus; Detail = "Deferred by $deferFeature day(s).$fExtra" }) }
if ($null -ne $deferQuality) { $hasGPOKeys = $true; $qStatus = if ([int]$deferQuality -gt 14) { 'WARN' } else { 'INFO' }; $qExtra = if ([int]$deferQuality -gt 14) { ' Over 14 days means missing two or more Patch Tuesdays. Security risk.' } else { '' }; $findings.Add([PSCustomObject]@{ Check = 'Quality Update Deferral (GPO)'; Status = $qStatus; Detail = "Deferred by $deferQuality day(s).$qExtra" }) }
if ($null -ne $pauseDefer -and $pauseDefer -eq 1) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Pause Deferrals (GPO)'; Status = 'WARN'; Detail = 'PauseDeferrals = 1. All update deferrals are paused by policy.' }) }
if (-not [string]::IsNullOrWhiteSpace($pauseQualityStart)) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Quality Update Pause (GPO)'; Status = 'ISSUE'; Detail = "Quality/security patches paused since $pauseQualityStart. Security risk -- machine is not receiving security updates." }) }
if (-not [string]::IsNullOrWhiteSpace($pauseFeatureStart)) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Feature Update Pause (GPO)'; Status = 'WARN'; Detail = "Feature updates paused since $pauseFeatureStart." }) }
if ($null -eq $deferFeature -and $null -eq $deferQuality -and ($null -eq $pauseDefer -or $pauseDefer -ne 1) -and [string]::IsNullOrWhiteSpace($pauseQualityStart) -and [string]::IsNullOrWhiteSpace($pauseFeatureStart)) { $findings.Add([PSCustomObject]@{ Check = 'Deferral & Pause Settings (GPO)'; Status = 'OK'; Detail = 'No deferral or pause policies configured at the GPO layer.' }) }

$excludeDriversGPO = Get-RegValue -Path $gpoRoot -Name 'ExcludeWUDriversInQualityUpdate'
if ($null -ne $excludeDriversGPO -and $excludeDriversGPO -eq 1) { $hasGPOKeys = $true; $findings.Add([PSCustomObject]@{ Check = 'Driver Update Exclusion (GPO)'; Status = 'INFO'; Detail = 'ExcludeWUDriversInQualityUpdate = 1. Driver updates are excluded from quality updates. If users report missing drivers, this is the cause.' }) }

$ahStart = Get-RegValue -Path $uxSettings -Name 'ActiveHoursStart'
$ahEnd = Get-RegValue -Path $uxSettings -Name 'ActiveHoursEnd'
if ($null -ne $ahStart -and $null -ne $ahEnd) {
    $span = $ahEnd - $ahStart; if ($span -lt 0) { $span = $span + 24 }
    if ($span -gt 18) { $findings.Add([PSCustomObject]@{ Check = 'Active Hours'; Status = 'WARN'; Detail = "Active hours: ${ahStart}:00 - ${ahEnd}:00 (${span}h span). Exceeds the 18-hour maximum. OS will clamp to 18 hours, severely limiting the auto-restart window." }) }
    else { $findings.Add([PSCustomObject]@{ Check = 'Active Hours'; Status = 'INFO'; Detail = "Active hours: ${ahStart}:00 - ${ahEnd}:00 (${span}h span). OS will not auto-restart during these hours." }) }
} else { $findings.Add([PSCustomObject]@{ Check = 'Active Hours'; Status = 'OK'; Detail = 'Not configured. Default active hours apply (8 AM - 5 PM).' }) }

$pauseExpiry = Get-RegValue -Path $uxSettings -Name 'PauseUpdatesExpiryTime'
if (-not [string]::IsNullOrWhiteSpace($pauseExpiry)) {
    try {
        $expiryDate = [datetime]::Parse($pauseExpiry, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($expiryDate -gt (Get-Date)) { $findings.Add([PSCustomObject]@{ Check = 'User-Initiated Pause'; Status = 'ISSUE'; Detail = "Updates paused via Settings UI. Pause expires: $($expiryDate.ToString('yyyy-MM-dd')). No updates will install until then." }) }
        else { $findings.Add([PSCustomObject]@{ Check = 'User-Initiated Pause'; Status = 'OK'; Detail = "A previous pause expired on $($expiryDate.ToString('yyyy-MM-dd')). Updates should resume normally." }) }
    } catch {
        $findings.Add([PSCustomObject]@{ Check = 'User-Initiated Pause'; Status = 'INFO'; Detail = "PauseUpdatesExpiryTime is set ($pauseExpiry) but could not parse the date." })
    }
} else { $findings.Add([PSCustomObject]@{ Check = 'User-Initiated Pause'; Status = 'OK'; Detail = 'No user-initiated pause is active.' }) }

$doMode = Get-RegValue -Path $doPolicy -Name 'DODownloadMode'
if ($null -ne $doMode) {
    $doDesc = switch ([int]$doMode) { 0 { 'HTTP only. No peering. All downloads from Microsoft CDN.' } 1 { 'LAN peering (default). Peers on the same subnet share update payloads.' } 2 { 'Group peering. Peers across subnets within the same AD site or group.' } 3 { 'Internet peering. Machine acts as a public peer. Unusual in enterprise.' } 99 { 'Simple download mode (no peering, no caching). May significantly slow large updates.' } 100 { 'Bypass mode. Delivery Optimization disabled. BITS used directly. May cause slower downloads.' } default { "Unknown value: $doMode." } }
    $doStatus = switch ([int]$doMode) { 0 { 'INFO' } 1 { 'OK' } 2 { 'OK' } 3 { 'INFO' } 99 { 'WARN' } 100 { 'WARN' } default { 'INFO' } }
    $findings.Add([PSCustomObject]@{ Check = 'Delivery Optimization'; Status = $doStatus; Detail = "DODownloadMode = $doMode. $doDesc" })
} else { $findings.Add([PSCustomObject]@{ Check = 'Delivery Optimization'; Status = 'OK'; Detail = 'Not configured by policy. Default mode applies (LAN peering).' }) }

$tgEnabled = Get-RegValue -Path $gpoRoot -Name 'TargetGroupEnabled'
$tgName = Get-RegValue -Path $gpoRoot -Name 'TargetGroup'
if ($null -ne $tgEnabled -and $tgEnabled -eq 1) {
    $hasGPOKeys = $true
    if (-not [string]::IsNullOrWhiteSpace($tgName)) { $findings.Add([PSCustomObject]@{ Check = 'WSUS Target Group'; Status = 'INFO'; Detail = "Client-side targeting enabled. Target group: '$tgName'. Verify this matches the intended deployment ring." }) }
    else { $findings.Add([PSCustomObject]@{ Check = 'WSUS Target Group'; Status = 'WARN'; Detail = 'Client-side targeting is enabled but no target group name is set. Client will appear in the Unassigned Computers group on WSUS.' }) }
} elseif (-not [string]::IsNullOrWhiteSpace($wuServer)) { $findings.Add([PSCustomObject]@{ Check = 'WSUS Target Group'; Status = 'INFO'; Detail = 'Client-side targeting not configured. Server-side targeting in use on WSUS.' }) }

$mdmExists = Test-Path -Path $mdmUpdate
if ($mdmExists) {
    $hasMDMKeys = $true
    $mdmAllowAuto = Get-RegValue -Path $mdmUpdate -Name 'AllowAutoUpdate'
    $mdmDeferFeature = Get-RegValue -Path $mdmUpdate -Name 'DeferFeatureUpdatesPeriodInDays'
    $mdmDeferQuality = Get-RegValue -Path $mdmUpdate -Name 'DeferQualityUpdatesPeriodInDays'
    $mdmPauseQuality = Get-RegValue -Path $mdmUpdate -Name 'PauseQualityUpdatesStartTime'
    $mdmPauseFeature = Get-RegValue -Path $mdmUpdate -Name 'PauseFeatureUpdatesStartTime'
    $mdmExcludeDrivers = Get-RegValue -Path $mdmUpdate -Name 'ExcludeWUDriversInQualityUpdate'
    $mdmProductVersion = Get-RegValue -Path $mdmUpdate -Name 'ProductVersion'
    if ($null -ne $mdmAllowAuto) {
        $mdmAutoDesc = switch ([int]$mdmAllowAuto) { 0 { 'Notify before download. User must approve.' } 1 { 'Auto-install at maintenance time.' } 2 { 'Auto-install and auto-restart at maintenance time.' } 3 { 'Auto-install and restart at a scheduled time.' } 4 { 'Auto-install and restart without user control.' } 5 { 'Turn off automatic updates.' } default { "Unknown value: $mdmAllowAuto." } }
        $mdmAutoStatus = if ([int]$mdmAllowAuto -eq 5) { 'ISSUE' } elseif ([int]$mdmAllowAuto -eq 0) { 'WARN' } else { 'INFO' }
        $findings.Add([PSCustomObject]@{ Check = 'AllowAutoUpdate (MDM)'; Status = $mdmAutoStatus; Detail = "AllowAutoUpdate = $mdmAllowAuto. $mdmAutoDesc" })
    }
    if ($null -ne $mdmDeferFeature) { $mdfStatus = if ([int]$mdmDeferFeature -gt 180) { 'WARN' } else { 'INFO' }; $mdfExtra = if ([int]$mdmDeferFeature -gt 180) { ' Over 6 months is aggressive.' } else { '' }; $findings.Add([PSCustomObject]@{ Check = 'Feature Update Deferral (MDM)'; Status = $mdfStatus; Detail = "Deferred by $mdmDeferFeature day(s).$mdfExtra" }) }
    if ($null -ne $mdmDeferQuality) { $mdqStatus = if ([int]$mdmDeferQuality -gt 14) { 'WARN' } else { 'INFO' }; $mdqExtra = if ([int]$mdmDeferQuality -gt 14) { ' Over 14 days means missing two or more Patch Tuesdays.' } else { '' }; $findings.Add([PSCustomObject]@{ Check = 'Quality Update Deferral (MDM)'; Status = $mdqStatus; Detail = "Deferred by $mdmDeferQuality day(s).$mdqExtra" }) }
    if (-not [string]::IsNullOrWhiteSpace($mdmPauseQuality)) { $findings.Add([PSCustomObject]@{ Check = 'Quality Update Pause (MDM)'; Status = 'ISSUE'; Detail = "Quality/security patches paused since $mdmPauseQuality. Security risk." }) }
    if (-not [string]::IsNullOrWhiteSpace($mdmPauseFeature)) { $findings.Add([PSCustomObject]@{ Check = 'Feature Update Pause (MDM)'; Status = 'WARN'; Detail = "Feature updates paused since $mdmPauseFeature." }) }
    if ($null -ne $mdmExcludeDrivers -and $mdmExcludeDrivers -eq 1) { $findings.Add([PSCustomObject]@{ Check = 'Driver Update Exclusion (MDM)'; Status = 'INFO'; Detail = 'ExcludeWUDriversInQualityUpdate = 1. Driver updates excluded from quality updates via MDM policy.' }) }
    $mdmTargetRelease = Get-RegValue -Path $mdmUpdate -Name 'TargetReleaseVersion'
    if (-not [string]::IsNullOrWhiteSpace($mdmProductVersion) -or -not [string]::IsNullOrWhiteSpace($mdmTargetRelease)) {
        $pinParts = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($mdmProductVersion)) { $pinParts.Add($mdmProductVersion) }
        if (-not [string]::IsNullOrWhiteSpace($mdmTargetRelease)) { $pinParts.Add($mdmTargetRelease) }
        $findings.Add([PSCustomObject]@{ Check = 'Target Product Version (MDM)'; Status = 'INFO'; Detail = "Device is pinned to OS version: $($pinParts -join ' '). Feature updates beyond this version will not be offered." })
    }
    $mdmKeyCount = @($mdmAllowAuto, $mdmDeferFeature, $mdmDeferQuality, $mdmPauseQuality, $mdmPauseFeature, $mdmExcludeDrivers, $mdmProductVersion, $mdmTargetRelease) | Where-Object { $null -ne $_ }
    if (@($mdmKeyCount).Count -eq 0) { $findings.Add([PSCustomObject]@{ Check = 'MDM Update Policy'; Status = 'INFO'; Detail = 'MDM PolicyManager path exists but no update-specific policies are configured.' }) }
} else { $findings.Add([PSCustomObject]@{ Check = 'MDM Update Policy'; Status = 'INFO'; Detail = 'No MDM update policies detected. Device is not managed by Intune/MDM for Windows Update.' }) }

if ($hasGPOKeys -and $hasMDMKeys) {
    $mdmWins = Get-RegValue -Path $mdmConflict -Name 'MDMWinsOverGP'
    if ($null -ne $mdmWins -and $mdmWins -eq 1) { $findings.Add([PSCustomObject]@{ Check = 'GPO/MDM Conflict Resolution'; Status = 'INFO'; Detail = 'Both GPO and MDM are configuring Windows Update. MDMWinsOverGP = 1 -- MDM policies take precedence for Policy CSP settings. This is expected in co-management environments.' }) }
    else { $findings.Add([PSCustomObject]@{ Check = 'GPO/MDM Conflict Resolution'; Status = 'WARN'; Detail = 'Both GPO and MDM are configuring Windows Update. MDMWinsOverGP is not set -- GPO takes precedence by default. If MDM policies appear ignored, set MDMWinsOverGP = 1 to give MDM priority.' }) }
}

Write-Output ''
Write-Output '=== WU Policy & Configuration Audit ==='
Write-Output ''
$gpoChecks = @('WSUS Server', 'WSUS Status Server', 'Automatic Updates (GPO)', 'Windows Update Access (GPO)', 'Internet Locations (GPO)', 'Auto-Update Behavior (GPO)', 'Feature Update Deferral (GPO)', 'Quality Update Deferral (GPO)', 'Pause Deferrals (GPO)', 'Quality Update Pause (GPO)', 'Feature Update Pause (GPO)', 'Deferral & Pause Settings (GPO)', 'Driver Update Exclusion (GPO)', 'WSUS Target Group')
$uxChecks = @('Active Hours', 'User-Initiated Pause')
$mdmChecks = @('AllowAutoUpdate (MDM)', 'Feature Update Deferral (MDM)', 'Quality Update Deferral (MDM)', 'Quality Update Pause (MDM)', 'Feature Update Pause (MDM)', 'Driver Update Exclusion (MDM)', 'Target Product Version (MDM)', 'MDM Update Policy')
$doChecks = @('Delivery Optimization')
$conflictChecks = @('GPO/MDM Conflict Resolution')
$issueCount = 0
$warnCount = 0
foreach ($f in $findings) { if ($f.Status -eq 'ISSUE') { $issueCount++ }; if ($f.Status -eq 'WARN') { $warnCount++ } }

$gpoFindings = @($findings | Where-Object { $gpoChecks -contains $_.Check })
if ($gpoFindings.Count -gt 0) {
    Write-Output '--- GPO Policy Layer ---'
    foreach ($f in $gpoFindings) {
        $icon = switch ($f.Status) { 'OK' { '[OK]  ' } 'ISSUE' { '[!!]  ' } 'WARN' { '[!]   ' } 'ERROR' { '[ERR] ' } 'INFO' { '[i]   ' } default { "[$($f.Status)] " } }
        Write-Output "$icon$($f.Check)"
        Write-Output "       $($f.Detail)"
    }
    Write-Output ''
}
$uxFindings = @($findings | Where-Object { $uxChecks -contains $_.Check })
if ($uxFindings.Count -gt 0) {
    Write-Output '--- User & UX Settings ---'
    foreach ($f in $uxFindings) {
        $icon = switch ($f.Status) { 'OK' { '[OK]  ' } 'ISSUE' { '[!!]  ' } 'WARN' { '[!]   ' } 'ERROR' { '[ERR] ' } 'INFO' { '[i]   ' } default { "[$($f.Status)] " } }
        Write-Output "$icon$($f.Check)"
        Write-Output "       $($f.Detail)"
    }
    Write-Output ''
}
$mdmFindings = @($findings | Where-Object { $mdmChecks -contains $_.Check })
if ($mdmFindings.Count -gt 0) {
    Write-Output '--- MDM/Intune Policy Layer ---'
    foreach ($f in $mdmFindings) {
        $icon = switch ($f.Status) { 'OK' { '[OK]  ' } 'ISSUE' { '[!!]  ' } 'WARN' { '[!]   ' } 'ERROR' { '[ERR] ' } 'INFO' { '[i]   ' } default { "[$($f.Status)] " } }
        Write-Output "$icon$($f.Check)"
        Write-Output "       $($f.Detail)"
    }
    Write-Output ''
}
$doFindings = @($findings | Where-Object { $doChecks -contains $_.Check })
if ($doFindings.Count -gt 0) {
    Write-Output '--- Delivery Optimization ---'
    foreach ($f in $doFindings) {
        $icon = switch ($f.Status) { 'OK' { '[OK]  ' } 'ISSUE' { '[!!]  ' } 'WARN' { '[!]   ' } 'ERROR' { '[ERR] ' } 'INFO' { '[i]   ' } default { "[$($f.Status)] " } }
        Write-Output "$icon$($f.Check)"
        Write-Output "       $($f.Detail)"
    }
    Write-Output ''
}
$conflictFindings = @($findings | Where-Object { $conflictChecks -contains $_.Check })
if ($conflictFindings.Count -gt 0) {
    Write-Output '--- Policy Conflict Resolution ---'
    foreach ($f in $conflictFindings) {
        $icon = switch ($f.Status) { 'OK' { '[OK]  ' } 'ISSUE' { '[!!]  ' } 'WARN' { '[!]   ' } 'ERROR' { '[ERR] ' } 'INFO' { '[i]   ' } default { "[$($f.Status)] " } }
        Write-Output "$icon$($f.Check)"
        Write-Output "       $($f.Detail)"
    }
    Write-Output ''
}
if ($issueCount -eq 0 -and $warnCount -eq 0) { Write-Output 'RESULT: No issues detected. Windows Update policies appear correctly configured.' }
elseif ($issueCount -gt 0 -and $warnCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] and [!] above." }
elseif ($issueCount -gt 0) { Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above." }
else { Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above." }
Write-Output ''
Write-Output 'NEXT:   If WSUS unreachable           -> verify WSUS server health or escalate to infrastructure team'
Write-Output '        If policies block updates     -> review GPO/Intune policies with the sysadmin'
Write-Output '        If GPO/MDM split-brain        -> decide on a single policy source and set MDMWinsOverGP accordingly'
Write-Output '        If user paused updates        -> unpause via Settings > Windows Update'
Write-Output '        For network-level issues      -> run WU003 WUNetworkCheck'
Write-Output '        For deeper WU investigation   -> run scripts WU003-WU008 in order'
Write-Output ''
