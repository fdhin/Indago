# WU004_WUTlsCertCheck.ps1
# Scriptlet: WU004 - TLS, Certificates & Time Check
# Context: System | Version: 1.2

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== TLS, Certificates & Time Check ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Helper: Read registry value safely
# ---------------------------------------------------------------
function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        if ($null -ne $item -and ($item.PSObject.Properties.Name -contains $Name)) {
            return $item.$Name
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------
# Check 1: Schannel TLS 1.2 Configuration
# ---------------------------------------------------------------
Write-Output '--- Schannel TLS 1.2 Configuration ---'

$schBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'

$tls12Roles = @(
    @{ Role = 'Client'; Path = "$schBase\TLS 1.2\Client" }
    @{ Role = 'Server'; Path = "$schBase\TLS 1.2\Server" }
)

foreach ($role in $tls12Roles) {
    $roleName = $role.Role
    $regPath  = $role.Path

    $keyExists = Test-Path $regPath
    if (-not $keyExists) {
        Write-Output "[OK]  TLS 1.2 $roleName"
        Write-Output '       Subkey not present. OS defaults apply (TLS 1.2 enabled on Windows 10+).'
    } else {
        $enabled = Get-RegVal -Path $regPath -Name 'Enabled'
        $disabled = Get-RegVal -Path $regPath -Name 'DisabledByDefault'

        if ($null -ne $enabled -and $enabled -eq 0) {
            Write-Output "[!!]  TLS 1.2 ${roleName}: DISABLED"
            Write-Output "       Enabled = 0 at $regPath."
            Write-Output '       TLS 1.2 is explicitly disabled. Windows Update CANNOT negotiate with Microsoft endpoints.'
            Write-Output '       Fix: Set Enabled = 1 and DisabledByDefault = 0, then reboot.'
            $issueCount++
        } elseif ($null -ne $disabled -and $disabled -eq 1) {
            Write-Output "[!!]  TLS 1.2 ${roleName}: Disabled By Default"
            Write-Output "       DisabledByDefault = 1 at $regPath."
            Write-Output '       Applications must explicitly opt in to TLS 1.2. WU may not do this.'
            Write-Output '       Fix: Set DisabledByDefault = 0 and Enabled = 1, then reboot.'
            $issueCount++
        } else {
            Write-Output "[OK]  TLS 1.2 $roleName"
            $detail = ''
            if ($null -ne $enabled) { $detail = "Enabled = $enabled" }
            if ($null -ne $disabled) {
                if ($detail.Length -gt 0) { $detail += ', ' }
                $detail += "DisabledByDefault = $disabled"
            }
            if ($detail.Length -eq 0) { $detail = 'Subkey exists with no override values. OS defaults apply.' }
            Write-Output "       $detail. TLS 1.2 is active."
        }
    }
}

# Legacy protocol detection
$legacyProtocols = @(
    @{ Name = 'TLS 1.0'; Path = "$schBase\TLS 1.0\Client" }
    @{ Name = 'SSL 3.0'; Path = "$schBase\SSL 3.0\Client" }
)

$legacyActive = [System.Collections.Generic.List[string]]::new()
foreach ($lp in $legacyProtocols) {
    $lpPath = $lp.Path
    if (Test-Path $lpPath) {
        $lpEnabled = Get-RegVal -Path $lpPath -Name 'Enabled'
        # If subkey exists and Enabled is not explicitly 0, the protocol is active
        if ($null -eq $lpEnabled -or $lpEnabled -ne 0) {
            $null = $legacyActive.Add($lp.Name)
        }
    } else {
        # TLS 1.0 is enabled by default on Win10 if no subkey exists
        if ($lp.Name -eq 'TLS 1.0') {
            $null = $legacyActive.Add('TLS 1.0 (OS default)')
        }
    }
}

if ($legacyActive.Count -gt 0) {
    $legacyStr = $legacyActive -join ', '
    Write-Output "[!]   Legacy Protocols Still Active: $legacyStr"
    Write-Output '       These are not blocking Windows Update but are a security risk.'
    Write-Output '       Consider disabling TLS 1.0 and SSL 3.0 when all applications support TLS 1.2+.'
    $warnCount++
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: .NET Framework TLS Defaults
# ---------------------------------------------------------------
Write-Output '--- .NET Framework TLS Defaults ---'

$dotnetPaths = @(
    @{ Label = '.NET 4.x (64-bit)'; Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' }
    @{ Label = '.NET 4.x (32-bit)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' }
)

foreach ($dnp in $dotnetPaths) {
    $label   = $dnp.Label
    $regPath = $dnp.Path

    if (-not (Test-Path $regPath)) {
        Write-Output "[i]   $label"
        Write-Output "       Registry path not found: $regPath"
        Write-Output '       .NET Framework 4.x may not be installed for this architecture.'
        continue
    }

    $strongCrypto = Get-RegVal -Path $regPath -Name 'SchUseStrongCrypto'
    $sysDefault   = Get-RegVal -Path $regPath -Name 'SystemDefaultTlsVersions'

    $scOk = ($null -ne $strongCrypto -and $strongCrypto -eq 1)
    $sdOk = ($null -ne $sysDefault -and $sysDefault -eq 1)

    if ($scOk -and $sdOk) {
        Write-Output "[OK]  $label"
        Write-Output '       SchUseStrongCrypto = 1, SystemDefaultTlsVersions = 1. Strong crypto active.'
    } elseif ($scOk) {
        Write-Output "[OK]  $label"
        Write-Output '       SchUseStrongCrypto = 1. Strong crypto active.'
        if ($null -eq $sysDefault) {
            Write-Output '       SystemDefaultTlsVersions not set (acceptable if SchUseStrongCrypto is 1).'
        }
    } elseif ($sdOk) {
        Write-Output "[OK]  $label"
        Write-Output '       SystemDefaultTlsVersions = 1. .NET defers to OS default protocols.'
        if ($null -eq $strongCrypto) {
            Write-Output '       SchUseStrongCrypto not set. Consider setting to 1 for defense-in-depth.'
        }
    } else {
        Write-Output "[!!]  $label"
        $scStr = if ($null -eq $strongCrypto) { 'not set' } else { "$strongCrypto" }
        $sdStr = if ($null -eq $sysDefault) { 'not set' } else { "$sysDefault" }
        Write-Output "       SchUseStrongCrypto = $scStr, SystemDefaultTlsVersions = $sdStr."
        Write-Output '       .NET processes using this architecture will default to TLS 1.0 for HTTPS.'
        Write-Output "       Fix: Set SchUseStrongCrypto = 1 (DWORD) at $regPath"
        $issueCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: WinHTTP Default Secure Protocols
# ---------------------------------------------------------------
Write-Output '--- WinHTTP Secure Protocols ---'

$winhttpPaths = @(
    @{ Label = 'WinHTTP (64-bit)'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' }
    @{ Label = 'WinHTTP (32-bit)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' }
)

# Protocol bitmask values
$protoFlags = @(
    @{ Bit = 0x00000800; Name = 'TLS 1.2' }
    @{ Bit = 0x00000200; Name = 'TLS 1.1' }
    @{ Bit = 0x00000080; Name = 'TLS 1.0' }
    @{ Bit = 0x00000020; Name = 'SSL 3.0' }
)

foreach ($whp in $winhttpPaths) {
    $label   = $whp.Label
    $regPath = $whp.Path

    $dsp = Get-RegVal -Path $regPath -Name 'DefaultSecureProtocols'

    if ($null -eq $dsp) {
        Write-Output "[OK]  $label"
        Write-Output '       DefaultSecureProtocols not configured. OS defaults apply (TLS 1.2 included on Win10+).'
    } else {
        $dspInt = [int]$dsp
        $dspHex = '0x{0:X8}' -f $dspInt

        # Decode which protocols are enabled
        $enabled = [System.Collections.Generic.List[string]]::new()
        foreach ($pf in $protoFlags) {
            if (($dspInt -band $pf.Bit) -ne 0) {
                $null = $enabled.Add($pf.Name)
            }
        }

        $hasTls12 = (($dspInt -band 0x00000800) -ne 0)
        $protoStr = if ($enabled.Count -gt 0) { $enabled -join ', ' } else { 'None recognized' }

        if ($hasTls12) {
            Write-Output "[OK]  $label"
            Write-Output "       DefaultSecureProtocols = $dspHex. Protocols: $protoStr."
            Write-Output '       TLS 1.2 is included. WinHTTP can negotiate with Microsoft endpoints.'
        } else {
            Write-Output "[!!]  $label"
            Write-Output "       DefaultSecureProtocols = $dspHex. Protocols: $protoStr."
            Write-Output '       TLS 1.2 is NOT included. WinHTTP (used by wuauserv) CANNOT negotiate'
            Write-Output '       TLS 1.2 with Microsoft Azure Front Door endpoints.'
            Write-Output '       Common HRESULT: 0x80072F8F (content decoding / TLS failure).'
            Write-Output "       Fix: Set DefaultSecureProtocols to at least 0x00000A00 (TLS 1.1 + 1.2) at $regPath"
            $issueCount++
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: System Clock & Time Source
# ---------------------------------------------------------------
Write-Output '--- System Clock & Time Source ---'

# 4a: Check W32Time service
$w32svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
$w32Running = ($null -ne $w32svc -and $w32svc.Status -eq 'Running')

# 4b: Query the configured time source
$timeSource = 'Unknown'
try {
    $srcOutput = & w32tm /query /source 2>&1
    $srcText = ($srcOutput | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($srcText) -and $srcText -notlike '*error*' -and $srcText -notlike '*not running*') {
        $timeSource = $srcText
    } elseif ($srcText -like '*not running*') {
        $timeSource = '(W32Time service not running)'
    }
} catch {
    $timeSource = '(query failed)'
}

# 4c: Attempt to measure clock offset
$offsetSeconds = $null
$offsetMeasured = $false

if ($w32Running -and $timeSource -ne 'Unknown' -and $timeSource -ne '(W32Time service not running)' -and $timeSource -ne '(query failed)') {
    # Use the configured NTP source for stripchart
    $ntpTarget = $timeSource
    # w32tm /query /source returns format: "server,0xFlags" (single) or "server,0xF peer2,0xF" (multi, space-separated)
    # Split on spaces first to isolate the first peer, then strip the ,0xNN flag suffix
    $ntpTarget = ($ntpTarget -split '\s+')[0].Trim()
    $ntpTarget = $ntpTarget -replace ',0x[0-9a-fA-F]+$', ''
    $ntpTarget = $ntpTarget.Trim()

    if (-not [string]::IsNullOrWhiteSpace($ntpTarget) -and $ntpTarget -ne 'Local CMOS Clock' -and $ntpTarget -ne 'Free-running System Clock') {
        try {
            $stripOutput = & w32tm /stripchart /computer:$ntpTarget /samples:1 /dataonly 2>&1
            $stripText = $stripOutput | Out-String
            # Parse offset from output lines like: "22:15:00, +00.4218632s" (or comma decimal on European locales)
            $lines = $stripText -split "`n"
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -match '([+-]\d+(?:[\.,]\d+)?)s') {
                    $rawStr = $Matches[1].Replace(',', '.')
                    $offsetSeconds = [double]::Parse($rawStr, [System.Globalization.CultureInfo]::InvariantCulture)
                    $offsetMeasured = $true
                    break
                }
            }
        } catch { }
    }
}

# Report findings
if (-not $w32Running) {
    Write-Output '[!]   Windows Time Service (W32Time)'
    Write-Output '       Service is not running. Cannot verify time synchronization.'
    Write-Output '       If the system clock drifts, TLS certificate validation will fail.'
    Write-Output '       Start the service: net start W32Time'
    $warnCount++
} elseif ($offsetMeasured) {
    $absOffset = [math]::Abs($offsetSeconds)
    $offsetStr = '{0:+0.00;-0.00}' -f $offsetSeconds

    if ($absOffset -gt 300) {
        Write-Output '[!!]  System Clock: CRITICAL DRIFT'
        Write-Output "       Time source: $timeSource"
        Write-Output "       Offset: ${offsetStr} seconds ($('{0:N0}' -f ($absOffset / 60)) minutes)."
        Write-Output '       Clock drift exceeds 5 minutes. TLS certificate validity checks WILL FAIL.'
        Write-Output '       Fix: w32tm /resync /force'
        $issueCount++
    } elseif ($absOffset -gt 60) {
        Write-Output '[!]   System Clock: Drift Detected'
        Write-Output "       Time source: $timeSource"
        Write-Output "       Offset: ${offsetStr} seconds."
        Write-Output '       Drift is notable but not yet critical for TLS. Monitor or resync.'
        $warnCount++
    } else {
        Write-Output '[OK]  System Clock'
        Write-Output "       Time source: $timeSource"
        Write-Output "       Offset: ${offsetStr} seconds. Clock is accurate."
    }
} else {
    # Could not measure offset -- report what we know
    if ($timeSource -eq 'Local CMOS Clock' -or $timeSource -eq 'Free-running System Clock') {
        Write-Output '[!]   System Clock: No External Sync'
        Write-Output "       Time source: $timeSource"
        Write-Output '       Machine is not synchronizing with an NTP server.'
        Write-Output '       Clock may drift over time, eventually causing TLS failures.'
        Write-Output '       Configure an NTP source: w32tm /config /manualpeerlist:time.windows.com /syncfromflags:manual /update'
        $warnCount++
    } else {
        Write-Output '[i]   System Clock'
        Write-Output "       Time source: $timeSource"
        Write-Output '       Could not measure offset (NTP server may be unreachable).'
        Write-Output '       Verify the clock is correct visually. If off by more than 5 minutes, TLS will fail.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: Microsoft Root Certificate Validation
# ---------------------------------------------------------------
Write-Output '--- Microsoft Root Certificates ---'

$rootCerts = @(
    @{
        CN         = 'Microsoft Root Certificate Authority 2011'
        Thumbprint = '8F43288AD272F3103B6FB1428485EA3014C0BCFE'
        Purpose    = 'Signs all WU payloads since 2011'
    }
    @{
        CN         = 'Microsoft ECC Root Certificate Authority 2017'
        Thumbprint = '999A64C37FF47D9FAB95F14769891460EEC4C3C5'
        Purpose    = 'Used by newer endpoints and Azure Front Door'
    }
)

foreach ($rc in $rootCerts) {
    $certName = $rc.CN
    $expectedThumb = $rc.Thumbprint
    $purpose = $rc.Purpose

    $found = $null
    try {
        # Search by thumbprint first (most reliable)
        $found = Get-ChildItem -Path 'Cert:\LocalMachine\Root' -ErrorAction Stop | Where-Object { $_.Thumbprint -eq $expectedThumb } | Select-Object -First 1
    } catch { }

    if ($null -eq $found) {
        # Fallback: search by subject CN
        try {
            $found = Get-ChildItem -Path 'Cert:\LocalMachine\Root' -ErrorAction Stop | Where-Object { $_.Subject -like "*$certName*" } | Select-Object -First 1
        } catch { }
    }

    if ($null -eq $found) {
        Write-Output "[!!]  $certName"
        Write-Output '       NOT FOUND in Cert:\LocalMachine\Root.'
        Write-Output "       Purpose: $purpose."
        Write-Output '       Windows Update signature validation will fail with certificate chain errors.'
        Write-Output '       Common HRESULTs: 0x800B0109 (chain error), 0x80096004 (trust failure).'
        Write-Output '       Fix: certutil -generateSSTFromWU roots.sst && certutil -addstore -f root roots.sst'
        $issueCount++
    } else {
        $expiry = $found.NotAfter
        $expired = ($expiry -lt (Get-Date))

        if ($expired) {
            Write-Output "[!!]  $certName"
            Write-Output "       EXPIRED on $($expiry.ToString('yyyy-MM-dd'))."
            Write-Output '       WU signature validation will fail. Certificate chain cannot be verified.'
            Write-Output '       Fix: certutil -generateSSTFromWU roots.sst && certutil -addstore -f root roots.sst'
            $issueCount++
        } else {
            $daysToExpiry = [math]::Floor(($expiry - (Get-Date)).TotalDays)
            Write-Output "[OK]  $certName"
            Write-Output "       Present. Expires: $($expiry.ToString('yyyy-MM-dd')) ($daysToExpiry days). Valid."
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 6: FIPS Mode
# ---------------------------------------------------------------
Write-Output '--- FIPS Mode ---'

$fipsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FIPSAlgorithmPolicy'
$fipsEnabled = Get-RegVal -Path $fipsPath -Name 'Enabled'

if ($null -ne $fipsEnabled -and $fipsEnabled -eq 1) {
    Write-Output '[!]   FIPS Algorithm Policy: ENABLED'
    Write-Output '       FIPSAlgorithmPolicy\Enabled = 1.'
    Write-Output '       FIPS mode restricts cryptographic algorithms. This can interfere with'
    Write-Output '       certain WU downloads and .NET crypto operations.'
    Write-Output '       If WU fails with crypto errors and all other checks pass, FIPS may be the cause.'
    $warnCount++
} else {
    Write-Output '[OK]  FIPS Algorithm Policy: Not enabled'
    Write-Output '       FIPS mode is not active. No cryptographic restrictions.'
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
$totalProblems = $issueCount + $warnCount
if ($totalProblems -eq 0) {
    Write-Output 'RESULT: No issues detected. TLS, certificates, and time appear healthy.'
} elseif ($issueCount -gt 0 -and $warnCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Review items above."
} elseif ($issueCount -gt 0) {
    Write-Output "RESULT: $issueCount issue(s) found. Review items marked [!!] above."
} else {
    Write-Output "RESULT: $warnCount warning(s) found. Review items marked [!] above."
}

Write-Output ''
Write-Output 'NEXT:   If TLS 1.2 disabled       -> enable via registry (or run WU010 WUServicingRepair)'
Write-Output '        If clock drift > 5 min    -> fix with: w32tm /resync /force'
Write-Output '        If root certs missing     -> run: certutil -generateSSTFromWU roots.sst'
Write-Output '        If .NET strong crypto off -> set SchUseStrongCrypto = 1 at the flagged registry path'
Write-Output '        If all checks pass        -> run WU005 WUComponentHealth for component store analysis'
Write-Output ''
