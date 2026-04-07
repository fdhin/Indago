# WU003_WUNetworkCheck.ps1
# Scriptlet: WU003 - Network & Connectivity Diagnostics
# Context: System | Version: 1.2

$ErrorActionPreference = 'SilentlyContinue'
Write-Output ''
Write-Output '=== Network & Connectivity Diagnostics ==='
Write-Output ''

$issueCount = 0
$warnCount  = 0

# ---------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------
$connectTimeoutMs = 5000

# Microsoft Update endpoints to test
$endpoints = @(
    @{ Host = 'windowsupdate.microsoft.com';    Port = 443; Label = 'Windows Update discovery' }
    @{ Host = 'update.microsoft.com';           Port = 443; Label = 'Windows Update secondary' }
    @{ Host = 'download.windowsupdate.com';     Port = 443; Label = 'Payload download' }
    @{ Host = 'dl.delivery.mp.microsoft.com';   Port = 443; Label = 'Delivery Optimization' }
)

# Check if WSUS is configured and add it to the endpoint list
$wsusUrl = $null
try {
    $wsusReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop
    if ($null -ne $wsusReg -and ($wsusReg.PSObject.Properties.Name -contains 'WUServer')) {
        $wsusUrl = $wsusReg.WUServer
    }
} catch { }

if (-not [string]::IsNullOrWhiteSpace($wsusUrl)) {
    try {
        $uri = [System.Uri]$wsusUrl
        $wsusHost = $uri.Host
        $wsusPort = $uri.Port
        $endpoints += @{ Host = $wsusHost; Port = $wsusPort; Label = "WSUS server ($wsusUrl)" }
    } catch { }
}

# ---------------------------------------------------------------
# Check 1: DNS Resolution
# ---------------------------------------------------------------
Write-Output '--- DNS Resolution ---'

# Store resolved IPs for use in Check 2
$resolvedEndpoints = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($ep in $endpoints) {
    $hostName = $ep.Host
    $port     = $ep.Port
    $label    = $ep.Label

    $ips = $null
    $dnsOk = $false
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($hostName)
        if ($null -ne $ips -and $ips.Count -gt 0) {
            $dnsOk = $true
        }
    } catch { }

    if ($dnsOk) {
        $ipList = ($ips | ForEach-Object { $_.IPAddressToString }) -join ', '
        Write-Output "[OK]  $hostName"
        Write-Output "       Resolves to: $ipList ($label)"
        $null = $resolvedEndpoints.Add([PSCustomObject]@{
            Host    = $hostName
            Port    = $port
            Label   = $label
            Resolved = $true
        })
    } else {
        Write-Output "[!!]  $hostName"
        Write-Output "       DNS resolution FAILED. Cannot resolve this endpoint ($label)."
        Write-Output "       Check DNS server configuration, DNS forwarding rules, and DNS-layer filters."
        $null = $resolvedEndpoints.Add([PSCustomObject]@{
            Host    = $hostName
            Port    = $port
            Label   = $label
            Resolved = $false
        })
        $issueCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 2: HTTPS Connectivity (TCP port test)
# ---------------------------------------------------------------
Write-Output '--- HTTPS Connectivity ---'

foreach ($ep in $resolvedEndpoints) {
    $hostName = $ep.Host
    $port     = $ep.Port
    $label    = $ep.Label

    if (-not $ep.Resolved) {
        Write-Output "[i]   ${hostName}:${port}"
        Write-Output "       Skipped -- DNS resolution failed (see above)."
        continue
    }

    $tcpOk = $false
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($hostName, $port, $null, $null)
        $waited = $ar.AsyncWaitHandle.WaitOne($connectTimeoutMs, $false)
        if ($waited) {
            $tcp.EndConnect($ar)
            $tcpOk = $true
        }
    } catch {
        $tcpOk = $false
    } finally {
        if ($null -ne $tcp) { try { $tcp.Close() } catch { } }
    }

    if ($tcpOk) {
        Write-Output "[OK]  ${hostName}:${port}"
        Write-Output "       Reachable. Connection established within ${connectTimeoutMs}ms timeout."
    } else {
        Write-Output "[!!]  ${hostName}:${port}"
        Write-Output "       Cannot connect on port $port within ${connectTimeoutMs}ms."
        Write-Output "       A firewall, web filter, or network appliance may be blocking this connection."
        if ($port -ne 443) {
            Write-Output "       This is a WSUS endpoint -- verify the WSUS server is running and reachable."
        } else {
            Write-Output "       Verify firewall rules allow outbound TCP 443 to Microsoft Update endpoints."
        }
        $issueCount++
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 3: WinHTTP Proxy Settings
# ---------------------------------------------------------------
Write-Output '--- WinHTTP Proxy ---'

$winHttpOutput = $null
try {
    $winHttpOutput = & netsh winhttp show proxy 2>&1
    $winHttpText = ($winHttpOutput | Out-String).Trim()
} catch {
    $winHttpText = ''
}

if ([string]::IsNullOrWhiteSpace($winHttpText)) {
    Write-Output '[!]   WinHTTP Proxy'
    Write-Output '       Could not query WinHTTP proxy settings (netsh winhttp show proxy failed).'
    $warnCount++
} else {
    # Detect proxy by looking for a proxy server pattern (host:port)
    # Direct access outputs vary by locale, but a configured proxy always shows host:port
    $hasProxy = $false
    $proxyLine = ''
    $bypassLine = ''

    $lines = $winHttpText -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        # Match lines with label: value pattern
        if ($trimmed -match ':\s*(.+)$') {
            $val = $Matches[1].Trim()
            if ($val -match '\S+:\d+') {
                # Value contains host:port -- this is the proxy server
                if (-not $hasProxy) {
                    $hasProxy = $true
                    $proxyLine = $val
                }
            } elseif ($hasProxy -and -not [string]::IsNullOrWhiteSpace($val)) {
                # After finding proxy, the next non-empty label:value line is the bypass list
                if ([string]::IsNullOrWhiteSpace($bypassLine)) {
                    $bypassLine = $val
                }
            }
        }
    }

    if ($hasProxy) {
        if ([string]::IsNullOrWhiteSpace($bypassLine)) {
            Write-Output '[!]   WinHTTP Proxy'
            Write-Output "       Proxy configured: $proxyLine"
            Write-Output '       Bypass list: (empty)'
            Write-Output '       WARNING: No bypass list. ALL traffic routes through the proxy, including WU.'
            Write-Output '       Verify the proxy allows traffic to *.windowsupdate.com and *.microsoft.com.'
            $warnCount++
        } else {
            Write-Output '[i]   WinHTTP Proxy'
            Write-Output "       Proxy configured: $proxyLine"
            Write-Output "       Bypass list: $bypassLine"
            Write-Output '       Verify the proxy allows traffic to *.windowsupdate.com and *.microsoft.com.'
        }
    } else {
        Write-Output '[OK]  WinHTTP Proxy'
        Write-Output '       Direct access (no proxy server). WinHTTP uses direct connections.'
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 4: WinINet Proxy (SYSTEM user hive)
# ---------------------------------------------------------------
Write-Output '--- WinINet Proxy (SYSTEM) ---'

# WUA runs as SYSTEM and reads proxy from the SYSTEM user hive, not HKLM.
# HKLM Internet Settings are ignored unless ProxySettingsPerUser = 0 (GPO).
$sysProxyPath = 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyEnabled = $null
$proxyServer  = $null
$proxyOverride = $null

try {
    $sysProxyReg = Get-ItemProperty -Path $sysProxyPath -ErrorAction Stop
    if ($null -ne $sysProxyReg) {
        if ($sysProxyReg.PSObject.Properties.Name -contains 'ProxyEnable') {
            $proxyEnabled = [int]$sysProxyReg.ProxyEnable
        }
        if ($sysProxyReg.PSObject.Properties.Name -contains 'ProxyServer') {
            $proxyServer = $sysProxyReg.ProxyServer
        }
        if ($sysProxyReg.PSObject.Properties.Name -contains 'ProxyOverride') {
            $proxyOverride = $sysProxyReg.ProxyOverride
        }
    }
} catch { }

if ($null -eq $proxyEnabled -or $proxyEnabled -eq 0) {
    Write-Output '[OK]  WinINet Proxy (SYSTEM)'
    Write-Output '       No proxy configured in the SYSTEM account hive (ProxyEnable is not set or 0).'
} elseif ($proxyEnabled -eq 1) {
    if ([string]::IsNullOrWhiteSpace($proxyServer)) {
        Write-Output '[!]   WinINet Proxy (SYSTEM)'
        Write-Output '       ProxyEnable = 1 but no ProxyServer is defined.'
        Write-Output '       This is a broken configuration. Proxy is enabled with nowhere to route traffic.'
        $warnCount++
    } else {
        $bypassStr = if ([string]::IsNullOrWhiteSpace($proxyOverride)) { '(none)' } else { $proxyOverride }
        Write-Output '[i]   WinINet Proxy (SYSTEM)'
        Write-Output "       Proxy enabled: $proxyServer"
        Write-Output "       Bypass list: $bypassStr"
        Write-Output '       Verify the proxy allows traffic to *.windowsupdate.com and *.microsoft.com.'
    }
} else {
    Write-Output '[i]   WinINet Proxy (SYSTEM)'
    Write-Output "       ProxyEnable = $proxyEnabled (unexpected value)."
}

Write-Output ''

# ---------------------------------------------------------------
# Check 5: PAC / Auto-Config Detection
# ---------------------------------------------------------------
Write-Output '--- PAC / Auto-Config ---'

$pacUrl = $null
$wpadEnabled = $false

try {
    $inetReg = Get-ItemProperty -Path $sysProxyPath -ErrorAction Stop
    if ($null -ne $inetReg -and ($inetReg.PSObject.Properties.Name -contains 'AutoConfigURL')) {
        $pacUrl = $inetReg.AutoConfigURL
    }
} catch { }

# Check WPAD auto-detect via DefaultConnectionSettings binary blob
$connectionsPath = 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
try {
    $connReg = Get-ItemProperty -Path $connectionsPath -ErrorAction Stop
    if ($null -ne $connReg -and ($connReg.PSObject.Properties.Name -contains 'DefaultConnectionSettings')) {
        $blob = $connReg.DefaultConnectionSettings
        if ($null -ne $blob -and $blob.Length -gt 8) {
            # Byte index 8 (0-based): bit 0x08 = auto-detect enabled
            $flags = [int]$blob[8]
            if (($flags -band 0x08) -ne 0) {
                $wpadEnabled = $true
            }
        }
    }
} catch { }

$hasPacOrWpad = $false
if (-not [string]::IsNullOrWhiteSpace($pacUrl)) {
    Write-Output '[i]   PAC File Configured'
    Write-Output "       AutoConfigURL: $pacUrl"
    Write-Output '       Verify the PAC file returns DIRECT or a working proxy for *.windowsupdate.com.'
    $hasPacOrWpad = $true
}
if ($wpadEnabled) {
    Write-Output '[i]   WPAD Auto-Detection Enabled'
    Write-Output '       The system will try to discover a proxy via DNS/DHCP (Web Proxy Auto-Discovery).'
    Write-Output '       If no WPAD server responds, the system falls back to direct connections.'
    $hasPacOrWpad = $true
}
if (-not $hasPacOrWpad) {
    Write-Output '[OK]  Automatic Proxy Configuration'
    Write-Output '       No PAC file or WPAD auto-detection configured.'
}

Write-Output ''

# ---------------------------------------------------------------
# Check 6: VPN Adapter Detection
# ---------------------------------------------------------------
Write-Output '--- VPN Detection ---'

$vpnKeywords = @(
    'Cisco', 'AnyConnect',
    'Palo Alto', 'GlobalProtect',
    'FortiClient', 'Fortinet',
    'WireGuard',
    'OpenVPN', 'TAP-Windows',
    'Juniper',
    'SonicWall', 'NetExtender',
    'Check Point',
    'Zscaler',
    'NordVPN', 'NordLynx',
    'Pulse Secure', 'Ivanti'
)

$vpnAdapters = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop)
    foreach ($adapter in $adapters) {
        $desc = $adapter.InterfaceDescription
        if ([string]::IsNullOrWhiteSpace($desc)) { continue }

        foreach ($keyword in $vpnKeywords) {
            if ($desc -like "*$keyword*") {
                $null = $vpnAdapters.Add([PSCustomObject]@{
                    Name   = $adapter.Name
                    Desc   = $desc
                    Status = $adapter.Status
                })
                break
            }
        }
    }
} catch {
    Write-Output '[!]   VPN Adapter Detection'
    Write-Output "       Could not enumerate network adapters: $($_.Exception.Message)"
    $warnCount++
}

if ($vpnAdapters.Count -eq 0) {
    Write-Output '[OK]  VPN Adapters'
    Write-Output '       No VPN adapters detected.'
} else {
    foreach ($vpn in $vpnAdapters) {
        if ($vpn.Status -eq 'Up') {
            Write-Output "[!]   Active VPN: $($vpn.Desc)"
            Write-Output "       Adapter: $($vpn.Name). Status: Up."
            Write-Output '       If updates fail, verify the VPN split-tunnel configuration allows traffic'
            Write-Output '       to *.windowsupdate.com, *.microsoft.com, and *.delivery.mp.microsoft.com.'
            $warnCount++
        } else {
            Write-Output "[i]   VPN Adapter: $($vpn.Desc)"
            Write-Output "       Adapter: $($vpn.Name). Status: $($vpn.Status)."
            Write-Output '       Not connected. No impact on current connectivity.'
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Check 7: Metered Connection Detection
# ---------------------------------------------------------------
Write-Output '--- Metered Connection ---'

$meteredFindings = [System.Collections.Generic.List[PSCustomObject]]::new()

# 7a: Check DefaultMediaCost registry for global metered settings
$mediaCostPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost'
try {
    $mediaCostReg = Get-ItemProperty -Path $mediaCostPath -ErrorAction Stop
    if ($null -ne $mediaCostReg) {
        # DefaultMediaCost values: 1 = Unrestricted/Unmetered, 2 = Metered
        if ($mediaCostReg.PSObject.Properties.Name -contains 'Ethernet') {
            $ethCost = [int]$mediaCostReg.Ethernet
            if ($ethCost -ge 2) {
                $null = $meteredFindings.Add([PSCustomObject]@{
                    Severity = 'ISSUE'
                    Message  = "Ethernet is globally marked as METERED (DefaultMediaCost = $ethCost). This is unusual for wired connections and will defer most updates."
                })
            }
        }
        if ($mediaCostReg.PSObject.Properties.Name -contains 'WiFi') {
            $wifiCost = [int]$mediaCostReg.WiFi
            if ($wifiCost -ge 2) {
                $null = $meteredFindings.Add([PSCustomObject]@{
                    Severity = 'WARN'
                    Message  = "Wi-Fi is globally marked as METERED (DefaultMediaCost = $wifiCost). Windows will defer updates on Wi-Fi connections. This may be intentional for mobile hotspots."
                })
            }
        }
    }
} catch { }

# 7b: Check active connection profiles for per-connection metered status
try {
    $connProfiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    foreach ($cp in $connProfiles) {
        $costType = $null
        try { $costType = $cp.NetworkCostType } catch { }
        if ($null -ne $costType) {
            $costStr = $costType.ToString()
            # Fixed or Variable = metered
            if ($costStr -eq 'Fixed' -or $costStr -eq 'Variable') {
                $null = $meteredFindings.Add([PSCustomObject]@{
                    Severity = 'WARN'
                    Message  = "Connection '$($cp.Name)' on $($cp.InterfaceAlias) is marked as METERED ($costStr). Windows will defer updates on this connection."
                })
            }
        }
    }
} catch { }

if ($meteredFindings.Count -eq 0) {
    Write-Output '[OK]  Metered Connection Status'
    Write-Output '       No metered connections detected. Updates will download normally.'
} else {
    foreach ($mf in $meteredFindings) {
        if ($mf.Severity -eq 'ISSUE') {
            Write-Output "[!!]  $($mf.Message)"
            $issueCount++
        } else {
            Write-Output "[!]   $($mf.Message)"
            $warnCount++
        }
    }
}

Write-Output ''

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
if ($issueCount -eq 0 -and $warnCount -eq 0) {
    Write-Output 'RESULT: No issues detected. Network connectivity to Microsoft Update appears healthy.'
} elseif ($issueCount -eq 0) {
    Write-Output "RESULT: $warnCount warning(s) found. Review the flagged items above."
} else {
    Write-Output "RESULT: $issueCount issue(s) and $warnCount warning(s) found. Network connectivity needs attention."
}

Write-Output ''
Write-Output 'NEXT:   If DNS fails              -> check DNS server configuration and firewall rules'
Write-Output '        If HTTPS blocked          -> work with firewall team to allow Microsoft Update endpoints'
Write-Output '        If proxy issues           -> verify proxy allows *.windowsupdate.com, *.microsoft.com'
Write-Output '        For TLS/certificate issues -> run WU004 WUTlsCertCheck'
