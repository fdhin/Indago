# BL007_BLEventAnalysis.ps1
# Scriptlet: BL007 - BitLocker Event Log & Error Code Analysis
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$allTimelineEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output '=== BitLocker Event Log & Error Code Analysis ==='

# ============================================================
# Parameter handling
# ============================================================
$daysBack = 7
if ($Param1) {
    $parsed = 0
    if ([int]::TryParse($Param1, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 90) {
        $daysBack = $parsed
    }
}

$cutoffTime = (Get-Date).AddDays(-$daysBack)
$cutoffMs = [long]([Math]::Abs((New-TimeSpan -Start (Get-Date) -End $cutoffTime).TotalMilliseconds))

Write-Output "[i]   Time Window: last $daysBack day(s)"
Write-Output "       Cutoff: $($cutoffTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output ''

# ============================================================
# HRESULT Translation Map
# ============================================================
$hresultMap = @{
    '0x80310059' = @{ Name = 'FVE_E_POLICY_CONFLICT'; Meaning = 'Conflicting GPO -- platform validation profile incompatible with firmware or overlapping policy.'; Route = 'Run BL006 BLPolicyConflict' }
    '0x803100B4' = @{ Name = 'FVE_E_EDRIVE_INCOMPATIBLE'; Meaning = 'Incompatible hardware encryption (eDrive) -- volume uses hardware FDE that conflicts with BitLocker software encryption policy.'; Route = 'Run BL003 BLHardwarePrereqs' }
    '0x80284008' = @{ Name = 'TBS_E_SERVICE_NOT_RUNNING'; Meaning = 'TPM Base Services (TBS) down -- cannot communicate with TPM hardware.'; Route = 'Run BL002 BLTpmHealth' }
    '0x803100CC' = @{ Name = 'FVE_E_POLICY_REQUIRES_RECOVERY_PASSWORD_ON_TOUCH_DEVICE'; Meaning = 'Alphanumeric PIN policy mismatch -- policy requires numeric-only but enhanced PINs were attempted (or vice versa).'; Route = 'Run BL006 BLPolicyConflict' }
    '0x80070490' = @{ Name = 'ERROR_NOT_FOUND'; Meaning = 'Missing system partition or BCD corruption -- bootloader infrastructure broken.'; Route = 'Run BL003 BLHardwarePrereqs' }
    '0x80310000' = @{ Name = 'FVE_E_LOCKED_VOLUME'; Meaning = 'Drive is locked by BitLocker -- cannot read volume metadata until unlocked.'; Route = 'Manual unlock required (manage-bde -unlock)' }
    '0x80280001' = @{ Name = 'TPM_E_AUTHFAIL'; Meaning = 'TPM authentication failure -- wrong PIN or owner authorization value rejected by hardware.'; Route = 'Run BL002 BLTpmHealth' }
    '0x80072F9A' = @{ Name = 'WININET_E_CONNECTION_ABORTED'; Meaning = 'Entra ID escrow failure -- certificate permissions or PRT issue prevented recovery key upload.'; Route = 'Run BL005 BLEscrowCheck' }
    '0x80310030' = @{ Name = 'FVE_E_NOT_FOUND'; Meaning = 'TPM not found -- hardware not detected or not enabled in BIOS/UEFI firmware.'; Route = 'Run BL002 BLTpmHealth (check BIOS settings)' }
    '0x80310019' = @{ Name = 'FVE_E_NOT_ALLOWED'; Meaning = 'Volume cannot be encrypted -- wrong partition type, dynamic disk, or unsupported volume configuration.'; Route = 'Run BL003 BLHardwarePrereqs' }
    '0x8031006E' = @{ Name = 'FVE_E_BUSY'; Meaning = 'BitLocker is already performing an encryption or decryption operation on this volume.'; Route = 'Wait for current operation or cancel with manage-bde -pause' }
    '0x8031000A' = @{ Name = 'FVE_E_AD_SCHEMA_NOT_INSTALLED'; Meaning = 'AD DS forest lacks BitLocker schema extensions -- recovery keys cannot be stored in Active Directory.'; Route = 'Escalate to Domain Admins -- they must extend the AD schema for BitLocker (not an endpoint issue)' }
    '0x80280803' = @{ Name = 'TPM_E_DEFEND_LOCK_RUNNING'; Meaning = 'TPM dictionary attack lockout is active -- the TPM is refusing all auth commands until the timeout expires.'; Route = 'Run BL002 BLTpmHealth (leave system powered on until lockout expires)' }
    '0x8004100E' = @{ Name = 'WBEM_E_INVALID_NAMESPACE'; Meaning = 'WMI namespace ROOT\CIMV2\Security\MicrosoftVolumeEncryption is missing or corrupted -- no programmatic BitLocker control possible.'; Route = 'Rebuild WMI repository: winmgmt /resetrepository (disruptive -- schedule maintenance window)' }
    '0x80090030' = @{ Name = 'NTE_DEVICE_NOT_READY'; Meaning = 'TPM device not ready -- management console failed to load. Suspected hardware/firmware issue (common on TPM 1.2).'; Route = 'Run BL002 BLTpmHealth (consider firmware update or TPM 2.0 switch)' }
    '0x80090016' = @{ Name = 'NTE_BAD_KEYSET'; Meaning = 'TPM operation failed or was invalid -- keyset missing or sysprep image corrupted.'; Route = 'If joined to Entra, re-image the computer without joining Entra ID beforehand' }
    '0x80290407' = @{ Name = 'TPM_E_PCP_INTERNAL_ERROR'; Meaning = 'Generic TPM PCP error -- often blocks Hybrid Entra join or PRT logic.'; Route = 'Run BL002 BLTpmHealth (clear TPM or disable/reenable if persistent)' }
    '0x80290300' = @{ Name = 'TPM_E_PPI_OPERATION_FAILED'; Meaning = 'Error acquiring BIOS response to a Physical Presence Interface (PPI) command (e.g., clearing the TPM from Windows).'; Route = 'Enable "RESET of TPM from OS" and "OS Management of TPM" in the device BIOS/UEFI security settings.' }
    '0x80280036' = @{ Name = 'TPM_E_NOTFIPS'; Meaning = 'FIPS mode of the TPM is currently not supported.'; Route = 'Check FIPS Group Policy or disable TPM temporarily during Entra join' }
    '0x80090031' = @{ Name = 'NTE_AUTHENTICATION_IGNORED'; Meaning = 'TPM is locked out -- transient error during Anti-hammering cooldown.'; Route = 'Wait for lockout cooldown period to expire' }
    '0x80070005' = @{ Name = 'E_ACCESSDENIED'; Meaning = 'Access Denied -- failed to backup TPM Owner Auth to AD DS. msTPM-TPMInformationForComputer lacks SELF Write/Read permission.'; Route = 'Use dsacls.exe to grant NTAUTHORITY\SELF Write/Read permissions to the computer object in AD' }
    '0x80072030' = @{ Name = 'ERROR_DS_NO_SUCH_OBJECT'; Meaning = 'No such object on the server -- failed to backup TPM info to AD DS because Schema/Forest functional level is out of date or missing ACEs.'; Route = 'Escalate to Domain Admins to upgrade forest functional level minimum 2012 R2 or run Add-TPMSelfWriteACE.vbs' }
    '0x800423f4' = @{ Name = 'VSS_E_WRITERERROR_NONRETRYABLE'; Meaning = 'VSS snapshot failed -- the VSS writer attempted to snapshot a BitLocker encrypted volume but timed out or lacked unencrypted access.'; Route = 'If this is a virtualized Domain Controller, configure the backup software to suspend BitLocker during the snapshot, or use Windows Server Backup natively inside the guest.' }
    '0xc0210000' = @{ Name = 'STATUS_FVE_LOCKED_VOLUME'; Meaning = 'Volume is locked -- VSS snapshot of a DC failed, OR a TPM 1.2 device with VBS/Credential Guard attempted Secure Launch.'; Route = 'If a VM Domain Controller: Pause BitLocker before snapshots. If TPM 1.2 physical machine: VBS Secure Launch is unsupported on TPM 1.2 and must be disabled.' }
}

# Collected HRESULTs from events
$observedHresults = @{}

# ============================================================
# Event ID significance map (for timeline annotations)
# ============================================================
$eventAnnotations = @{
    768  = @{ Verdict = 'INFO'; Summary = 'Encryption commenced' }
    770  = @{ Verdict = 'WARN'; Summary = 'Decryption commenced' }
    771  = @{ Verdict = 'INFO'; Summary = 'Decryption completed' }
    773  = @{ Verdict = 'WARN'; Summary = 'Protection suspended' }
    775  = @{ Verdict = 'OK';   Summary = 'Key protector generated' }
    778  = @{ Verdict = 'ISSUE'; Summary = 'Encryption ROLLED BACK -- volume reverted to unprotected' }
    796  = @{ Verdict = 'OK';   Summary = 'Hardware assessment passed (software encryption)' }
    817  = @{ Verdict = 'OK';   Summary = 'Volume master key sealed to TPM' }
    834  = @{ Verdict = 'ISSUE'; Summary = 'TCG log invalid -- Secure Boot integrity failure' }
    835  = @{ Verdict = 'ISSUE'; Summary = 'TCG log invalid -- Secure Boot integrity failure' }
    845  = @{ Verdict = 'OK';   Summary = 'Recovery key escrowed to Entra ID (detail: BL005)' }
    846  = @{ Verdict = 'ISSUE'; Summary = 'Escrow to Entra ID FAILED (detail: BL005)' }
    851  = @{ Verdict = 'ISSUE'; Summary = 'Silent encryption FAILED -- policy conflict or prereq missing' }
    853  = @{ Verdict = 'ISSUE'; Summary = 'TPM not found or bootable media detected -- encryption blocked' }
    854  = @{ Verdict = 'ISSUE'; Summary = 'WinRE not configured -- silent encryption blocked' }
    858  = @{ Verdict = 'WARN'; Summary = 'Recovery key rotation failed (detail: BL005)' }
    1026 = @{ Verdict = 'ISSUE'; Summary = 'TPM dictionary attack lockout -- hardware timeout active' }
}

# ============================================================
# Helper: Extract HRESULTs from event message
# ============================================================
function Extract-HResults {
    param([string]$Message)
    $found = [regex]::Matches($Message, '0x[0-9A-Fa-f]{8}')
    $results = @()
    foreach ($m in $found) {
        $code = '0x' + $m.Value.Substring(2).ToUpper()
        if ($results -notcontains $code) {
            $results += $code
        }
    }
    return $results
}

# ============================================================
# Helper: Get event message safely
# ============================================================
function Get-SafeMessage {
    param($Event)
    $msg = $Event.Message
    if (-not $msg) {
        try { $msg = $Event.FormatDescription() } catch { $msg = '' }
    }
    if (-not $msg) { $msg = '' }
    return $msg
}

# ============================================================
# Helper: Add event to timeline
# ============================================================
function Add-TimelineEvent {
    param(
        [datetime]$Timestamp,
        [string]$Source,
        [int]$EventId,
        [string]$Summary,
        [string]$Verdict,
        [string[]]$HResults
    )
    $allTimelineEvents.Add([PSCustomObject]@{
        Timestamp = $Timestamp
        Source    = $Source
        EventId  = $EventId
        Summary  = $Summary
        Verdict  = $Verdict
        HResults = $HResults
    })
}

# ============================================================
# Section 1: BitLocker Management Log (encryption lifecycle)
# ============================================================
$mgmtLogName = 'Microsoft-Windows-BitLocker-API/Management'
$mgmtEventIds = @(768, 770, 771, 773, 775, 778, 796, 817, 834, 835, 845, 846, 851, 853, 854, 858)
$mgmtEvents = @()
$mgmtAvailable = $true

try {
    $xpathMgmt = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs] and ($(($mgmtEventIds | ForEach-Object { "EventID=$_" }) -join ' or '))]]"
    $mgmtEvents = @(Get-WinEvent -LogName $mgmtLogName -FilterXPath $xpathMgmt -ErrorAction Stop)
} catch {
    $fqeid = $_.FullyQualifiedErrorId
    if ($fqeid -eq 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand') {
        $findings.Add([PSCustomObject]@{
            Check  = 'Management Log Events'
            Status = 'INFO'
            Detail = "No BitLocker management events found in the last $daysBack day(s)."
        })
    } elseif ($fqeid -like '*EventLogNotFoundException*') {
        $mgmtAvailable = $false
        $findings.Add([PSCustomObject]@{
            Check  = 'Management Log'
            Status = 'WARN'
            Detail = "BitLocker Management log channel not available on this build. This may indicate BitLocker feature is not installed."
        })
    } else {
        $findings.Add([PSCustomObject]@{
            Check  = 'Management Log'
            Status = 'WARN'
            Detail = "Failed to query Management log: $($_.Exception.Message)"
        })
    }
}

# Process management events
$criticalMgmt = 0
$warnMgmt = 0

foreach ($evt in $mgmtEvents) {
    $msg = Get-SafeMessage -Event $evt
    $codes = Extract-HResults -Message $msg
    foreach ($c in $codes) { $observedHresults[$c] = $true }

    # Determine annotation
    $annotation = $null
    if ($eventAnnotations.ContainsKey($evt.Id)) {
        $annotation = $eventAnnotations[$evt.Id]
    }

    $verdict = if ($annotation) { $annotation.Verdict } else { 'INFO' }
    $summary = if ($annotation) { $annotation.Summary } else { "Event $($evt.Id)" }

    # Extract extra context from message for key events
    $extraContext = ''
    switch ($evt.Id) {
        768 {
            # Encryption started -- try to extract cipher and volume
            if ($msg -match 'volume\s+([A-Z]:)') { $extraContext = " Volume: $($Matches[1])" }
            if ($msg -match '(XTS-AES.?\d+|AES-CBC.?\d+|AES.\d+)') { $extraContext += " Cipher: $($Matches[1])" }
        }
        775 {
            # Key protector -- try to extract type
            if ($msg -match '(TPM|RecoveryPassword|NumericalPassword|ExternalKey|StartupKey)') { 
                $extraContext = " Type: $($Matches[1])" 
            }
        }
        817 {
            # TPM seal -- try to extract PCR values
            if ($msg -match 'PCR\s*[:\[]?\s*([0-9,\s]+)') { $extraContext = " PCRs: $($Matches[1].Trim())" }
        }
        773 {
            # Suspension -- best-effort context extraction (may not match on non-English OS)
            if ($msg -match 'reboot|update|firmware|bios') { $extraContext = ' (likely auto-suspend for update)' }
        }
        851 {
            # Silent encryption failed -- best-effort context (Event ID is the real diagnostic)
            if ($msg -match 'Group Policy') { $extraContext = ' (Group Policy conflict detected)' }
            if ($msg -match 'WinRE|recovery environment') { $extraContext = ' (WinRE prerequisite missing)' }
        }
    }

    if ($extraContext) { $summary = $summary + $extraContext }

    # Add HRESULT context if any
    if ($codes.Count -gt 0) {
        $summary = $summary + " [Error: $($codes -join ', ')]"
    }

    Add-TimelineEvent -Timestamp $evt.TimeCreated -Source 'Mgmt' -EventId $evt.Id -Summary $summary -Verdict $verdict -HResults $codes

    if ($verdict -eq 'ISSUE') { $criticalMgmt++ }
    if ($verdict -eq 'WARN') { $warnMgmt++ }
}

if ($mgmtEvents.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Management Log Summary'
        Status = if ($criticalMgmt -gt 0) { 'ISSUE' } elseif ($warnMgmt -gt 0) { 'WARN' } else { 'OK' }
        Detail = "$($mgmtEvents.Count) management event(s) in the last $daysBack day(s): $criticalMgmt critical, $warnMgmt warning."
    })
}

# ============================================================
# Section 1b: BitLocker Operational Log (API/driver errors)
# ============================================================
$opLogName = 'Microsoft-Windows-BitLocker-API/Operational'
$opEvents = @()

try {
    $xpathOp = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs]]]"
    $opEvents = @(Get-WinEvent -LogName $opLogName -FilterXPath $xpathOp -MaxEvents 50 -ErrorAction Stop)
} catch {
    $fqeid = $_.FullyQualifiedErrorId
    if ($fqeid -ne 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand') {
        if ($fqeid -like '*EventLogNotFoundException*') {
            # Channel may not exist -- graceful skip
        } else {
            $findings.Add([PSCustomObject]@{
                Check  = 'Operational Log'
                Status = 'INFO'
                Detail = "Could not query BitLocker Operational log: $($_.Exception.Message)"
            })
        }
    }
}

$criticalOp = 0
foreach ($evt in $opEvents) {
    $msg = Get-SafeMessage -Event $evt
    $codes = Extract-HResults -Message $msg

    # Skip events with no useful content
    if (-not $msg -and $codes.Count -eq 0) { continue }

    foreach ($c in $codes) { $observedHresults[$c] = $true }

    # Check for known annotations, otherwise classify by level
    $annotation = $null
    if ($eventAnnotations.ContainsKey($evt.Id)) {
        $annotation = $eventAnnotations[$evt.Id]
    }

    $verdict = 'INFO'
    $summary = ''

    if ($annotation) {
        $verdict = $annotation.Verdict
        $summary = $annotation.Summary
    } else {
        # Classify by event level: 1=Critical, 2=Error, 3=Warning, 4=Info
        $level = $evt.Level
        if ($level -le 2) {
            $verdict = 'ISSUE'
            $criticalOp++
        } elseif ($level -eq 3) {
            $verdict = 'WARN'
        }
        # Build summary from message
        $truncMsg = $msg
        if ($truncMsg.Length -gt 150) { $truncMsg = $truncMsg.Substring(0, 150) + '...' }
        $truncMsg = $truncMsg -replace '[\r\n]+', ' '
        $summary = "Event $($evt.Id): $truncMsg"
    }

    if ($codes.Count -gt 0 -and $summary -notmatch 'Error:') {
        $summary = $summary + " [Error: $($codes -join ', ')]"
    }

    Add-TimelineEvent -Timestamp $evt.TimeCreated -Source 'Oper' -EventId $evt.Id -Summary $summary -Verdict $verdict -HResults $codes
}

if ($opEvents.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Operational Log Summary'
        Status = if ($criticalOp -gt 0) { 'WARN' } else { 'INFO' }
        Detail = "$($opEvents.Count) operational event(s). $criticalOp error-level or critical event(s)."
    })
}

# ============================================================
# Section 1c: System Log -- TPM Events
# ============================================================
$tpmSources = @('TPM', 'TPM-WMI', 'Microsoft-Windows-TPM-WMI')
$tpmEvents = @()

try {
    $sourceFilter = ($tpmSources | ForEach-Object { "Provider[@Name='$_']" }) -join ' or '
    $xpathTpm = "*[System[($sourceFilter) and TimeCreated[timediff(@SystemTime) <= $cutoffMs]]]"
    $tpmEvents = @(Get-WinEvent -LogName 'System' -FilterXPath $xpathTpm -MaxEvents 30 -ErrorAction Stop)
} catch {
    $fqeid = $_.FullyQualifiedErrorId
    if ($fqeid -ne 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand') {
        $findings.Add([PSCustomObject]@{
            Check  = 'System TPM Events'
            Status = 'INFO'
            Detail = "Could not query System log for TPM events: $($_.Exception.Message)"
        })
    }
}

$criticalTpm = 0
foreach ($evt in $tpmEvents) {
    $msg = Get-SafeMessage -Event $evt
    $codes = Extract-HResults -Message $msg
    foreach ($c in $codes) { $observedHresults[$c] = $true }

    $annotation = $null
    if ($eventAnnotations.ContainsKey($evt.Id)) {
        $annotation = $eventAnnotations[$evt.Id]
    }

    $verdict = 'INFO'
    $summary = ''

    if ($annotation) {
        $verdict = $annotation.Verdict
        $summary = $annotation.Summary
    } else {
        $level = $evt.Level
        if ($level -le 2) {
            $verdict = 'ISSUE'
            $criticalTpm++
        } elseif ($level -eq 3) {
            $verdict = 'WARN'
        }
        $truncMsg = $msg
        if ($truncMsg.Length -gt 150) { $truncMsg = $truncMsg.Substring(0, 150) + '...' }
        $truncMsg = $truncMsg -replace '[\r\n]+', ' '
        $summary = "TPM Event $($evt.Id): $truncMsg"
    }

    if ($codes.Count -gt 0 -and $summary -notmatch 'Error:') {
        $summary = $summary + " [Error: $($codes -join ', ')]"
    }

    Add-TimelineEvent -Timestamp $evt.TimeCreated -Source 'TPM' -EventId $evt.Id -Summary $summary -Verdict $verdict -HResults $codes
}

if ($tpmEvents.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'System TPM Events'
        Status = if ($criticalTpm -gt 0) { 'ISSUE' } else { 'INFO' }
        Detail = "$($tpmEvents.Count) TPM event(s) in System log. $criticalTpm error-level or critical."
    })
}

# ============================================================
# Section 1d: DrivePreparationTool Log (if available)
# ============================================================
$dpLogName = 'Microsoft-Windows-BitLocker-DrivePreparationTool/Operational'
$dpEvents = @()

try {
    $xpathDp = "*[System[TimeCreated[timediff(@SystemTime) <= $cutoffMs]]]"
    $dpEvents = @(Get-WinEvent -LogName $dpLogName -FilterXPath $xpathDp -MaxEvents 20 -ErrorAction Stop)
} catch {
    # Channel may not exist on all builds -- graceful skip
}

if ($dpEvents.Count -gt 0) {
    $findings.Add([PSCustomObject]@{
        Check  = 'Drive Preparation Tool'
        Status = 'INFO'
        Detail = "$($dpEvents.Count) event(s) from DrivePreparationTool log (partition preparation for encryption)."
    })

    foreach ($evt in $dpEvents) {
        $msg = Get-SafeMessage -Event $evt
        $codes = Extract-HResults -Message $msg
        foreach ($c in $codes) { $observedHresults[$c] = $true }

        $verdict = 'INFO'
        $level = $evt.Level
        if ($level -le 2) { $verdict = 'ISSUE' }
        elseif ($level -eq 3) { $verdict = 'WARN' }

        $truncMsg = $msg
        if ($truncMsg.Length -gt 150) { $truncMsg = $truncMsg.Substring(0, 150) + '...' }
        $truncMsg = $truncMsg -replace '[\r\n]+', ' '
        $summary = "DrivePrep Event $($evt.Id): $truncMsg"

        if ($codes.Count -gt 0) {
            $summary = $summary + " [Error: $($codes -join ', ')]"
        }

        Add-TimelineEvent -Timestamp $evt.TimeCreated -Source 'DPrep' -EventId $evt.Id -Summary $summary -Verdict $verdict -HResults $codes
    }
}

# ============================================================
# Output Section 1: Chronological Timeline
# ============================================================
Write-Output ''
Write-Output '--- Event Timeline ---'

$totalEvents = $allTimelineEvents.Count
if ($totalEvents -eq 0) {
    Write-Output '[i]   No BitLocker or TPM events found in the last ' -NoNewline
    Write-Output "$daysBack day(s)."
    Write-Output '       This endpoint may not have BitLocker configured, or event logs may have been cleared.'
    $findings.Add([PSCustomObject]@{
        Check  = 'Event Timeline'
        Status = 'INFO'
        Detail = "No BitLocker or TPM events found in the last $daysBack day(s). Endpoint may not have BitLocker configured or logs may be cleared."
    })
} else {
    # Sort chronologically (most recent first)
    $sorted = $allTimelineEvents | Sort-Object -Property Timestamp -Descending

    $totalCritical = @($sorted | Where-Object { $_.Verdict -eq 'ISSUE' }).Count
    $totalWarn = @($sorted | Where-Object { $_.Verdict -eq 'WARN' }).Count

    Write-Output "[i]   $totalEvents event(s) found across all log channels."
    if ($totalCritical -gt 0 -or $totalWarn -gt 0) {
        Write-Output "       $totalCritical critical issue(s) and $totalWarn warning(s) detected."
    }
    Write-Output ''

    # Display up to 40 most recent events
    $showCount = [Math]::Min($sorted.Count, 40)
    for ($i = 0; $i -lt $showCount; $i++) {
        $te = $sorted[$i]
        $icon = switch ($te.Verdict) {
            'OK'    { '[OK]  ' }
            'ISSUE' { '[!!]  ' }
            'WARN'  { '[!]   ' }
            'INFO'  { '[i]   ' }
            default { "[$($te.Verdict)] " }
        }
        $ts = $te.Timestamp.ToString('yyyy-MM-dd HH:mm')
        $src = "[$($te.Source)]".PadRight(7)
        Write-Output "$icon$ts  $src  $($te.Summary)"
    }

    if ($sorted.Count -gt 40) {
        Write-Output "[i]   ... and $($sorted.Count - 40) more event(s) not shown. Increase DaysBack or check Event Viewer."
    }

    $findings.Add([PSCustomObject]@{
        Check  = 'Event Timeline'
        Status = if ($totalCritical -gt 0) { 'ISSUE' } elseif ($totalWarn -gt 0) { 'WARN' } else { 'OK' }
        Detail = "$totalEvents event(s): $totalCritical critical, $totalWarn warning(s)."
    })
}

# ============================================================
# Output Section 2: HRESULT Error Code Summary
# ============================================================
Write-Output ''
Write-Output '--- Error Code Summary ---'

if ($observedHresults.Keys.Count -gt 0) {
    Write-Output "[!]   $($observedHresults.Keys.Count) unique HRESULT code(s) extracted from events."
    Write-Output ''

    $findings.Add([PSCustomObject]@{
        Check  = 'Error Codes Observed'
        Status = 'WARN'
        Detail = "$($observedHresults.Keys.Count) unique HRESULT code(s) extracted from events."
    })

    foreach ($code in ($observedHresults.Keys | Sort-Object)) {
        if ($hresultMap.ContainsKey($code)) {
            $entry = $hresultMap[$code]
            $routeStr = ''
            if ($entry.Route) { $routeStr = " --> $($entry.Route)" }
            Write-Output "[!]   $code ($($entry.Name))"
            Write-Output "       $($entry.Meaning)$routeStr"
            $findings.Add([PSCustomObject]@{
                Check  = "  $code ($($entry.Name))"
                Status = 'WARN'
                Detail = "$($entry.Meaning)$routeStr"
            })
        } else {
            Write-Output "[i]   $code"
            Write-Output '       Unknown HRESULT. Not in the embedded translation table. Search Microsoft documentation.'
            $findings.Add([PSCustomObject]@{
                Check  = "  $code"
                Status = 'INFO'
                Detail = 'Unknown HRESULT. Not in the embedded translation table.'
            })
        }
    }
} else {
    Write-Output '[OK]  No HRESULT error codes extracted from events. No known error conditions.'
    $findings.Add([PSCustomObject]@{
        Check  = 'Error Codes'
        Status = 'OK'
        Detail = 'No HRESULT error codes extracted from events.'
    })
}

# ============================================================
# Summary and NEXT footer
# ============================================================
Write-Output ''
Write-Output '--- Summary ---'

$issueCount = @($findings | Where-Object { $_.Status -eq 'ISSUE' }).Count
$warnCount  = @($findings | Where-Object { $_.Status -eq 'WARN' }).Count

if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected in BitLocker event timeline.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items marked [!!] above."
}

Write-Output ''
Write-Output 'NEXT:   Address the most common error code listed above.'
Write-Output '        If escrow failures (Event 846)    -> run BL005 BLEscrowCheck'
Write-Output '        If GPO conflicts (Event 851)      -> run BL006 BLPolicyConflict'
Write-Output '        If TPM issues (Event 853/1026)    -> run BL002 BLTpmHealth'
Write-Output '        If hardware/partition errors       -> run BL003 BLHardwarePrereqs'
Write-Output '        If WinRE missing (Event 854)       -> reagentc /enable'
Write-Output '        If protection suspended (Event 773) -> verify protection resumed: manage-bde -protectors -enable C:'
Write-Output ''
