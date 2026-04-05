# BL005_BLEscrowCheck.ps1
# Scriptlet: BL005 - Recovery Key Escrow Diagnostics
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Recovery Key Escrow Diagnostics ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Check 1: Escrow Policy Requirements
# ---------------------------------------------------------------
Write-Output '--- Escrow Policy Requirements ---'

$fvePath = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'

$osRequireBackup = $null
try {
    $fveItem = Get-ItemProperty -Path $fvePath -Name 'OSRequireActiveDirectoryBackup' -ErrorAction Stop
    if ($null -ne $fveItem) { $osRequireBackup = $fveItem.OSRequireActiveDirectoryBackup }
} catch { }

$escrowGateActive = $false
if ($null -ne $osRequireBackup -and $osRequireBackup -eq 1) {
    $escrowGateActive = $true
    Write-Output '[i]   Escrow Policy: OSRequireActiveDirectoryBackup = 1'
    Write-Output '       Encryption will NOT begin until the recovery key is backed up to AD/AAD.'
    Write-Output '       If escrow fails, encryption is blocked indefinitely.'
} elseif ($null -ne $osRequireBackup -and $osRequireBackup -eq 0) {
    Write-Output '[OK]  Escrow Policy: OSRequireActiveDirectoryBackup = 0'
    Write-Output '       Backup not required for encryption to proceed. Encryption can start without escrow.'
} else {
    Write-Output '[OK]  Escrow Policy: OSRequireActiveDirectoryBackup'
    Write-Output '       Not set. Default behavior -- encryption can proceed without mandatory backup.'
}

# Check FDV (Fixed Data Volume) requirement
$fdvRequireBackup = $null
try {
    $fveItem2 = Get-ItemProperty -Path $fvePath -Name 'FDVRequireActiveDirectoryBackup' -ErrorAction Stop
    if ($null -ne $fveItem2) { $fdvRequireBackup = $fveItem2.FDVRequireActiveDirectoryBackup }
} catch { }

if ($null -ne $fdvRequireBackup -and $fdvRequireBackup -eq 1) {
    Write-Output '[i]   Fixed Data Volumes: FDVRequireActiveDirectoryBackup = 1'
    Write-Output '       Fixed data drives also require backup before encryption.'
}

# Check what gets stored
$infoToStore = $null
try {
    $fveItem3 = Get-ItemProperty -Path $fvePath -Name 'OSActiveDirectoryInfoToStore' -ErrorAction Stop
    if ($null -ne $fveItem3) { $infoToStore = $fveItem3.OSActiveDirectoryInfoToStore }
} catch { }

if ($null -ne $infoToStore) {
    $storeDesc = switch ([int]$infoToStore) {
        1 { 'Recovery passwords AND key packages (forensic recovery capable)' }
        2 { 'Recovery passwords only' }
        default { "Value: $infoToStore" }
    }
    Write-Output "[i]   Escrow Content: OSActiveDirectoryInfoToStore = $infoToStore"
    Write-Output "       $storeDesc"
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: AAD Device Registration & Identity Health
# ---------------------------------------------------------------
Write-Output '--- AAD Device Registration & Identity Health ---'

$dsregOutput = $null
try {
    $dsregOutput = & dsregcmd.exe /status 2>&1 | Out-String
    # Strip ANSI/VT escape sequences -- dsregcmd on Win 11 emits VT codes that clear the console
    if ($dsregOutput) { $dsregOutput = $dsregOutput -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
} catch { }

if ([string]::IsNullOrEmpty($dsregOutput)) {
    Write-Output '[!!]  dsregcmd.exe /status'
    Write-Output '       Failed to execute dsregcmd or no output returned.'
    Write-Output '       Cannot validate device identity for escrow.'
    $issueCount++
} else {
    # Parse relevant fields
    $azureAdJoined = $null
    $azureAdPrt = $null
    $deviceAuthStatus = $null
    $tpmProtected = $null
    $tenantId = $null

    foreach ($line in $dsregOutput -split "`n") {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*AzureAdJoined\s*:\s*(.+)$') { $azureAdJoined = $Matches[1].Trim() }
        if ($trimmed -match '^\s*AzureAdPrt\s*:\s*(.+)$') { $azureAdPrt = $Matches[1].Trim() }
        if ($trimmed -match '^\s*DeviceAuthStatus\s*:\s*(.+)$') { $deviceAuthStatus = $Matches[1].Trim() }
        if ($trimmed -match '^\s*TpmProtected\s*:\s*(.+)$') { $tpmProtected = $Matches[1].Trim() }
        if ($trimmed -match '^\s*TenantId\s*:\s*(.+)$') {
            if ($null -eq $tenantId) { $tenantId = $Matches[1].Trim() }
        }
    }

    # AzureAdJoined
    if ($azureAdJoined -eq 'YES') {
        Write-Output '[OK]  AzureAdJoined: YES'
        Write-Output '       Device is joined to Entra ID. Cloud escrow is structurally possible.'
    } elseif ($azureAdJoined -eq 'NO') {
        Write-Output '[!!]  AzureAdJoined: NO'
        Write-Output '       Device is NOT joined to Entra ID. Cloud escrow to AAD is impossible.'
        Write-Output '       The device must be Entra ID joined or Hybrid joined for AAD escrow.'
        $issueCount++
    } else {
        Write-Output '[!]   AzureAdJoined: Could not determine'
        Write-Output '       dsregcmd did not return AzureAdJoined field.'
        $warnCount++
    }

    # AzureAdPrt (Primary Refresh Token)
    if ($azureAdPrt -eq 'YES') {
        Write-Output '[OK]  AzureAdPrt: YES'
        Write-Output '       Primary Refresh Token is present. Background auth to AAD will work.'
    } elseif ($azureAdPrt -eq 'NO') {
        Write-Output '[!!]  AzureAdPrt: NO'
        Write-Output '       Primary Refresh Token is MISSING. Background authentication to AAD'
        Write-Output '       will fail. Escrow transmissions will be rejected by the cloud STS.'
        Write-Output '       Try: dsregcmd /refreshprt or sign out and back in.'
        $issueCount++
    } else {
        Write-Output '[i]   AzureAdPrt: Not found in dsregcmd output'
        Write-Output '       PRT status could not be determined. May require a user to be signed in.'
    }

    # DeviceAuthStatus (zombie detection)
    if ($null -ne $deviceAuthStatus) {
        if ($deviceAuthStatus -match 'SUCCESS') {
            Write-Output '[OK]  DeviceAuthStatus: SUCCESS'
            Write-Output '       Device can authenticate to Entra ID. Identity is healthy.'
        } elseif ($deviceAuthStatus -match 'FAILED') {
            Write-Output '[!!]  DeviceAuthStatus: FAILED -- ZOMBIE STATE DETECTED'
            Write-Output "       Status: $deviceAuthStatus"
            Write-Output '       The device believes it is Entra joined, but its tokens are rejected.'
            Write-Output '       Escrow will fail because the cloud rejects this device identity.'
            Write-Output '       Fix: Run dsregcmd /leave then dsregcmd /join to re-establish trust.'
            $issueCount++
        } else {
            Write-Output "[i]   DeviceAuthStatus: $deviceAuthStatus"
        }
    }

    # TpmProtected
    if ($tpmProtected -eq 'YES') {
        Write-Output '[OK]  TpmProtected: YES'
        Write-Output '       Device identity key is stored in hardware TPM. Secure.'
    } elseif ($tpmProtected -eq 'NO') {
        Write-Output '[!]   TpmProtected: NO'
        Write-Output '       Device identity key is software-backed, not in TPM.'
        Write-Output '       Some conditional access policies may reject software-backed keys.'
        $warnCount++
    }

    # TenantId
    if (-not [string]::IsNullOrEmpty($tenantId)) {
        Write-Output "[i]   TenantId: $tenantId"
        Write-Output '       Escrow will target this Entra ID tenant.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: Escrow Event History (Last 7 Days)
# ---------------------------------------------------------------
Write-Output '--- Escrow Event History (Last 7 Days) ---'

$logName = 'Microsoft-Windows-BitLocker/BitLocker Management'
$escrowEventIds = @(845, 846, 851, 858, 778)
$startTime = (Get-Date).AddDays(-7)

$hresultTable = @{
    '0x80072f9a' = 'SYSTEM lacks cert access or SSL inspection breaking Entra authentication'
    '0x80310059' = 'Overlapping operation -- GPO/MDM collision or filter driver interference'
    '0x80072efe' = 'Connection aborted -- firewall, VPN, or proxy dropped the escrow payload'
    '0x8007054b' = 'DNS failure -- cannot resolve Entra ID endpoint'
    '0x80310018' = 'TPM not owned -- cannot generate Volume Master Key'
    '0x803100b5' = 'No pre-boot keyboard or WinRE missing -- slate device block'
}

$escrowEvents = $null
try {
    $filter = @{
        LogName   = $logName
        Id        = $escrowEventIds
        StartTime = $startTime
    }
    $escrowEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        $escrowEvents = @()
    }
}

if ($null -eq $escrowEvents) {
    Write-Output '[i]   Escrow Events'
    Write-Output '       Could not query BitLocker Management event log.'
    Write-Output '       The log may not exist or may be inaccessible.'
} elseif ($escrowEvents.Count -eq 0) {
    Write-Output '[i]   Escrow Events: None found in the last 7 days'
    Write-Output '       No escrow success, failure, or rollback events detected.'
    Write-Output '       Escrow may never have been attempted on this machine.'
} else {
    $successes = @($escrowEvents | Where-Object { $_.Id -eq 845 })
    $failures  = @($escrowEvents | Where-Object { $_.Id -eq 846 })
    $silentFail = @($escrowEvents | Where-Object { $_.Id -eq 851 })
    $rotationFail = @($escrowEvents | Where-Object { $_.Id -eq 858 })
    $rollbacks = @($escrowEvents | Where-Object { $_.Id -eq 778 })

    # Report successes
    if ($successes.Count -gt 0) {
        $latest = $successes[0]
        $ts = $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')
        Write-Output "[OK]  Escrow Success (Event 845): $($successes.Count) in last 7 days"
        Write-Output "       Last successful escrow: $ts."
        Write-Output '       Recovery key was backed up to Entra ID.'
    }

    # Report failures
    if ($failures.Count -gt 0) {
        $latest = $failures[0]
        $ts = $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')
        $msg = "$($latest.Message)"

        # Extract HRESULT from message
        $hresult = ''
        if ($msg -match '(0x[0-9a-fA-F]{8})') {
            $hresult = $Matches[1].ToLower()
        }

        Write-Output "[!!]  Escrow FAILED (Event 846): $($failures.Count) failure(s) in last 7 days"
        Write-Output "       Last failure: $ts."
        if (-not [string]::IsNullOrEmpty($hresult)) {
            $translation = 'Unknown HRESULT'
            if ($hresultTable.ContainsKey($hresult)) {
                $translation = $hresultTable[$hresult]
            }
            Write-Output "       HRESULT: $hresult -- $translation"
        }
        $issueCount++

        if ($escrowGateActive) {
            Write-Output '[!!]  CRITICAL: Escrow gate is active (OSRequireActiveDirectoryBackup = 1)'
            Write-Output '       Encryption is architecturally BLOCKED. It will never start until'
            Write-Output '       the escrow succeeds. Fix the escrow failure first.'
            $issueCount++
        }
    }

    # Report silent encryption failures
    if ($silentFail.Count -gt 0) {
        $latest = $silentFail[0]
        $ts = $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')
        Write-Output "[!!]  Silent Encryption Failed (Event 851): $($silentFail.Count) in last 7 days"
        Write-Output "       Last failure: $ts."
        Write-Output '       Silent encryption could not activate. Often a downstream result of'
        Write-Output '       escrow failure (846) combined with the OSRequireActiveDirectoryBackup gate.'
        $issueCount++
    }

    # Report rotation failures
    if ($rotationFail.Count -gt 0) {
        $latest = $rotationFail[0]
        $ts = $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')
        Write-Output "[!]   Key Rotation Failed (Event 858): $($rotationFail.Count) in last 7 days"
        Write-Output "       Last failure: $ts."
        Write-Output '       MDM attempted to rotate the recovery key but the device was not ready.'
        Write-Output '       Common causes: network unavailable, WinRE missing, policy misconfigured.'
        $warnCount++
    }

    # Report rollbacks
    if ($rollbacks.Count -gt 0) {
        $latest = $rollbacks[0]
        $ts = $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')
        Write-Output "[!!]  Volume Rollback (Event 778): $($rollbacks.Count) in last 7 days"
        Write-Output "       Last rollback: $ts."
        Write-Output '       The volume was REVERTED to an unprotected state. Encryption was'
        Write-Output '       rolled back -- likely because escrow failed and policy required it.'
        $issueCount++
    }

    # Repeated failures despite no issues -- hint at 200-key limit
    if ($failures.Count -ge 3 -and $successes.Count -eq 0) {
        Write-Output ''
        Write-Output '[!]   Repeated escrow failures with no successes detected.'
        Write-Output '       If identity and connectivity are healthy, this may indicate the'
        Write-Output '       Entra ID 200-key hard limit has been reached for this device object.'
        Write-Output '       Check the Entra portal: Device > BitLocker keys > delete stale keys.'
        $warnCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: Escrow Endpoint Connectivity
# ---------------------------------------------------------------
Write-Output '--- Escrow Endpoint Connectivity ---'

$endpoints = @(
    @('login.microsoftonline.com',           'OAuth token acquisition for escrow authentication'),
    @('enterpriseregistration.windows.net',   'Device Registration Service -- accepts the key payload'),
    @('device.login.microsoftonline.com',     'Device identity verification and compliance checks')
)

foreach ($ep in $endpoints) {
    $hostname = $ep[0]
    $purpose  = $ep[1]

    $result = $null
    try {
        $result = [System.Net.Sockets.TcpClient]::new()
        $async = $result.BeginConnect($hostname, 443, $null, $null)
        $waited = $async.AsyncWaitHandle.WaitOne(3000, $false)
        if ($waited -and $result.Connected) {
            Write-Output "[OK]  ${hostname}:443 -- Reachable"
            Write-Output "       $purpose"
        } else {
            Write-Output "[!!]  ${hostname}:443 -- UNREACHABLE (timeout)"
            Write-Output "       $purpose"
            Write-Output '       Escrow transmissions to this endpoint will fail from SYSTEM context.'
            $issueCount++
        }
    } catch {
        Write-Output "[!!]  ${hostname}:443 -- UNREACHABLE (error)"
        Write-Output "       $purpose"
        Write-Output "       Error: $($_.Exception.Message)"
        $issueCount++
    } finally {
        if ($null -ne $result) {
            try { $result.Close() } catch { }
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Recovery Key Protector Status
# ---------------------------------------------------------------
Write-Output '--- Recovery Key Protector Status ---'

$osDrive = $env:SystemDrive
if ([string]::IsNullOrEmpty($osDrive)) { $osDrive = 'C:' }

$blVolume = $null
try {
    $blVolume = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop
} catch { }

if ($null -eq $blVolume) {
    Write-Output "[i]   Recovery Key Protectors ($osDrive)"
    Write-Output '       Could not query BitLocker volume. BitLocker may not be available or'
    Write-Output '       the drive is not encrypted. Key protector analysis skipped.'
} else {
    $volStatus = "$($blVolume.VolumeStatus)"
    if ($volStatus -eq 'FullyDecrypted') {
        Write-Output "[i]   Volume $osDrive is not encrypted"
        Write-Output '       Key protectors are not applicable. Encryption has not been enabled.'
    } else {
        $protectors = @($blVolume.KeyProtector)
        $recoveryKeys = @($protectors | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        $otherTypes = @($protectors | Where-Object { $_.KeyProtectorType -ne 'RecoveryPassword' })

        $typeList = ($protectors | ForEach-Object { "$($_.KeyProtectorType)" }) -join ', '
        Write-Output "[i]   Key Protectors on ${osDrive}: $($protectors.Count) total ($typeList)"

        if ($recoveryKeys.Count -eq 0) {
            Write-Output "[!!]  No RecoveryPassword protector found on $osDrive"
            Write-Output '       There is no recovery key to escrow. BitLocker cannot back up'
            Write-Output '       a key that does not exist. A new recovery key must be generated.'
            $issueCount++
        } else {
            # Cross-reference each recovery key GUID with Event 845
            $event845Msgs = @()
            if ($null -ne $escrowEvents) {
                $event845Msgs = @($escrowEvents | Where-Object { $_.Id -eq 845 } | ForEach-Object { "$($_.Message)" })
            }

            foreach ($rk in $recoveryKeys) {
                $guid = "$($rk.KeyProtectorId)"
                # Clean GUID for display (remove braces if present)
                $guidClean = $guid -replace '[{}]', ''

                # Check if this GUID appears in any 845 success event
                $escrowed = $false
                foreach ($msg845 in $event845Msgs) {
                    if ($msg845 -match [regex]::Escape($guidClean)) {
                        $escrowed = $true
                        break
                    }
                    # Also try with braces
                    if ($msg845 -match [regex]::Escape($guid)) {
                        $escrowed = $true
                        break
                    }
                }

                if ($escrowed) {
                    Write-Output "[OK]  RecoveryPassword $guidClean"
                    Write-Output '       Escrow confirmed -- Event 845 found for this key protector.'
                } else {
                    Write-Output "[!]   RecoveryPassword $guidClean"
                    Write-Output '       No escrow confirmation found in last 7 days for this key.'
                    Write-Output '       The key may have been escrowed earlier, or escrow may not have'
                    Write-Output '       been attempted. Check the Entra portal to confirm.'
                    $warnCount++
                }
            }
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 6: WinRE Status (Lightweight)
# ---------------------------------------------------------------
Write-Output '--- WinRE Status ---'

$reagentOutput = $null
try {
    $reagentOutput = & reagentc.exe /info 2>&1 | Out-String
} catch { }

if ([string]::IsNullOrEmpty($reagentOutput)) {
    Write-Output '[!]   WinRE Status: Could not query'
    Write-Output '       reagentc.exe did not return output. WinRE status unknown.'
    Write-Output '       WinRE is required for silent encryption and key rotation.'
    $warnCount++
} else {
    $winreEnabled = $false
    foreach ($line in $reagentOutput -split "`n") {
        $trimmed = $line.Trim()
        if ($trimmed -match 'Windows RE status.*Enabled' -or $trimmed -match 'Windows RE.*Enabled') {
            $winreEnabled = $true
        }
        if ($trimmed -match 'Windows RE status.*Disabled' -or $trimmed -match 'Windows RE.*Disabled') {
            $winreEnabled = $false
        }
    }

    if ($winreEnabled) {
        Write-Output '[OK]  WinRE: Enabled'
        Write-Output '       Windows Recovery Environment is active. Silent encryption and'
        Write-Output '       key rotation prerequisites are met.'
    } else {
        Write-Output '[!!]  WinRE: Disabled or Not Configured'
        Write-Output '       Silent encryption will fail (Event 854) because the OS cannot'
        Write-Output '       guarantee a recovery pathway. Key rotation (Event 858) will also fail.'
        Write-Output '       Fix: reagentc /enable (may require WinRE image at C:\Recovery\WindowsRE).'
        Write-Output '       For deeper analysis, run BL008 BLReadinessCheck.'
        $issueCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No escrow issues detected. Recovery key pipeline appears healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If escrow failed due to connectivity -> fix network (see WU003 WUNetworkCheck)'
Write-Output '        If device registration broken       -> run dsregcmd /leave then re-join'
Write-Output '        If escrow gate active + key missing  -> run BL009 BLTpmRemediation'
Write-Output '        If no escrow events + volume decrypted -> policy may not have triggered -- run BL004'
Write-Output '        If repeated 846 despite healthy state -> check Entra portal for 200-key limit'
Write-Output '        If WinRE disabled                    -> reagentc /enable or run BL008 BLReadinessCheck'
Write-Output ''
