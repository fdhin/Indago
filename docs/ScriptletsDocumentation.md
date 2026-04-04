# Indago Scriptlet Documentation

Reference documentation for all scriptlets in the Indago module.
Each entry describes what the scriptlet checks, why it matters, how to run it, and what the output means.

---

## Output Icon Reference

All scriptlets use a consistent icon system:

| Icon | Meaning |
|------|---------|
| `[OK]` | Check passed. Everything is healthy. |
| `[!!]` | Issue found. Action required. |
| `[!]` | Warning. Not critical, but worth noting. |
| `[ERR]` | Error occurred while running the check itself. |
| `[i]` | Informational. Additional context for another finding. |

Every scriptlet ends with a `RESULT:` summary line and a `NEXT:` footer recommending follow-up actions.

---

## Windows Update Suite

### WU001 -- WUQuickHealth

**Version:** 2.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

30-second vital-signs snapshot of Windows Update health. Answers the question every tech asks first:

> Is WU fundamentally working on this machine, or do I need to dig deeper -- and if so, where?

This is the entry point for all Windows Update troubleshooting. Run this first; its output will tell you which deeper diagnostic to run next.

#### Usage

```powershell
# Default: scan last 30 days of update history
Invoke-Indago -Name WUQuickHealth

# Custom window: scan last 7 days only
Invoke-Indago -Name WUQuickHealth -Param1 "7"
```

#### Parameters

| Parameter | Name | Default | Description |
|-----------|------|---------|-------------|
| `Param1` | DaysBack | `30` | How many days of Windows Update history to scan for failures. |

#### What It Checks

##### Check 1 -- Core Service Status

Queries four critical Windows Update services:

| Service | Name | Expected State |
|---------|------|----------------|
| Windows Update | `wuauserv` | Manual (Trigger Start) -- starts on demand |
| Background Intelligent Transfer | `BITS` | Manual -- starts on demand |
| Cryptographic Services | `CryptSvc` | Automatic -- should always be running |
| Update Orchestrator | `UsoSvc` | Automatic -- should always be running |

**Verdict logic:**
- `Disabled` on any service --> `[!!]` -- updates cannot function
- `Stopped` with `Automatic` start type --> `[!!]` -- should be running but isn't
- `Stopped` with `Manual` start type --> `[OK]` -- normal demand-start behavior
- `Running` --> `[OK]`

**Why it matters:** If any of these services is disabled, nothing else in the WU pipeline can function. `UsoSvc` (Update Orchestrator) replaced the legacy `wuauclt.exe` and is the primary scan/install coordinator on Windows 10/11.

##### Check 2 -- System Drive Free Space

Queries `Win32_LogicalDisk` for the system drive and applies two thresholds:

| Free Space | Verdict | Meaning |
|-----------|---------|---------|
| < 5 GB | `[!!]` Critical | Even monthly cumulative updates may fail. |
| 5-20 GB | `[!]` Warning | Monthly patches should work, but feature updates need at least 20 GB. |
| >= 20 GB | `[OK]` | Sufficient for all update types. |

Reports both free and total capacity for context (e.g., "5.5 GB free of 63 GB").

##### Check 3 -- Pending Reboot Flags

Checks three independent reboot signal locations. A pending reboot blocks all new update installations -- this is one of the most common "hidden" causes of update failures.

| Signal Source | Registry Path | Detection Method |
|--------------|---------------|------------------|
| Windows Update | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` | Key presence |
| Component Based Servicing | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending` | Key presence |
| Session Manager | `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` | `PendingFileRenameOperations` value is non-empty |

If any signal is present, the output names which subsystem(s) requested the reboot.

##### Check 4 -- Recent Update History

Queries the Windows Update COM API (`Microsoft.Update.Session`) for update history within the `DaysBack` window.

- Reports **count** of successful and failed updates
- Shows the **top 5 failures** with date, HRESULT code, update title, and a **human-readable translation** of the error code
- Unknown HRESULT codes display with a prompt to search on Microsoft Learn

The embedded HRESULT translation table covers 20 common error codes:

| HRESULT | Meaning | Suggested Action |
|---------|---------|-----------------|
| `0x80070643` | WinRE partition too small or MSI failure | Manual partition resize may be needed |
| `0x800F081F` | Component store missing files | Run WU005 WUComponentHealth |
| `0x80073712` | Component store corruption | Run WU005 WUComponentHealth |
| `0x80244022` | Update server HTTP 503 | Run WU003 WUNetworkCheck |
| `0x8024401C` | Connection timed out | Run WU003 WUNetworkCheck |
| `0x8024002E` | WU administratively disabled | Run WU002 WUPolicyAudit |
| `0x80070005` | Access denied | Check third-party AV / Tamper Protection |
| `0x80240022` | All updates in batch failed | Check individual errors |
| `0x80242014` | Post-reboot finalization pending | Reboot the machine |
| `0x800F0922` | Safe OS phase failed | Check WinRE partition / disk space |
| `0x80070002` | Required file not found | Run WU005 |
| `0x80080005` | Server execution failed | Run WU009 WUServiceReset |
| `0x8007000E` | Out of memory | Close applications, retry |
| `0x80072EE7` | DNS resolution failed | Run WU003 WUNetworkCheck |
| `0x80072F8F` | TLS/SSL validation failed | Run WU004 WUTlsCertCheck |
| `0x80096004` | Certificate trust failure | Run WU004 WUTlsCertCheck |
| `0x80244019` | WSUS rejected request (503) | Check WSUS server health |
| `0x800705B4` | Operation timed out | Run WU009 WUServiceReset |
| `0x80240017` | Update not applicable | Usually not a problem |
| `0x80070BC9` | Reboot required first | Reboot and retry |

##### Check 5 -- SoftwareDistribution Cache Size

Measures the total size of `%SystemRoot%\SoftwareDistribution`, where Windows Update stores downloaded payloads.

| Size | Verdict | Meaning |
|------|---------|---------|
| >= 1 GB | `[!!]` | Bloated cache -- likely stuck or failed downloads accumulating. |
| < 1 GB | `[OK]` | Normal cache size. |

If the folder is missing entirely, that's also flagged as `[!!]` -- it should always exist.

##### Check 6 -- Last Successful Update Date

Finds the most recent successfully installed update from the COM history (across all available history, not limited to the `DaysBack` window).

| Days Since Last Success | Verdict | Meaning |
|------------------------|---------|---------|
| > 60 days | `[!!]` | Machine is significantly behind on patches. |
| 31-60 days | `[!]` | Updates appear to have stalled. |
| 0-30 days | `[OK]` | Update cadence looks healthy. |
| No history found | `[!!]` | No successful updates in available history. Investigate immediately. |

#### Example Output (Healthy System)

```
=== Windows Update Quick Health ===

[OK]  Windows Update (wuauserv)
       Running, start type: Manual. Operational.
[OK]  Background Intelligent Transfer (BITS) (BITS)
       Stopped, start type: Manual. This is expected -- service starts on demand when updates are needed.
[OK]  Cryptographic Services (CryptSvc)
       Running, start type: Automatic. Operational.
[OK]  Update Orchestrator (UsoSvc)
       Running, start type: Automatic. Operational.
[OK]  Disk Space (C:)
       45.2 GB free of 256 GB. Sufficient for all update types.
[OK]  Pending Reboot
       No reboot pending. Machine is clear to accept new updates.
[OK]  Update History (last 30 days)
       No failed updates. 21 update(s) succeeded.
[OK]  SoftwareDistribution Cache
       66 MB. Cache size is normal.
[OK]  Last Successful Update
       0 days ago (2026-04-01). Update cadence looks healthy.

RESULT: No issues detected. Windows Update appears healthy.

NEXT:   If services are stopped      -> run WU009 WUServiceReset
        If policy issues suspected   -> run WU002 WUPolicyAudit
        If network-related failures  -> run WU003 WUNetworkCheck
        For deeper investigation     -> run scripts WU002-WU008 in order
```

#### Scope Boundaries

WU001 is deliberately scoped to fast vital signs. The following concerns are handled by other scriptlets:

| Concern | Handled By |
|---------|-----------|
| GPO/MDM/WSUS policy settings | WU002 WUPolicyAudit |
| Network connectivity, DNS, proxy | WU003 WUNetworkCheck |
| TLS, certificates, clock drift | WU004 WUTlsCertCheck |
| DISM, CBS.log, SFC, component store health | WU005 WUComponentHealth |
| Event log timeline (Event IDs 19/20/21) | WU006 WUEventTimeline |
| Third-party AV, hardware, Defender | WU007 WUEnvironmentAudit |
| Service reset, cache clear | WU009 WUServiceReset |
| DISM repair, SFC, full servicing fix | WU010 WUServicingRepair |

#### Version History

| Version | Changes |
|---------|---------|
| 2.0 | Complete rewrite. Replaced `DiagnoseWindowsUpdate`. Added UsoSvc, 3-signal reboot detection, 20-entry HRESULT table, last-success date, `NEXT:` footer routing, `[!]` warning tier. Dropped `msiserver` monitoring. Fixed demand-start service logic (Manual + Stopped = OK). |
| 1.0 | Original `DiagnoseWindowsUpdate` -- basic service and history checks. |

---

### WU002 -- WUPolicyAudit

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Read-only audit of every GPO, MDM/Intune, and UX-level policy setting governing Windows Update behavior. In managed environments, a stale WSUS pointer, an overly aggressive deferral period, or a user-initiated pause is the single most common cause of silent update failure -- machines that look enrolled and healthy but quietly stop patching for weeks.

WU001 tells the tech "updates are failing." WU002 tells them "here is the exact policy configuration causing it."

#### Usage

```powershell
Invoke-Indago -Name WUPolicyAudit
```

No parameters. The script reads all relevant registry paths automatically.

#### What It Checks

The script audits three disjoint registry layers that can conflict or silently override each other:

**GPO Policy Layer** (`HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` and `\AU`):

| Check | Registry Key | Verdicts |
|-------|-------------|----------|
| WSUS Server | `WUServer`, `WUStatusServer`, `UseWUServer` | `[OK]` if not configured or reachable. `[!!]` if configured but unreachable (3s TCP timeout). `[!]` if URL set but not enforced. |
| Automatic Updates | `NoAutoUpdate` | `[OK]` if not set. `[!!]` if `= 1` (updates disabled). |
| Windows Update Access | `DisableWindowsUpdateAccess` | `[OK]` if not blocked. `[!!]` if `= 1` (HRESULT 0x8024002E). |
| Internet Locations | `DoNotConnectToWindowsUpdateInternetLocations` | `[OK]` if not set. `[i]` if locked to WSUS (expected). `[!!]` if locked to WSUS but no WSUS configured. |
| Auto-Update Behavior | `AUOptions` (1-5) | `[OK]` for value 4 (fully automated). `[i]` for values 2-3, 5. `[!]` for value 1 (disabled). |
| Feature Deferral | `DeferFeatureUpdatesPeriodInDays` | `[i]` with value. `[!]` if > 180 days. |
| Quality Deferral | `DeferQualityUpdatesPeriodInDays` | `[i]` with value. `[!]` if > 14 days (missing 2+ Patch Tuesdays). |
| Pause Deferrals | `PauseDeferrals` | `[!]` if `= 1`. |
| Quality Pause | `PauseQualityUpdatesStartTime` | `[!!]` if set -- security patches paused. |
| Feature Pause | `PauseFeatureUpdatesStartTime` | `[!]` if set. |
| Driver Exclusion | `ExcludeWUDriversInQualityUpdate` | `[i]` if `= 1` -- drivers excluded from quality updates. |
| WSUS Target Group | `TargetGroupEnabled`, `TargetGroup` | `[i]` with group name. `[!]` if targeting enabled but no group set. |

**User & UX Settings** (`HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings`):

| Check | Registry Key | Verdicts |
|-------|-------------|----------|
| Active Hours | `ActiveHoursStart`, `ActiveHoursEnd` | `[OK]` if default. `[i]` with window. `[!]` if span > 18h. |
| User-Initiated Pause | `PauseUpdatesExpiryTime` | `[OK]` if not set or expired. `[!!]` if pause is active (expiry in the future). |

**MDM/Intune Policy Layer** (`HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update`):

| Check | Registry Key | Verdicts |
|-------|-------------|----------|
| AllowAutoUpdate | `AllowAutoUpdate` (0-5) | `[!!]` if 5 (updates off). `[!]` if 0 (notify only). `[i]` for 1-4. |
| Feature Deferral | `DeferFeatureUpdatesPeriodInDays` | Same thresholds as GPO. |
| Quality Deferral | `DeferQualityUpdatesPeriodInDays` | Same thresholds as GPO. |
| Quality Pause | `PauseQualityUpdatesStartTime` | `[!!]` if set. |
| Feature Pause | `PauseFeatureUpdatesStartTime` | `[!]` if set. |
| Driver Exclusion | `ExcludeWUDriversInQualityUpdate` | `[i]` if `= 1`. |
| Target Product Version | `ProductVersion` | `[i]` -- device pinned to this OS version. |

**Delivery Optimization** (`HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization`):

| Check | Registry Key | Verdicts |
|-------|-------------|----------|
| Download Mode | `DODownloadMode` | `[OK]` for modes 1-2 (LAN/Group peering). `[i]` for 0 or 3. `[!]` for 99 or 100 (peering disabled). |

**Policy Conflict Resolution** (Split-Brain Detection):

When both GPO and MDM keys are present, the script checks `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict\MDMWinsOverGP`:

| Condition | Verdict |
|-----------|---------|
| `MDMWinsOverGP = 1` | `[!]` MDM wins. GPO settings are being overridden for Policy CSP settings. |
| `MDMWinsOverGP` not set or `= 0` | `[!!]` Race condition. No guaranteed policy winner. Unpredictable update behavior. |
| Only GPO or only MDM keys present | No conflict finding shown. |

#### Output Structure

The output is organized into clearly labeled sections so techs can quickly identify which policy layer is causing the problem:

```
=== WU Policy & Configuration Audit ===

--- GPO Policy Layer ---
[OK]  WSUS Server
       Not configured. Client uses Microsoft Update or MDM for updates.
[OK]  Automatic Updates (GPO)
       NoAutoUpdate is not set. Automatic updates are enabled.
[OK]  Windows Update Access (GPO)
       Access to Windows Update is not blocked by policy.
[OK]  Internet Locations (GPO)
       Client can reach Microsoft Update if WSUS is unavailable.
[OK]  Auto-Update Behavior (GPO)
       Not configured by policy. Default OS behavior applies.
[OK]  Deferral & Pause Settings (GPO)
       No deferral or pause policies configured at the GPO layer.

--- User & UX Settings ---
[OK]  Active Hours
       Not configured. Default active hours apply (8 AM - 5 PM).
[OK]  User-Initiated Pause
       No user-initiated pause is active.

--- MDM/Intune Policy Layer ---
[i]   MDM Update Policy
       No MDM update policies detected. Device is not managed by Intune/MDM for Windows Update.

--- Delivery Optimization ---
[OK]  Delivery Optimization
       Not configured by policy. Default mode applies (LAN peering).

RESULT: No issues detected. Windows Update policies appear correctly configured.

NEXT:   If WSUS unreachable           -> verify WSUS server health or escalate to infrastructure team
        If policies block updates     -> review GPO/Intune policies with the sysadmin
        If GPO/MDM split-brain        -> decide on a single policy source and set MDMWinsOverGP accordingly
        If user paused updates        -> unpause via Settings > Windows Update
        For network-level issues      -> run WU003 WUNetworkCheck
        For deeper WU investigation   -> run scripts WU003-WU008 in order
```

#### Boundary with Other Scriptlets

| Scriptlet | What it handles (NOT WU002's job) |
|-----------|-----------------------------------|
| WU001 WUQuickHealth | Services, disk space, reboot flags, WU history, cache size |
| WU003 WUNetworkCheck | DNS resolution, HTTPS connectivity, proxy, VPN, metered connections |
| WU004 WUTlsCertCheck | TLS 1.2 Schannel, .NET crypto, clock drift, root certificates |
| WU005 WUComponentHealth | DISM health, CBS.log, SFC, component store |

WU002 does a basic TCP reachability test for the WSUS server URL (if configured). This is NOT a full network diagnostic -- it is a quick "is the configured server alive?" check. Full DNS/HTTPS/proxy diagnostics belong to WU003.

#### Changelog

| Version | Changes |
|---------|---------|
| 1.0 | Initial release. 11 checks across 3 registry layers. WSUS TCP reachability (3s timeout). ExcludeWUDriversInQualityUpdate from both GPO and MDM. MDMWinsOverGP split-brain detection at ControlPolicyConflict registry path. Sectioned output (GPO, UX, MDM, DO, Conflict Resolution). |

---

### WU003 -- WUNetworkCheck

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Tests whether the machine can actually reach Microsoft Update infrastructure. Answers: "policies look correct, services are running -- **can the machine physically talk to the update servers?**"

This is the #2 cause of silent update failure in managed environments: the machine is configured correctly but cannot reach the servers due to DNS blocking, firewall rules, proxy misconfiguration, VPN split-tunnel issues, or metered connections. None of these show up in WU001 or WU002.

#### Usage

```powershell
Invoke-Indago -Name WUNetworkCheck
```

No parameters.

#### What It Checks

##### Check 1 -- DNS Resolution

Resolves key Microsoft Update endpoints using `[System.Net.Dns]::GetHostAddresses()`:

| Endpoint | Purpose |
|----------|---------|
| `windowsupdate.microsoft.com` | Primary WU discovery |
| `update.microsoft.com` | Secondary WU endpoint |
| `download.windowsupdate.com` | Payload download |
| `dl.delivery.mp.microsoft.com` | Delivery Optimization / modern payload delivery |
| WSUS hostname (if configured) | Internal WSUS (extracted from `HKLM:\...\WindowsUpdate\WUServer`) |

The WSUS server is only included if `WUServer` is configured in the GPO registry path. The hostname is parsed from the URL via `[System.Uri]`.

| Condition | Verdict |
|-----------|---------|
| DNS resolves to IP(s) | `[OK]` with resolved IPs |
| DNS resolution fails | `[!!]` -- check DNS server, forwarding, DNS-layer filters |

##### Check 2 -- HTTPS Connectivity (TCP 443)

For each successfully resolved endpoint, tests TCP connectivity using `[System.Net.Sockets.TcpClient]` with async `BeginConnect` and a **5-second timeout**.

For WSUS endpoints, tests the WSUS port (parsed from URL, defaulting to 8530/8531) instead of 443.

> **Design note:** Uses `TcpClient` instead of `Invoke-WebRequest` per vision.md spec. `Invoke-WebRequest` requires IE COM objects that may not be available in SYSTEM context.

| Condition | Verdict |
|-----------|---------|
| TCP connection succeeds | `[OK]` |
| TCP connection fails/times out | `[!!]` -- firewall, web filter, or network appliance may be blocking |
| Endpoint skipped (DNS failed) | `[i]` -- skipped, DNS failed |

##### Check 3 -- WinHTTP Proxy

Captures WinHTTP proxy configuration via `netsh winhttp show proxy`. Parses output by looking for proxy server patterns (host:port) to avoid locale-dependent label matching.

| Condition | Verdict |
|-----------|---------|
| Direct access (no proxy) | `[OK]` |
| Proxy configured with bypass list | `[i]` -- show proxy + bypass list, advise verifying WU access |
| Proxy configured, no bypass list | `[!]` -- all traffic routes through proxy |

##### Check 4 -- System Proxy Registry (HKLM)

Reads machine-level proxy at `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings`:

| Value | Purpose |
|-------|---------|
| `ProxyEnable` | 0/1 -- proxy active |
| `ProxyServer` | Proxy address |
| `ProxyOverride` | Bypass list |

> **Important:** This reads the **HKLM** (machine-level) proxy, not HKCU. In SYSTEM context, the user-level proxy is irrelevant.

| Condition | Verdict |
|-----------|---------|
| `ProxyEnable` not set or = 0 | `[OK]` |
| Proxy enabled with server | `[i]` -- show config |
| Proxy enabled, no server | `[!]` -- broken configuration |

##### Check 5 -- PAC / Auto-Config

Detects automatic proxy configuration:

- **PAC file:** `AutoConfigURL` registry value at the Internet Settings path
- **WPAD:** Byte 8 of `DefaultConnectionSettings` binary blob in the Connections subkey (bit 0x08 = auto-detect enabled)

Full PAC file download and parsing is out of scope. We detect the _configuration_ exists and alert the tech.

| Condition | Verdict |
|-----------|---------|
| No PAC or WPAD | `[OK]` |
| PAC URL configured | `[i]` -- show URL, advise verifying WU access |
| WPAD auto-detect enabled | `[i]` -- system will try DNS/DHCP proxy discovery |

##### Check 6 -- VPN Adapter Detection

Enumerates network adapters via `Get-NetAdapter` and matches `InterfaceDescription` against 11 common VPN vendor keywords: Cisco/AnyConnect, Palo Alto/GlobalProtect, FortiClient, WireGuard, OpenVPN/TAP-Windows, Juniper, SonicWall/NetExtender, Check Point, Zscaler, NordVPN/NordLynx, Pulse Secure/Ivanti.

| Condition | Verdict |
|-----------|---------|
| No VPN adapters | `[OK]` |
| VPN adapter Up | `[!]` -- advise verifying split-tunnel for WU endpoints |
| VPN adapter present but Down | `[i]` -- no current impact |

##### Check 7 -- Metered Connection Detection

Checks metered status from two sources:

1. **Global:** `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost` -- `Ethernet` and `WiFi` cost values (1 = unrestricted, 2+ = metered)
2. **Per-connection:** `Get-NetConnectionProfile` -- `NetworkCostType` property (Fixed/Variable = metered)

| Condition | Verdict |
|-----------|---------|
| No metered connections | `[OK]` |
| Ethernet globally metered | `[!!]` -- unusual for wired, will defer updates |
| WiFi/connection metered | `[!]` -- may be intentional |

#### Example Output (Healthy System)

```
=== Network & Connectivity Diagnostics ===

--- DNS Resolution ---
[OK]  windowsupdate.microsoft.com
       Resolves to: 13.107.4.50 (Windows Update discovery)
[OK]  update.microsoft.com
       Resolves to: 13.107.4.50 (Windows Update secondary)
[OK]  download.windowsupdate.com
       Resolves to: 117.18.232.240, 117.18.232.241 (Payload download)
[OK]  dl.delivery.mp.microsoft.com
       Resolves to: 152.199.39.108 (Delivery Optimization)

--- HTTPS Connectivity ---
[OK]  windowsupdate.microsoft.com:443
       Reachable. Connection established within 5000ms timeout.
[OK]  update.microsoft.com:443
       Reachable.
[OK]  download.windowsupdate.com:443
       Reachable.
[OK]  dl.delivery.mp.microsoft.com:443
       Reachable.

--- WinHTTP Proxy ---
[OK]  WinHTTP Proxy
       Direct access (no proxy server). WinHTTP uses direct connections.

--- System Proxy (HKLM) ---
[OK]  System Proxy (HKLM)
       No system-level proxy configured.

--- PAC / Auto-Config ---
[OK]  Automatic Proxy Configuration
       No PAC file or WPAD auto-detection configured.

--- VPN Detection ---
[OK]  VPN Adapters
       No VPN adapters detected.

--- Metered Connection ---
[OK]  Metered Connection Status
       No metered connections detected. Updates will download normally.

RESULT: No issues detected. Network connectivity to Microsoft Update appears healthy.

NEXT:   If DNS fails              -> check DNS server configuration and firewall rules
        If HTTPS blocked          -> work with firewall team to allow Microsoft Update endpoints
        If proxy issues           -> verify proxy allows *.windowsupdate.com, *.microsoft.com
        For TLS/certificate issues -> run WU004 WUTlsCertCheck
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| WU services, disk space, reboot flags, history | WU001 WUQuickHealth |
| GPO/MDM policy settings, WSUS config, deferral/pause | WU002 WUPolicyAudit |
| TLS 1.2 Schannel, .NET crypto, clock drift, root certs | WU004 WUTlsCertCheck |
| DISM, CBS.log, SFC, component store | WU005 WUComponentHealth |
| Event log timeline | WU006 WUEventTimeline |
| Service reset, cache clear | WU009 WUServiceReset |

WU002 does a basic TCP reachability test for the WSUS server URL. WU003 does full DNS + TCP connectivity against all Microsoft Update endpoints AND the WSUS server. WU003 is the full network diagnostic.

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 7 check groups: DNS resolution for 4 Microsoft endpoints + WSUS (if configured) via `[System.Net.Dns]::GetHostAddresses()`, HTTPS TCP connectivity via `TcpClient` with 5s async timeout, WinHTTP proxy via `netsh winhttp show proxy` with locale-safe parsing, system proxy via HKLM Internet Settings, PAC/WPAD detection via AutoConfigURL + DefaultConnectionSettings blob bit 0x08, VPN adapter detection via `Get-NetAdapter` keyword matching (11 vendors), metered connection via DefaultMediaCost registry + `Get-NetConnectionProfile.NetworkCostType`. `NEXT:` footer routing to WU004. |

---

### WU004 -- WUTlsCertCheck

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Verifies the **cryptographic and time-keeping prerequisites** that Windows Update depends on. WU003 confirms the machine can reach Microsoft endpoints at the network layer (DNS resolves, TCP socket opens). WU004 answers the next question: **will the TLS handshake succeed once the socket is open?**

Missing TLS 1.2 support, expired root certificates, or a drifted system clock all produce maddeningly generic HRESULTs (`0x80072F8F`, `0x800B0109`, `0x80096004`) that are impossible to diagnose without specifically probing the TLS stack, certificate store, and clock. WU004 exists to surface these silent killers.

#### Usage

```powershell
Invoke-Indago -Name WUTlsCertCheck
```

No parameters.

#### What It Checks

##### Check 1 -- Schannel TLS 1.2 Configuration

Reads the Schannel registry to determine whether TLS 1.2 is enabled for both Client and Server roles:

| Registry Path | Values Checked |
|---------------|----------------|
| `HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client` | `Enabled`, `DisabledByDefault` |
| `HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server` | `Enabled`, `DisabledByDefault` |

On Windows 10+, TLS 1.2 is enabled by default when no Schannel subkey exists. The check handles this correctly.

| Condition | Verdict |
|-----------|---------|
| Subkey absent (OS defaults) | `[OK]` -- TLS 1.2 enabled by default |
| `Enabled` = 1, `DisabledByDefault` = 0 | `[OK]` -- explicitly enabled |
| `Enabled` = 0 | `[!!]` -- TLS 1.2 explicitly disabled |
| `DisabledByDefault` = 1 | `[!!]` -- apps must opt in to TLS 1.2 |

**Legacy protocol detection:** Also checks if TLS 1.0 or SSL 3.0 Client subkeys are still enabled. Flags as `[!]` warning (security risk but not blocking WU).

##### Check 2 -- .NET Framework TLS Defaults

Reads .NET Framework 4.x registry for both 64-bit and 32-bit (WOW6432Node) architectures:

| Registry Path | Values Checked |
|---------------|----------------|
| `HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319` | `SchUseStrongCrypto`, `SystemDefaultTlsVersions` |
| `HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319` | Same keys |

Both architectures are checked independently because WU components can run as either 32-bit or 64-bit processes.

| Condition | Verdict |
|-----------|---------|
| `SchUseStrongCrypto` = 1 or `SystemDefaultTlsVersions` = 1 | `[OK]` |
| Both missing or 0 | `[!!]` -- .NET defaults to TLS 1.0 |
| Registry path not found | `[i]` -- .NET 4.x may not be installed for this arch |

##### Check 3 -- WinHTTP Default Secure Protocols

Reads the `DefaultSecureProtocols` DWORD at the WinHTTP registry path. This is distinct from the Schannel check -- it specifically governs the WinHTTP subsystem used by `wuauserv` and `svchost`.

| Registry Path | Value |
|---------------|-------|
| `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp` | `DefaultSecureProtocols` |
| `HKLM:\SOFTWARE\WOW6432Node\...\WinHttp` | Same (32-bit) |

The value is a protocol bitmask:

| Bit | Protocol |
|-----|----------|
| `0x00000800` | TLS 1.2 |
| `0x00000200` | TLS 1.1 |
| `0x00000080` | TLS 1.0 |
| `0x00000020` | SSL 3.0 |

| Condition | Verdict |
|-----------|---------|
| Not configured (OS defaults) | `[OK]` -- TLS 1.2 included on Win10+ |
| Configured and includes `0x800` | `[OK]` -- decoded protocols shown |
| Configured but missing `0x800` | `[!!]` -- WinHTTP cannot negotiate TLS 1.2, causes `0x80072F8F` |

##### Check 4 -- System Clock & Time Source

Verifies that the system clock is accurate by:

1. Checking the W32Time service status
2. Querying the configured time source via `w32tm /query /source`
3. Measuring clock offset via `w32tm /stripchart /computer:<source> /samples:1 /dataonly`

| Condition | Verdict |
|-----------|---------|
| W32Time not running | `[!]` -- cannot verify time sync |
| Offset > 5 minutes (300s) | `[!!]` -- TLS cert validation WILL fail |
| Offset > 1 minute (60s) | `[!]` -- drift detected, not yet critical |
| Offset < 1 minute | `[OK]` -- clock accurate |
| Source is Local CMOS Clock / Free-running | `[!]` -- no external NTP sync |
| Cannot measure offset | `[i]` -- NTP server may be unreachable |

##### Check 5 -- Microsoft Root Certificate Validation

Searches `Cert:\LocalMachine\Root` for two critical Microsoft root CAs:

| Certificate | Thumbprint | Purpose |
|-------------|------------|---------|
| Microsoft Root Certificate Authority 2011 | `8F43288AD272F3103B6FB1428485EA3014C0BCFE` | Signs all WU payloads since 2011 |
| Microsoft ECC Root Certificate Authority 2017 | `999A64C37FF47D9FAB95F14769891460EEC4C3C5` | Used by newer endpoints and Azure Front Door |

Searches by thumbprint first (most reliable), with fallback to Subject CN matching.

| Condition | Verdict |
|-----------|---------|
| Found and not expired | `[OK]` -- shows expiry date and days remaining |
| Found but expired | `[!!]` -- WU signature validation will fail |
| Not found | `[!!]` -- certificate chain errors (`0x800B0109`, `0x80096004`) |

##### Check 6 -- FIPS Mode

Reads `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FIPSAlgorithmPolicy\Enabled`.

| Condition | Verdict |
|-----------|---------|
| Not enabled (0 or absent) | `[OK]` |
| Enabled = 1 | `[!]` -- can interfere with certain WU downloads and .NET crypto |

#### Example Output (Healthy System)

```
=== TLS, Certificates & Time Check ===

--- Schannel TLS 1.2 Configuration ---
[OK]  TLS 1.2 Client
       Subkey not present. OS defaults apply (TLS 1.2 enabled on Windows 10+).
[OK]  TLS 1.2 Server
       Subkey not present. OS defaults apply (TLS 1.2 enabled on Windows 10+).
[!]   Legacy Protocols Still Active: TLS 1.0 (OS default)
       These are not blocking Windows Update but are a security risk.
       Consider disabling TLS 1.0 and SSL 3.0 when all applications support TLS 1.2+.

--- .NET Framework TLS Defaults ---
[OK]  .NET 4.x (64-bit)
       SchUseStrongCrypto = 1, SystemDefaultTlsVersions = 1. Strong crypto active.
[OK]  .NET 4.x (32-bit)
       SchUseStrongCrypto = 1, SystemDefaultTlsVersions = 1. Strong crypto active.

--- WinHTTP Secure Protocols ---
[OK]  WinHTTP (64-bit)
       DefaultSecureProtocols not configured. OS defaults apply (TLS 1.2 included on Win10+).
[OK]  WinHTTP (32-bit)
       DefaultSecureProtocols not configured. OS defaults apply (TLS 1.2 included on Win10+).

--- System Clock & Time Source ---
[OK]  System Clock
       Time source: time.windows.com
       Offset: +0.42 seconds. Clock is accurate.

--- Microsoft Root Certificates ---
[OK]  Microsoft Root Certificate Authority 2011
       Present. Expires: 2036-03-22 (3650 days). Valid.
[OK]  Microsoft ECC Root Certificate Authority 2017
       Present. Expires: 2042-07-18 (5936 days). Valid.

--- FIPS Mode ---
[OK]  FIPS Algorithm Policy: Not enabled
       FIPS mode is not active. No cryptographic restrictions.

RESULT: No issues detected. TLS, certificates, and time appear healthy.

NEXT:   If TLS 1.2 disabled       -> enable via registry (or run WU010 WUServicingRepair)
        If clock drift > 5 min    -> fix with: w32tm /resync /force
        If root certs missing     -> run: certutil -generateSSTFromWU roots.sst
        If .NET strong crypto off -> set SchUseStrongCrypto = 1 at the flagged registry path
        If all checks pass        -> run WU005 WUComponentHealth for component store analysis
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| WU services, disk space, reboot flags, history | WU001 WUQuickHealth |
| GPO/MDM policy settings, WSUS config, deferral/pause | WU002 WUPolicyAudit |
| DNS resolution, HTTPS connectivity, proxy, VPN, metered | WU003 WUNetworkCheck |
| DISM, CBS.log, SFC, component store | WU005 WUComponentHealth |
| Event log timeline | WU006 WUEventTimeline |
| Service reset, cache clear | WU009 WUServiceReset |

WU003 proves the TCP socket opens. WU004 proves the TLS handshake will succeed once the socket is open. WU003's `NEXT:` footer explicitly routes to WU004 for TLS/certificate issues.

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 6 check groups: Schannel TLS 1.2 Client/Server subkeys with legacy protocol detection (TLS 1.0, SSL 3.0), .NET Framework 4.x SchUseStrongCrypto and SystemDefaultTlsVersions for both 64-bit and WOW6432Node, WinHTTP DefaultSecureProtocols bitmask decoding (64-bit + 32-bit), system clock offset via `w32tm /stripchart` with fallback for unreachable NTP sources, Microsoft Root CA 2011 + ECC 2017 certificate validation with expiry check, FIPS algorithm policy detection. |

---

### WU005 -- WUComponentHealth

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Checks whether the Windows servicing stack itself is healthy. When WU001 through WU004 all pass but updates still fail, the problem often lies in component store corruption -- damaged manifests, missing payloads, or orphaned servicing state. WU005 answers: "Is the servicing infrastructure intact?"

This scriptlet runs DISM health checks (non-destructive), parses CBS.log for corruption indicators, extracts the last SFC result, and analyzes component store sizing. It does NOT modify the system or run repairs -- that is WU010's job.

> **Timing note:** This scriptlet runs two DISM subprocess calls and may take 30-60 seconds -- significantly slower than most triage scriptlets.

#### Usage

```powershell
Invoke-Indago -Name WUComponentHealth
```

#### Parameters

None.

#### What It Checks

##### Check 1 -- DISM Health Check (Component Store Registry Flags)

Runs `Repair-WindowsImage -Online -CheckHealth` to query the CBS registry for pre-existing corruption flags. Falls back to `dism.exe /Online /Cleanup-Image /CheckHealth` if the PowerShell cmdlet fails.

| Health State | Verdict | Meaning |
|---|---|---|
| `Healthy` | `[OK]` | No corruption flags set in the CBS registry |
| `Repairable` | `[!!]` | Corruption detected; `DISM /RestoreHealth` can fix it |
| `NonRepairable` | `[!!]` | Corruption beyond DISM's ability to fix; in-place upgrade needed |

**Important nuance:** `/CheckHealth` only queries registry flags (`CorruptionDetectedDuringAcr`, `Unserviceable`). It does NOT scan physical files. A system with silent bit-rot or externally-deleted DLLs will report `Healthy`. This is why Checks 2 and 3 (CBS.log analysis and SFC results) are essential complements -- they catch what `/CheckHealth` misses.

##### Check 2 -- CBS.log Analysis (Last 200 Lines)

Reads the tail of `%SystemRoot%\Logs\CBS\CBS.log` (last 200 lines) and scans for corruption indicators. CBS.log is the ground truth for Component-Based Servicing -- DISM, SFC, and TiWorker.exe operations are all recorded here.

**Critical HRESULT patterns (component store corruption):**

| HRESULT | Name | Meaning |
|---|---|---|
| `0x80073712` | `ERROR_SXS_COMPONENT_STORE_CORRUPT` | WinSxS store fundamentally inconsistent |
| `0x800F081F` | `CBS_E_SOURCE_MISSING` | Repair payload not found locally or online |
| `0x800F0831` | `CBS_E_STORE_CORRUPTION` | Orphaned manifest blocking dependency chains |
| `0x800736CC` | `ERROR_SXS_FILE_HASH_MISMATCH` | File hash does not match manifest |

**Warning patterns (transient or third-party issues):**

| HRESULT | Name | Meaning |
|---|---|---|
| `0x800F0823` | `CBS_E_NEW_SERVICING_STACK_REQUIRED` | Servicing Stack Update outdated for this update |
| `0x800F0982` | `PSFX_E_MATCHING_BINARY_MISSING` | Aborted or rolled-back update |
| `0x8007000D` | `ERROR_INVALID_DATA` | Unreadable data or malformed manifest |
| `0x80070020` | `ERROR_SHARING_VIOLATION` | File locked by AV/EDR during servicing |

Also scans for text markers: `Store corruption` and `Exec: Error`.

**Verdict logic:**
- Critical HRESULTs or text markers found -> `[!!]` with count and last 3 unique matches
- Warning HRESULTs only -> `[!]` with count and last 3 unique matches
- No patterns found -> `[OK]`
- CBS.log unreadable -> `[i]`

##### Check 3 -- Last SFC Result

Parses CBS.log (last 5000 lines) for the most recent `sfc /scannow` outcome. SFC distinguishes its entries with the `[SR]` tag prefix. WU005 does NOT run SFC -- it only reads the result of the last execution.

| CBS.log Result String | Verdict | Meaning |
|---|---|---|
| `did not find any integrity violations` | `[OK]` | All protected files match their manifests |
| `found corrupt files and successfully repaired them` | `[i]` | SFC repaired files; store had corruption but self-healed |
| `found corrupt files but was unable to fix some of them` | `[!!]` | Unfixable corruption; WU010 needed |
| `could not perform the requested operation` | `[!]` | SFC failed to run; pending reboot or TrustedInstaller issue |
| No result found | `[i]` | SFC has not been run recently or log has rolled over |

Reports the timestamp of the last SFC run when extractable from the log line prefix.

**Design note:** The 5000-line scan depth (vs. 200 for Check 2) is necessary because SFC results can be pushed far back in the log by subsequent servicing activity.

##### Check 4 -- Component Store Size (DISM /AnalyzeComponentStore)

Runs `dism.exe /Online /Cleanup-Image /AnalyzeComponentStore` and parses stdout for 7 metrics. There is no WMI/CIM class that exposes accurate WinSxS sizing. Standard `Get-ChildItem` sizing is fatally flawed due to NTFS hard links counting the same physical sectors multiple times.

**Extracted metrics:**

| Metric | Source String |
|---|---|
| Gross directory size | `Windows Explorer Reported Size of Component Store :` |
| Actual (deduplicated) size | `Actual Size of Component Store :` |
| Shared with Windows | `Shared with Windows :` |
| Superseded payloads | `Backups and Disabled Features :` |
| Reclaimable packages | `Number of Reclaimable Packages :` |
| Cleanup recommended | `Component Store Cleanup Recommended :` |
| Last cleanup date | `Date of Last Cleanup :` |

**Verdict logic:**
- Cleanup not recommended -> `[OK]` with actual size and key metrics
- Cleanup recommended -> `[!]` with sizes and concrete cleanup command
- Parse failure -> `[!]` with raw output excerpt

#### Example Output (Healthy System)

```
=== Component Store & System Integrity ===

[i]   This scriptlet runs DISM operations and may take 30-60 seconds.

--- DISM Health Check ---
[OK]  Component Store Health (Registry Flags)
       No component store corruption detected. Store is healthy.
       Note: This checks registry state only. CBS.log analysis (below)
       validates physical file integrity that may not be reflected here.

--- CBS.log Analysis ---
[OK]  CBS.log (Last 200 Lines)
       No corruption patterns found in recent CBS activity.

--- Last SFC Result ---
[i]   System File Checker
       No SFC result found in CBS.log (last 5000 lines).
       SFC has not been run recently, or the log has rolled over.
       This is informational -- if DISM reports healthy and no CBS
       errors found, the component store is likely intact.

--- Component Store Size ---
[OK]  Component Store Analysis
       Actual size: 5.12 GB (reported: 8.42 GB due to hard links).
       Shared with Windows: 3.30 GB. Backups/disabled: 1.82 GB.
       Reclaimable packages: 0.
       Last cleanup: 2026-03-15.
       Component Store Cleanup Recommended: No.

RESULT: No issues detected. Component store and servicing stack appear healthy.

NEXT:   If corruption detected   -> run WU010 WUServicingRepair (DISM /RestoreHealth + SFC)
        If component store large -> run: DISM /Online /Cleanup-Image /StartComponentCleanup
        If SFC found unfixable   -> run WU010 WUServicingRepair for full repair chain
        If clean                 -> issue is elsewhere; run WU006 WUEventTimeline
```

#### Scope Boundaries

WU005 is strictly scoped to servicing stack diagnostics. The following concerns are handled by other scriptlets:

| Concern | Handled By |
|---|---|
| WU services (wuauserv, BITS, CryptSvc, UsoSvc), disk space, reboot flags, history | WU001 WUQuickHealth |
| GPO/MDM/WSUS policy, deferral, pause, servicing policies | WU002 WUPolicyAudit |
| DNS, HTTPS connectivity, proxy, VPN, metered | WU003 WUNetworkCheck |
| TLS 1.2 Schannel, .NET crypto, clock drift, root certs, FIPS | WU004 WUTlsCertCheck |
| Event log timeline (Servicing events, WindowsUpdateClient) | WU006 WUEventTimeline |
| Third-party AV, hardware, Defender | WU007 WUEnvironmentAudit |
| Service reset, cache clear | WU009 WUServiceReset |
| DISM /RestoreHealth, SFC /scannow, full servicing fix | WU010 WUServicingRepair |

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 4 check groups: DISM health via Repair-WindowsImage -CheckHealth with dism.exe fallback (3-state ImageHealthState enum, registry-only limitation documented), CBS.log tail analysis (last 200 lines, 8 corruption HRESULTs from WU006 research: 4 critical + 4 warning, plus Store corruption and Exec Error text markers), last SFC result (5000 line scan depth, [SR] tag parsing, 4 outcome strings with timestamp extraction), component store sizing via dism.exe /AnalyzeComponentStore (7 metrics including last cleanup date, regex stdout parsing -- no WMI/CIM alternative exists due to NTFS hard link sizing illusion). |

---

### WU006 -- WUEventTimeline

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Pulls WU-related events from three Windows Event Log sources, merges them into a single chronological timeline, and translates HRESULT error codes into plain English with actionable next-step routing. This gives the tech the **narrative** of a WU failure -- not just "it failed" (WU001) or "the store is corrupt" (WU005), but the blow-by-blow sequence of what happened across download, install, reboot, and commit stages.

WU001-WU005 answer "what's broken?" WU006 answers "what happened?" -- the sequence of events that reveals *where* in the pipeline things went wrong.

#### Usage

```powershell
# Default: last 7 days of events
Invoke-Indago -Name WUEventTimeline

# Custom window: last 30 days
Invoke-Indago -Name WUEventTimeline -Param1 "30"
```

#### Parameters

| Parameter | Name | Default | Description |
|---|---|---|---|
| `Param1` | DaysBack | `7` | How many days of event history to pull |

#### What It Checks

##### Check 1 -- Event Summary Statistics

Provides a compact overview before the full timeline:
- Total events found across all 3 sources within the time window
- Breakdown: successes vs failures vs informational events
- Most frequent error code (if failures exist)

| Condition | Verdict |
|---|---|
| No events found | `[OK]` No WU activity or logs cleared |
| Events found, no failures | `[OK]` Healthy update activity |
| Events with failures | `[!!]` Failure events detected |

##### Check 2 -- Event Timeline (Chronological, Capped at 50)

Queries 3 event log sources and merges events into a single timeline, sorted newest-first. Output is capped at the **50 most recent events** to keep RMM terminal output readable.

**Source 1: `Microsoft-Windows-WindowsUpdateClient/Operational`**

| Event ID | Type | Meaning |
|---|---|---|
| 19 | Success | Installation successful |
| 20 | Failure | Installation failed (contains HRESULT) |
| 21 | Info | Restart required to complete install |
| 25 | Info | Download started |
| 26 | Success | Download completed |
| 31 | Failure | Download failed (contains HRESULT) |
| 41 | Info | Update search started |
| 42 | Success | Update search completed |
| 43 | Failure | Update search failed (contains HRESULT) |
| 44 | Info | Automatic Updates scan started |

**Source 2: `Microsoft-Windows-BITS-Client/Operational`**

All BITS error events are included (not filtered to WU-only jobs, since BITS is primarily used by WU on most endpoints).

| Event ID | Type | Meaning |
|---|---|---|
| 3 | Info | Transfer started |
| 4 | Success | Transfer completed |
| 5 | Info | Transfer cancelled |
| 59 | Failure | Transfer error (contains HRESULT) |
| 60 | Failure | Transfer error (legacy format) |
| 64 | Failure | Job cancelled unexpectedly |

**Source 3: `System` log (two sub-queries)**

3a. Events from `Microsoft-Windows-WindowsUpdateClient` provider surfaced to the System log. Event level <= 2 (Error/Critical) classified as Failure.

3b. Service Control Manager events (IDs 7031, 7034, 7036, 7043) filtered to WU-related services only. The script matches event messages against: `wuauserv`, `BITS`, `TrustedInstaller`, `UsoSvc`, `Windows Update`, `Background Intelligent Transfer`, `Windows Modules Installer`.

| Event ID | Type | Meaning |
|---|---|---|
| 7031 | Failure | Service terminated unexpectedly |
| 7034 | Failure | Service terminated unexpectedly (2nd variant) |
| 7036 | Info | Service entered running/stopped state |
| 7043 | Failure | Service did not shut down properly |

**Timeline output format:**
```
yyyy-MM-dd HH:mm  [type]  [Source              ] EventID : Message summary
```

Each event shows timestamp, type icon (`[OK]`/`[!!]`/`[i]`), source name, event ID, and a truncated message (max 120 chars).

##### Check 3 -- HRESULT Summary (Grouped by Error Code)

After building the timeline, extracts all HRESULTs from failure event messages using regex pattern `0x[0-9A-Fa-f]{8}`. Groups by code and reports:

- Occurrence count
- Plain-English translation from 25-entry embedded map
- Suggested next action (routing to appropriate scriptlet)

**Embedded HRESULT Map (25 entries):**

| HRESULT | Translation | Suggested Action |
|---|---|---|
| `0x80072EFE` | Connection interrupted | WU003 |
| `0x80072EE7` | DNS resolution failed | WU003 |
| `0x80072F8F` | TLS/SSL validation failed | WU004 |
| `0x800B0109` | Certificate chain error | WU004 |
| `0x80096004` | Certificate trust failure | WU004 |
| `0x80244010` | Exceeded max WSUS round trips | Check WSUS |
| `0x80244022` | Server HTTP 503 | Check WSUS/CDN |
| `0x8024401C` | Connection timed out | WU003 |
| `0x80073712` | Component store corruption | WU005 |
| `0x800F081F` | Source files missing for repair | WU005 |
| `0x800F0831` | Orphaned manifest corruption | WU005 |
| `0x80070002` | File not found / corrupt store | WU005 |
| `0x80240024` | Update not applicable | Informational |
| `0x80240017` | Update not applicable | Informational |
| `0x80070643` | MSI / WinRE partition failure | Check WinRE |
| `0x800F0922` | Safe OS phase failed | Check WinRE + disk |
| `0x80080005` | COM/RPC failure | WU009 |
| `0x8007000E` | Out of memory | Close apps, retry |
| `0x80070005` | Access denied | Check AV/Tamper |
| `0x80070020` | Sharing violation (AV/EDR) | Check AV exclusions |
| `0x800705B4` | Operation timed out | WU009 |
| `0x80070BC9` | Reboot required first | Reboot machine |
| `0x8024002E` | WU administratively disabled | WU002 |
| `0x80242014` | Post-reboot finalization pending | Reboot machine |
| `0x80244019` | WSUS rejected (HTTP 503) | Check WSUS |

Unknown HRESULTs are shown as `[!]` with a link to search Microsoft Learn.

#### Example Output (System with Failures)

```
=== Windows Update Event Timeline ===

[!!]  Event Overview
       42 events across all sources. 28 success, 8 failure, 6 informational.
       Most common error: 0x80072EFE (5 occurrence(s)).

--- Timeline (50 Most Recent of 42) ---
2026-03-28 15:03  [OK]  [WindowsUpdateClient ] 19 : Installation successful: Security Update KB5035942
2026-03-28 15:02  [OK]  [WindowsUpdateClient ] 26 : Download completed: KB5035942
2026-03-28 15:00  [i]   [WindowsUpdateClient ] 25 : Download started: KB5035942
2026-03-28 14:32  [!!]  [WindowsUpdateClient ] 31 : Download failed: KB5035942 (0x80072EFE)
2026-03-28 14:31  [!!]  [BITS                ] 59 : Transfer error: 0x80072EFE
2026-03-28 14:30  [i]   [WindowsUpdateClient ] 25 : Download started: KB5035942
...

--- HRESULT Summary ---
[!!]  0x80072EFE  (5 occurrence(s))
       Connection interrupted -- server reset or dropped the connection mid-transfer.
       -> Run WU003 WUNetworkCheck to diagnose connectivity.

[!!]  0x80070643  (2 occurrence(s))
       MSI installer failure or WinRE recovery partition too small.
       -> Check WinRE partition size. Manual resize may be needed.

[i]   0x80240024  (1 occurrence(s))
       Update not applicable to this system architecture or edition.
       -> Informational -- usually not a problem.

RESULT: 3 unique error(s) found across 8 failure event(s). Review HRESULT details above.

NEXT:   Address the most common HRESULT listed above.
        If network errors (0x8007xxxx)  -> run WU003 WUNetworkCheck
        If cert errors (0x800B/0x8009)  -> run WU004 WUTlsCertCheck
        If store corruption (0x800F)    -> run WU005 WUComponentHealth
        If service errors (0x80080005)  -> run WU009 WUServiceReset
        If no errors found              -> issue may be policy (WU002) or environmental (WU007)
```

#### Example Output (Healthy System)

```
=== Windows Update Event Timeline ===

[OK]  Event Overview
       18 events across all sources. 12 success, 0 failure, 6 informational.

--- Timeline (All 18 Events) ---
2026-04-03 03:15  [OK]  [WindowsUpdateClient ] 19 : Installation successful: Cumulative Update KB5040442
2026-04-03 03:12  [OK]  [WindowsUpdateClient ] 26 : Download completed: KB5040442
2026-04-03 03:00  [i]   [WindowsUpdateClient ] 25 : Download started: KB5040442
2026-04-03 02:55  [OK]  [WindowsUpdateClient ] 42 : Update search completed
2026-04-03 02:50  [i]   [WindowsUpdateClient ] 44 : Automatic Updates scan started
...

RESULT: No failure events detected. Windows Update activity looks healthy.

NEXT:   Address the most common HRESULT listed above.
        If network errors (0x8007xxxx)  -> run WU003 WUNetworkCheck
        If cert errors (0x800B/0x8009)  -> run WU004 WUTlsCertCheck
        If store corruption (0x800F)    -> run WU005 WUComponentHealth
        If service errors (0x80080005)  -> run WU009 WUServiceReset
        If no errors found              -> issue may be policy (WU002) or environmental (WU007)
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| WU services, disk space, reboot flags, cache, COM API history | WU001 WUQuickHealth |
| GPO/MDM/WSUS policy, deferral, pause | WU002 WUPolicyAudit |
| DNS, HTTPS connectivity, proxy, VPN, metered | WU003 WUNetworkCheck |
| TLS 1.2 Schannel, .NET crypto, clock drift, root certs, FIPS | WU004 WUTlsCertCheck |
| DISM health, CBS.log parsing, SFC result, component store sizing | WU005 WUComponentHealth |
| Third-party AV, hardware, Defender | WU007 WUEnvironmentAudit |
| Service reset, cache clear | WU009 WUServiceReset |
| DISM /RestoreHealth, SFC /scannow, full servicing fix | WU010 WUServicingRepair |

**WU001 Check 4 vs WU006:** WU001 queries the WU COM API (`Microsoft.Update.Session`) for per-update outcomes. WU006 queries Windows Event Logs for the operational event sequence. Different data sources, different diagnostic purpose. WU001 says "KB5035942 failed with 0x80072EFE." WU006 says "download started -> BITS transfer error -> download failed -> retry -> succeeded."

**WU005 Check 2-3 vs WU006:** WU005 parses `CBS.log` (text file) for servicing stack corruption markers. WU006 reads structured Windows Event Logs. Completely different data sources. Some HRESULTs appear in both (e.g., 0x80073712) but are found in different contexts.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 3 output sections: event summary statistics (total/success/failure/info counts with most common error code), chronological timeline from 3 sources capped at 50 most recent events (WindowsUpdateClient/Operational IDs 19/20/21/25/26/31/41/42/43/44, BITS-Client/Operational IDs 3/4/5/59/60/64, System log Microsoft-Windows-WindowsUpdateClient provider + Service Control Manager IDs 7031/7034/7036/7043 filtered for WU service names), HRESULT summary with 25-entry embedded translation map and scriptlet routing. Regex extraction pattern `0x[0-9A-Fa-f]{8}`. Configurable time window via Param1 (default 7 days). |



### WU007 -- WUEnvironmentAudit

**Version:** 1.0
**Category:** WindowsUpdate
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Gathers the machine's software environment to identify third-party interference or eligibility issues that explain why Windows Update fails after all other diagnostics (WU001-WU006) have been cleared. This is the "what else is on this machine that might matter" check.

WU007 answers: "Is the machine's software environment compatible with the update being applied?"

#### Usage

```powershell
Invoke-Indago -Name WUEnvironmentAudit
```

No parameters.

#### What It Checks

##### Check 1 -- WU Agent Version

Reads `AgentVersion` from `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update` with `SetupVersion` fallback from the parent key.

| Condition | Verdict |
|---|---|
| Agent version found | `[i]` Report version |
| Agent version missing | `[]` Unable to determine version |

##### Check 2 -- OS Edition, Build, UBR

Reads from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` for BuildNumber, UBR, DisplayVersion, EditionID, ProductName. Uses `Get-CimInstance Win32_OperatingSystem` as caption fallback. Reports full build string as `BuildNumber.UBR` (e.g., `22631.4890`).

| Condition | Verdict |
|---|---|
| Standard edition/build | `[i]` Report edition, version, build.UBR |
| LTSC/LTSB/Server edition | `[i]` Note servicing channel difference |

##### Check 3 -- .NET Framework Version

Reads `Release` DWORD from `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full` and decodes using the official Microsoft mapping table:

| Release Value | .NET Version | Status |
|---|---|---|
| >= 533325 | 4.8.1 | `[OK]` Modern |
| >= 528040 | 4.8 | `[OK]` Modern |
| >= 461808 | 4.7.2 | `[]` Aging |
| >= 461308 | 4.7.1 | `[]` Aging |
| >= 460798 | 4.7 | `[]` Aging |
| >= 394802 | 4.6.2 | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` Outdated |
| >= 394254 | 4.6.1 | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` Outdated |
| < 394254 | 4.x | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` Outdated |

##### Check 4 -- PowerShell Version

Reports `$PSVersionTable.PSVersion` and `$PSVersionTable.CLRVersion`.

| Condition | Verdict |
|---|---|
| PS 5.1+ | `[OK]` Expected version |
| PS 5.0 | `[]` Below 5.1 |
| PS < 5.0 | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` Below minimum for modern WU cmdlets |

##### Check 5 -- Feature Update Eligibility

Compares the current OS build number against a hardcoded lookup table. **No internet queries.** Table includes builds through Windows 11 26H1 (ARM64-only, build 28000).

**Hardcoded version table:**

| Build | Version | Product | Status |
|---|---|---|---|
| 19041 | 2004 | Win 10 | End of service |
| 19042 | 20H2 | Win 10 | End of service |
| 19043 | 21H1 | Win 10 | End of service |
| 19044 | 21H2 | Win 10 | End of service |
| 19045 | 22H2 | Win 10 | EOS (Home/Pro), Extended ESU (Enterprise) |
| 22000 | 21H2 | Win 11 | End of service |
| 22621 | 22H2 | Win 11 | Enterprise extended |
| 22631 | 23H2 | Win 11 | In service |
| 26100 | 24H2 | Win 11 | In service |
| 26200 | 25H2 | Win 11 | In service (enablement package from 24H2) |
| 28000 | 26H1 | Win 11 | In service (ARM64-only, Snapdragon X2) |

| Condition | Verdict |
|---|---|
| Build in service | `[OK]` Receiving security updates |
| Build approaching EOL | `[]` Plan feature update |
| Build end of service | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` No longer receiving security updates |
| Build not in table | `[i]` May be Server, Insider, or new build |

##### Check 6 -- Third-Party AV / Security Software

**Two-pronged detection:**
- **SecurityCenter2 WMI** (`root/SecurityCenter2:AntiVirusProduct`) on workstations
- **Uninstall registry scan** (`HKLM:\...\Uninstall` + WOW6432Node)

**10-vendor known-problematic interference table:**

| Product | WU Interference Mechanism |
|---|---|
| Symantec | File locks on SoftwareDistribution folder (0x80240022) |
| Kaspersky | Web filter / CAPI2 certificate interception |
| McAfee | CAPI2 hooking, authrootstl.cab extraction failure (Event ID 11) |
| Trend Micro | Real-time scan blocks CBS file operations |
| ZoneAlarm | CAPI2 certificate interception |
| Webroot | Kernel driver file locks |
| Norton | File locks and schedule conflicts |
| Sophos | Web filter interference with BITS |
| ESET | May delay BITS transfers during real-time scanning |
| Bitdefender | Filter driver file locks in some versions |

Also scans for CrowdStrike, SentinelOne, Carbon Black, Cylance, Malwarebytes, Avast, and AVG (not flagged as problematic but reported for awareness).

> **Scope note:** DEF003 also queries SecurityCenter2 but for Defender coexistence analysis (bitmask decode, ghost registrations, remnant scan). WU007 does a lightweight AV detection focused specifically on Windows Update interference mechanisms. Different question, complementary answers.

| Condition | Verdict |
|---|---|
| No third-party AV | `[OK]` Only Defender active |
| Known-problematic AV | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/WU007_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "WU007",
    "Name": "WUEnvironmentAudit",
    "DisplayName": "Windows Update Agent & Environment Audit",
    "Category": "WindowsUpdate",
    "Description": "Gathers the machine software environment to identify third-party interference or eligibility issues: WU agent version, OS edition/build/UBR with feature update eligibility table, .NET Framework version decode, PowerShell version, third-party AV detection with known WU-interference flagging, update management tool inventory (SCCM, Intune, PatchMyPC, WSUS, ManageEngine, Automox) with co-management detection, and Visual C++ prerequisite check.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["windows-update", "environment", "third-party", "av", "agent", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 8 check groups: (1) WU agent version from Auto Update and WindowsUpdate registry. (2) OS edition/build/UBR from NT CurrentVersion registry with CIM fallback, servicing channel detection for LTSC/Server. (3) .NET Framework version decode from NDP v4 Full Release DWORD with official Microsoft mapping table (4.5 through 4.8.1). (4) PowerShell and CLR version from PSVersionTable. (5) Feature update eligibility against hardcoded version table: Win10 2004-22H2, Win11 21H2-25H2, Win11 26H1 ARM64 (build 28000). Reports OK/EXT/EOS status with end-of-service dates. No internet queries. (6) Third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table (Symantec/Kaspersky/McAfee/TrendMicro/ZoneAlarm/Webroot/Norton/Sophos/ESET/Bitdefender). (7) Update management tool inventory: SCCM ccmexec service, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS registry cross-reference, co-management conflict detection. (8) Visual C++ Redistributable presence check with modern vs legacy classification, pending .NET CBS package detection."
}

# Find insertion point -- after WU006
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'WU006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find WU006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: WU007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    wu007 = [e for e in verify if e['Id'] == 'WU007']
    if wu007:
        print(f"WU007 found. Name={wu007[0]['Name']}, Script={len(wu007[0]['Script'])} chars")
    else:
        print("ERROR: WU007 not found after insertion")
PYEOF]` Product known to interfere with WU, with mechanism description |
| Other third-party AV | `[i]` Present, noted for troubleshooting |
| Server OS | `[i]` SecurityCenter2 not available, Uninstall scan only |

##### Check 7 -- Third-Party Update Management

Detects which management tools are controlling updates:

| Tool | Detection Method |
|---|---|
| SCCM/MECM | `Get-Service ccmexec` |
| Intune MDM | `HKLM:\SOFTWARE\Microsoft\Enrollments` with ProviderID = 'MS DM Server' |
| Patch My PC | `Get-Service PatchMyPC*` |
| ManageEngine | `Get-Service ManageEngine*\|DesktopCentral\|UEMS` |
| Automox | `Get-Service amagent` |
| WSUS | `HKLM:\...\WindowsUpdate\WUServer` registry cross-reference |

**Co-management detection:** If both SCCM and Intune are present, flags as co-managed with a recommendation to verify workload slider assignment.

| Condition | Verdict |
|---|---|
| SCCM + Intune (co-management) | `[]` Verify workload slider |
| Multiple management tools | `[]` Risk of conflicting policies |
| Single management tool | `[i]` Noted for escalation |
| No management tools | `[i]` Standalone, locally controlled |

##### Check 8 -- Pending .NET / Visual C++ Prerequisites

**Visual C++ Redistributable:**
- Scans Uninstall registry for `Microsoft Visual C++ * Redistributable`
- Classifies as modern (2015+) vs legacy (2005-2014)

**Pending .NET updates:**
- Checks CBS PackagesPending for NetFx/NDP entries

| Condition | Verdict |
|---|---|
| Modern VC++ (2015+) present | `[OK]` |
| Legacy-only VC++ | `[]` No modern redistributable |
| No VC++ at all | `[]` Missing, some servicing may fail |
| Pending .NET CBS package | `[]` Reboot may be required |

#### Example Output (Healthy, Intune-Managed)

```
=== Windows Update Agent & Environment Audit ===

--- WU Agent ---
[i]   WU Agent Version
       Agent version: 10.0.19041.3636

--- OS Build & Edition ---
[i]   OS Build & Edition
       Microsoft Windows 11 Pro 23H2 (Build 22631.4890)
[OK]  Build Eligibility
       Build 22631 (Windows 11 23H2) is in service and receiving security updates.
       Home/Pro EOS Nov 2025, Enterprise Nov 2026.

--- .NET Framework ---
[OK]  .NET Framework Version
       .NET Framework 4.8.1 (Release 533325). Modern version, no WU concerns.

--- PowerShell ---
[OK]  PowerShell Version
       PowerShell 5.1.22621.4890 (CLR 4.0.30319.42000). Expected version.

--- Third-Party AV ---
[OK]  Third-Party AV
       No third-party AV detected. Only Windows Defender active. No WU interference expected.

--- Update Management ---
[i]   Intune MDM Enrollment
       Device is enrolled in Intune MDM. Update policies may be managed via Intune Update Rings.

--- Prerequisites ---
[OK]  Visual C++ Redistributable
       Modern Visual C++ Redistributable (2015-2022) installed. 4 package(s) total.

RESULT: No environment issues detected. WU agent and machine environment look healthy.

NEXT:   If third-party AV flagged  -> consider temporarily disabling or excluding WU from AV scanning
        If SCCM/Intune managing    -> escalate to the MDM admin, not WU directly
        If no issues found         -> run WU008 WUDatastoreRepair for deeper repair
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| Service health, disk space, pending reboots, recent failures, cache | WU001 WUQuickHealth |
| GPO/MDM/UX policy settings, WSUS config, deferrals, pause, active hours | WU002 WUPolicyAudit |
| DNS, HTTPS connectivity, proxy, VPN, metered connection | WU003 WUNetworkCheck |
| TLS 1.2, .NET crypto settings, clock drift, root certs, FIPS | WU004 WUTlsCertCheck |
| DISM health, CBS.log, SFC, component store | WU005 WUComponentHealth |
| Event log timeline, HRESULT extraction, failure patterns | WU006 WUEventTimeline |
| Datastore repair, COM re-registration, BITS cleanup | WU008 WUDatastoreRepair |

**Overlap notes:**
- WU002 checks whether WSUS is *configured* (WUServer registry). WU007 checks whether SCCM/Intune/PatchMyPC are *installed as products*. Different question: "what source is configured?" vs "which tools could be controlling updates?"
- DEF003 queries SecurityCenter2 for deep Defender coexistence analysis (bitmask, ghosts, remnants). WU007 queries SecurityCenter2 for lightweight WU-interference flagging. Different diagnostic domains.
- WU004 checks .NET Framework *crypto settings* (SchUseStrongCrypto). WU007 checks .NET Framework *version*. Completely different properties.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 8 check groups: WU agent version from Auto Update/WindowsUpdate registry, OS edition/build/UBR from NT CurrentVersion with CIM fallback and LTSC/Server detection, .NET Framework version decode from NDP v4 Full Release DWORD (4.5 through 4.8.1 mapping), PowerShell and CLR version from PSVersionTable, feature update eligibility against 11-entry hardcoded version table (Win10 2004-22H2, Win11 21H2-26H1 ARM64 build 28000) with OK/EXT/EOS verdicts, third-party AV detection via SecurityCenter2 WMI (workstations) + Uninstall registry scan with 10-vendor known-problematic interference table, update management tool inventory (SCCM ccmexec, Intune MDM enrollment, PatchMyPC, ManageEngine, Automox, WSUS cross-reference) with co-management conflict detection, Visual C++ Redistributable modern/legacy classification and pending .NET CBS package detection. |

---
## Defender & AV Suite

### DEF001 -- DEFStatusTriage

**Version:** 2.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

30-second vital-signs snapshot of antivirus and Defender health. Answers the question every tech asks when Intune reports "non-compliant" for antivirus:

> Is Defender actually running and protecting this machine? If not, what's blocking it -- and who do I call next?

This is the entry point for all Defender/AV troubleshooting. Run this first; its output will tell you which deeper diagnostic to run next.

#### Usage

```powershell
Invoke-Indago -Name DEFStatusTriage
```

#### Parameters

None.

#### What It Checks

##### Check 1 -- Security Center AV Products

Queries `ROOT\SecurityCenter2\AntiVirusProduct` via `Get-CimInstance` and **decodes the `productState` bitmask** into human-readable fields. This is exactly what Intune queries to determine AV compliance.

For each registered product, the script reports:

| Field | Source | Meaning |
|-------|--------|---------|
| State | Bits 12-15 (`-band 0xF000`) | On, Off, Snoozed, or Expired |
| Signatures | Bits 4-7 (`-band 0x00F0`) | Current or Outdated |
| Origin | Bits 8-11 (`-band 0x0F00`) | Microsoft or Third-party |

**productState Bitmask Reference:**

| Bits | Mask | Value | Meaning |
|------|------|-------|---------|
| 12-15 | `0xF000` | `0x1000` | Engine On |
| 12-15 | `0xF000` | `0x0000` | Engine Off |
| 12-15 | `0xF000` | `0x2000` | Engine Snoozed |
| 12-15 | `0xF000` | `0x3000` | Engine Expired |
| 4-7 | `0x00F0` | `0x0000` | Signatures Up-to-date |
| 4-7 | `0x00F0` | `0x0010` | Signatures Outdated |
| 8-11 | `0x0F00` | `0x0100` | Microsoft (Windows Defender) |
| 8-11 | `0x0F00` | `0x0000` | Third-party vendor |

**Ghost registration detection:** For non-Defender products, the script checks whether the reporting executable (`pathToSignedReportingExe`) actually exists on disk. If the executable is missing, the product was uninstalled but its Security Center registration persists -- a "ghost" that can force Defender into passive mode while providing no protection.

**Windows Server:** The `SecurityCenter2` namespace is not available on Windows Server. The script reports `[i]` and skips to the remaining checks, which still work on Server.

##### Check 2 -- Defender Status (Get-MpComputerStatus)

Queries the Defender subsystem directly, bypassing Security Center. This reveals the *ground truth* of what Defender is actually doing.

| Property | Verdict Logic |
|----------|--------------|
| `AMRunningMode` = `Normal` + `RealTimeProtectionEnabled` = `$true` | `[OK]` Active and protecting |
| `AMRunningMode` = `Passive Mode` + third-party AV present | `[i]` Expected behavior |
| `AMRunningMode` = `Passive Mode` + NO third-party AV | `[!!]` Ghost registration -- machine likely unprotected |
| `AMRunningMode` = `Normal` + `RealTimeProtectionEnabled` = `$false` | `[!!]` Primary but not scanning |
| `AMRunningMode` = `EDR Block Mode` | `[i]` AV passive, EDR detections blocked |

**Definition age thresholds:**

| Age | Verdict | Meaning |
|-----|---------|---------|
| 0-1 days | `[OK]` | Definitions are current |
| 2-3 days | `[!]` Warning | Slightly behind |
| > 3 days | `[!!]` Issue | Stale -- run DEF002 |

**Scan age thresholds** (only when Defender is active, not passive):

| Scan Type | Threshold | Verdict |
|-----------|-----------|---------|
| Quick scan | > 14 days | `[!]` Warning |
| Full scan | > 30 days | `[!]` Warning |

Also reports platform version, engine version, NIS engine version, and tamper protection status as informational items.

##### Check 3 -- Core Defender Services

| Service | Name | Expected State |
|---------|------|----------------|
| Windows Defender Antivirus | `WinDefend` | Automatic -- should always be running |
| Network Inspection Service | `WdNisSvc` | Manual -- starts on demand |

**Verdict logic (same demand-start pattern as WU001):**
- `Disabled` on any service --> `[!!]`
- `Stopped` with `Automatic` start type --> `[!!]` (should be running)
- `Stopped` with `Manual` start type --> `[OK]` (normal demand-start)
- `Running` --> `[OK]`
- Service not found --> `[!!]` (Defender may not be installed)

##### Check 4 -- Defender for Endpoint (MDE Sensor)

Checks the `Sense` service (Defender for Endpoint / MDE agent):

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Service not found | `[i]` | Device not onboarded to MDE (may be expected) |
| Disabled | `[!!]` | MDE sensor blocked from starting |
| Stopped | `[!!]` | MDE sensor not running |
| Running + OnboardingState = 1 | `[OK]` | Running and onboarded, reports OrgId |
| Running + onboarding unclear | `[!]` | Running but onboarding state needs verification |

Onboarding status is read from `HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status`.

##### Check 5 -- Signal Gap Analysis

Cross-references Security Center (Check 1) with Defender ground truth (Check 2) to catch scenarios that no individual check can detect alone:

| Scenario | Verdict | Meaning |
|----------|---------|---------|
| Defender passive + no third-party AV registered | `[!!]` Critical | Ghost registration -- nobody is protecting |
| Defender active + third-party AV also active | `[!!]` | Dual-engine conflict -- severe performance issues |
| All consistent | `[OK]` | Security Center and Defender agree |

Skipped with `[i]` if Security Center was unavailable (Windows Server) or Defender status could not be queried.

#### Example Output (Healthy System with Defender Only)

```
=== Defender & AV Status Triage ===

[OK]  Security Center: Windows Defender
       State: On, Signatures: Current, Origin: Microsoft.
[OK]  Defender Running Mode
       Mode: Normal. Real-time protection: Enabled. Defender is active and protecting.
[OK]  Definition Age
       0 day(s) old (last updated: 2026-04-01 14:30). Definitions are current.
[OK]  Scan History
       Quick scan: 1 day(s) ago. Full scan: 5 day(s) ago.
[i]   Platform Info
       Product: 4.18.24090.11, Engine: 1.1.24090.11, NIS Engine: 1.1.24090.11.
[i]   Tamper Protection
       Enabled. Defender settings are protected from unauthorized changes.
[OK]  Windows Defender Antivirus (WinDefend)
       Running, start type: Automatic. Operational.
[OK]  Network Inspection Service (WdNisSvc)
       Stopped, start type: Manual. This is expected -- service starts on demand.
[OK]  Defender for Endpoint (Sense)
       Running, onboarded. OrgId: abc12345-def6-7890-abcd-ef1234567890.
[OK]  Signal Gap Analysis
       Security Center and Defender ground truth are consistent.

RESULT: No issues detected. Defender appears healthy.

NEXT:   If Defender not running       -> restart WinDefend service or run DEF008 DEFRemediation
        If definitions stale          -> run DEF002 DEFDefinitionHealth
        If third-party AV detected    -> run DEF003 DEFThirdPartyAV
        If passive mode unexpected    -> run DEF003 DEFThirdPartyAV (likely ghost registration)
        If RTP disabled               -> run DEF004 DEFRealtimeProtection
        If Security Center mismatch   -> run DEF003 DEFThirdPartyAV
```

#### Scope Boundaries

DEF001 is deliberately scoped to fast vital signs. The following concerns are handled by other scriptlets:

| Concern | Handled By |
|---------|-----------|
| Definition update sources, WSUS/MMPC config, connectivity | DEF002 DEFDefinitionHealth |
| Third-party AV remnant registry scanning, ghost cleanup | DEF003 DEFThirdPartyAV |
| Real-time protection deep diagnostics, exclusions, ASR rules | DEF004 DEFRealtimeProtection |
| GPO vs MDM policy side-by-side comparison | DEF005 DEFPolicyConflict |
| Platform/engine version comparison against known-good | DEF006 DEFPlatformVersion |
| Event log timeline, threat history, error codes | DEF007 DEFEventAnalysis |
| Service reset, ghost cleanup, forced updates, remediation | DEF008 DEFRemediation |

#### Version History

| Version | Changes |
|---------|---------|
| 2.0 | Complete rewrite. Replaced `DiagnoseDefenderSensor`. Shifted focus from MDE/EDR to core AV compliance while retaining Sense service check. Added Security Center `productState` bitmask decoding, `AMRunningMode` passive mode detection, ghost registration detection (exe path validation), signal gap analysis (Security Center vs Defender cross-reference), `NEXT:` footer routing, `[!]` warning tier. Removed MDE cloud connectivity tests (belong in network diagnostics). |
| 1.0 | Original `DiagnoseDefenderSensor` -- MDE Sense service, onboarding, connectivity, basic AV checks. |

---

### DEF002 -- DEFDefinitionHealth

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Diagnoses **why** Defender definitions are stale. DEF001 tells the tech "definitions are X days old." DEF002 answers the follow-up: is the update source misconfigured, is the CDN unreachable, is the scheduled task broken, or is policy blocking updates?

In managed environments, stale definitions are the #1 compliance failure. The cause is almost never "Defender is broken" -- it's a WSUS server that doesn't approve Defender defs, a GPO that omits the Microsoft CDN from the fallback order, or a scheduled task that vanished after an in-place upgrade.

#### Usage

```powershell
Invoke-Indago -Name DEFDefinitionHealth
```

No parameters. The script reads all relevant sources automatically.

#### What It Checks

**Check 1: Definition Age Analysis**

Reports all three signature types with **hourly** precision (DEF001 only reports days):

| Signature Type | CIM Properties Used | Thresholds |
|---|---|---|
| Antivirus | `AntivirusSignatureLastUpdated`, `AntivirusSignatureAge` | `[OK]` <= 24h, `[!]` 24-48h, `[!!]` > 48h |
| Antispyware | `AntispywareSignatureLastUpdated`, `AntispywareSignatureAge` | Same |
| NIS (Network Inspection) | `NISSignatureLastUpdated`, `NISSignatureAge` | Same |

Special cases:
- **65535 sentinel**: If signature age = 65535, definitions have **never** been updated since OS install. Reported as `[!!] NEVER UPDATED`.
- **Server 2022 WMI blank**: If `Get-MpComputerStatus` returns null, WMI provider may be unregistered. Reported with remediation guidance.

**Check 2: Update Source Configuration**

Registry path: `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates`

| Registry Value | What We Report |
|---|---|
| `FallbackOrder` | Decoded priority list (WSUS -> Microsoft Update -> MMPC -> FileShares). `[!]` if WSUS-only with no Microsoft CDN fallback. |
| `DefinitionUpdateFileSharesSources` | UNC paths if `FileShares` is in fallback order. |
| `ForceUpdateFromMU` | Whether Microsoft Update fallback is explicitly allowed (1) or blocked (0). |
| `SignatureUpdateInterval` | Polling frequency in hours. `[!!]` if set to 0 (polling completely disabled). |
| `SignatureUpdateCatchupInterval` | Days before catch-up triggers after missed updates. |
| `DisableScheduledSignatureUpdateOnBattery` | `[!]` if set to 1 -- laptops may fall out of compliance on battery. |

Additional check: `SetPolicyDrivenUpdateSourceForOtherUpdates` at the WindowsUpdate policy path. If set to 1 by Co-Management, this hijacks Defender updates away from WSUS to cloud -- flagged as `[!]` with explanation.

**Check 3: Update Source Connectivity**

TCP 443 reachability test (3-second timeout) to Microsoft CDN endpoints:

| Endpoint | Purpose | Verdict if Unreachable |
|---|---|---|
| `definitionupdates.microsoft.com` | Primary CDN for Security Intelligence updates | `[!!]` -- definitions cannot update |
| `go.microsoft.com` | Alternate Download Location for cumulative catch-up updates | `[!]` -- catch-up updates will fail |

WSUS reachability is **not** duplicated here (WU002 handles it). If WSUS is in the fallback order, an informational note directs the tech to WU002.

**Check 4: Recent Update Failure Events (last 48h)**

Event log: `Microsoft-Windows-Windows Defender/Operational`

| Event ID | Meaning | Handling |
|---|---|---|
| 2000 | Signature update succeeded | Count in window. If none and definitions stale, pipeline is broken. |
| 2001 | Signature update **failed** | `[!!]` with HRESULT translation. Most recent failure shown. |
| 2003 | Engine update failed | `[!!]` -- engine updates are distinct from sig updates. |

HRESULT translation table (9 codes):

| HRESULT | Translation |
|---|---|
| `0x8024002E` | WU_E_WU_DISABLED -- Windows Update service disabled or access blocked |
| `0x8024402C` | DNS failure for update server |
| `0x80072EE7` | DNS failure for Microsoft CDN endpoints |
| `0x80072EFD` | Connection timed out to update server |
| `0x80240022` | Signature payload corrupted in transit |
| `0x8050800C` | Downloaded definitions incompatible with engine version |
| `0x80508020` | Internal engine config error, needs service restart |
| `0x800106BA` | RPC server unavailable -- Defender service crashed or MpCmdRun.exe missing |
| `0x80070643` | MSI/extraction failure during signature injection |

**Check 5: Scheduled Task Health**

Tasks under `\Microsoft\Windows\Windows Defender\`:

| Task Name | What It Does |
|---|---|
| `Windows Defender Scheduled Scan` | Evaluates catch-up and downloads definitions before scanning |
| `Windows Defender Cache Maintenance` | Purges stale definition delta files |
| `Windows Defender Cleanup` | Removes legacy definition files to prevent disk bloat |
| `Windows Defender Verification` | Periodic verification of Defender component integrity |

For each task: exists? enabled? last run result? Traps `0x2` (ERROR_FILE_NOT_FOUND) specifically -- this means MpCmdRun.exe is missing or the task XML path is corrupt.

#### Output Structure

```
=== Defender Definition & Signature Health ===

--- Definition Age ---
[OK]  Antivirus Signatures
       4.2 hours old (last updated: 2026-04-02 19:15 UTC). Definitions are current.
[OK]  Antispyware Signatures
       4.2 hours old (last updated: 2026-04-02 19:15 UTC). Current.
[OK]  NIS (Network Inspection) Signatures
       4.2 hours old (last updated: 2026-04-02 19:15 UTC). Current.

--- Update Source Configuration ---
[OK]  Signature Update Source (GPO)
       FallbackOrder: WSUS/SCCM -> Microsoft Update -> Microsoft Malware Protection Center (ADL).
       Microsoft CDN is included as a fallback. Update path has redundancy.
[i]   Update Schedule: Update check every 4 hour(s). catch-up after 1 day(s) of missed updates.

--- Update Source Connectivity ---
[OK]  definitionupdates.microsoft.com:443 -- Reachable.
       Primary CDN for Security Intelligence updates.
[OK]  go.microsoft.com:443 -- Reachable.
       Alternate Download Location (ADL) for cumulative catch-up updates.

--- Recent Update Events (last 48h) ---
[OK]  No signature update failures in the last 48 hours.
[i]   Last successful update: 2026-04-02 19:15 (Event 2000).

--- Scheduled Tasks ---
[OK]  Windows Defender Scheduled Scan
       Enabled. Last result: 0 (success).
[OK]  Windows Defender Cache Maintenance
       Enabled. Last result: 0 (success).
[OK]  Windows Defender Cleanup
       Enabled. Last result: 0 (success).
[OK]  Windows Defender Verification
       Enabled. Last result: 0 (success).

RESULT: No issues detected. Definition update pipeline is healthy.

NEXT:   If update source unreachable      -> check network/proxy (see WU003 WUNetworkCheck)
        If WSUS blocking definitions      -> approve Defender definitions on WSUS or add MMPC fallback
        If scheduled tasks missing         -> run DEF008 DEFRemediation to recreate
        If connectivity OK but still fail  -> run DEF006 DEFPlatformVersion (platform may be too old)
        If running WSUS                    -> run WU002 WUPolicyAudit to verify WSUS reachability
```

#### Boundary with Other Scriptlets

| Scriptlet | What it handles (NOT DEF002's job) |
|---|---|
| DEF001 DEFStatusTriage | AV running mode, Security Center bitmask, services, scan history, tamper protection, signal gap analysis |
| DEF003 DEFThirdPartyAV | Third-party AV conflicts, ghost registrations, remnant scan, passive mode analysis |
| DEF004 DEFRealtimeProtection | RTP state, tamper protection diagnostics, exclusions, ASR rules |
| DEF005 DEFPolicyConflict | Full GPO vs MDM policy audit for Defender settings |
| DEF006 DEFPlatformVersion | Platform/engine version freshness, update path analysis |
| DEF007 DEFEventAnalysis | Full event timeline, threat history, comprehensive error code analysis |

#### Changelog

| Version | Changes |
|---------|---------|
| 1.0 | Initial release. 5 check groups: definition age with hourly precision (AV, Antispyware, NIS), update source configuration (GPO FallbackOrder, polling interval, battery policy, Co-Management sabotage), CDN connectivity (definitionupdates.microsoft.com, go.microsoft.com with 3s TCP timeout), recent update failure events (48h window, 9-code HRESULT table), scheduled task health (4 tasks, existence/state/last result). |

---

### DEF003 -- DEFThirdPartyAV

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Determines which AV product is actually primary, whether coexistence is working correctly, and whether remnants of uninstalled AV products are causing ghost states. This is the scriptlet that generates the **most confusion in the field** -- a third-party AV was uninstalled but its Security Center registration persists, forcing Defender into passive mode while nobody is actually protecting the machine.

DEF001 detects "Defender is passive" or "ghost detected." DEF003 tells the tech **exactly which product, which GUID, which remnants, and what to do next**.

#### Usage

```powershell
Invoke-Indago -Name DEFThirdPartyAV
```

No parameters.

#### What It Checks

##### Check 1 -- Security Center Deep Enumeration

Queries `ROOT\SecurityCenter2\AntiVirusProduct` via `Get-CimInstance` and reports **every** registered product with full detail.

For each product, the script reports:

| Field | Source | What It Shows |
|-------|--------|---------------|
| Display Name | `displayName` | Product name |
| Instance GUID | `instanceGuid` | For DEF008 remediation targeting |
| Product State | `productState` bitmask decoded | Engine On/Off/Snoozed/Expired, Signatures Current/Outdated, Origin MS/Third-party |
| Product Exe | `pathToSignedProductExe` | Full path + `Test-Path` result |
| Reporting Exe | `pathToSignedReportingExe` | Full path + `Test-Path` result |

**Verdicts:**

| Condition | Verdict |
|-----------|---------|
| Defender On | `[OK]` |
| Defender Off/Snoozed/Expired | `[!]` |
| Third-party registered, engine On, exe exists | `[i]` (expected) |
| Third-party registered, exe MISSING | `[!!]` Ghost registration |
| Third-party registered, engine Off/Snoozed/Expired | `[!]` Not protecting |

**Windows Server:** `SecurityCenter2` namespace unavailable. Reports `[i]` and skips to remaining checks.

##### Check 2 -- AV Remnant Scan

Scans for leftover artifacts from 10 major vendors across three categories. Only flags items where the vendor is NOT registered in Security Center (if registered and active, the artifact is expected).

**2a: Registry Remnants**

| Vendor | Registry Path |
|--------|---------------|
| Norton / Symantec | `HKLM:\SOFTWARE\Symantec` |
| McAfee / Trellix | `HKLM:\SOFTWARE\McAfee` |
| Kaspersky | `HKLM:\SOFTWARE\KasperskyLab` |
| ESET | `HKLM:\SOFTWARE\ESET` |
| Sophos | `HKLM:\SOFTWARE\Sophos` |
| Trend Micro | `HKLM:\SOFTWARE\TrendMicro`, `WOW6432Node\TrendMicro` |
| Avast / AVG | `HKLM:\SOFTWARE\AVAST Software`, `HKLM:\SOFTWARE\AVG` |
| Bitdefender | `HKLM:\SOFTWARE\Bitdefender` |
| Webroot | `HKLM:\SOFTWARE\WRData` |
| Malwarebytes | `HKLM:\SOFTWARE\Malwarebytes` |

Verdict: `[!]` if vendor not in Security Center but registry key exists.

**2b: Leftover Services**

Checks for services from known AV vendors using wildcard patterns (e.g. `McAfee*`, `Norton*`, `Sophos*`). For each service found where the vendor is not in Security Center:

| Condition | Verdict |
|-----------|---------|
| Service Disabled | `[!]` Leftover from uninstall |
| Service Auto start but Stopped | `[!!]` Orphaned, trying to start and failing |
| Service Running | `[!]` Running but not registered, investigate |

**2c: Leftover Filter Drivers**

Checks `C:\Windows\System32\drivers\` for known vendor kernel driver files:

| Vendor | Driver Files |
|--------|-------------|
| McAfee / Trellix | `mfehidk.sys`, `mfefirek.sys`, `mfencbdc.sys` |
| ESET | `ehdrv.sys`, `epfwwfp.sys` |
| Kaspersky | `klif.sys`, `klhk.sys`, `klboot.sys` |
| Sophos | `savonaccess.sys`, `SophosED.sys` |
| Trend Micro | `tmwfp.sys`, `TmXPflt.sys` |
| Avast / AVG | `aswSP.sys`, `avgmfx64.sys`, `aswids.sys` |
| Bitdefender | `trufos.sys`, `bdsandbox.sys` |
| Webroot | `WRkrn.sys` |
| Malwarebytes | `mbam.sys`, `MBAMSwissArmy.sys`, `farflt.sys` |
| Norton / Symantec | `n360drv.sys`, `srtsp64.sys` |

Verdict: `[!]` -- "Leftover filter driver. May cause I/O conflicts or BSODs. Use vendor removal tool."

##### Check 3 -- Ghost Registration Analysis

Cross-references Check 1 (Security Center) with Defender's `AMRunningMode` from `Get-MpComputerStatus` to identify exact ghost/protection-gap scenarios:

| Condition | Verdict |
|-----------|---------|
| Ghost product + Defender Passive | `[!!]` **CRITICAL: Endpoint UNPROTECTED.** Reports product name and GUID for DEF008. |
| Ghost product + Defender Normal | `[!]` Ghost exists but Defender recovered. Cleanup still recommended. |
| Third-party On but engine Off/Snoozed/Expired + Defender Passive | `[!!]` Protection gap -- nobody is scanning. |
| Third-party On, engine On + Defender Passive | `[OK]` Expected coexistence. |
| Third-party On + Defender also Normal | `[!]` Dual-engine conflict -- performance risk. |
| Defender sole protector, Normal mode | `[OK]` No conflicts. |

##### Check 4 -- Defender Policy Overrides

Checks for legacy GPO and MDM keys that disable Defender:

**GPO path:** `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender`

| Value | Verdict if = 1 |
|-------|----------------|
| `DisableAntiSpyware` | `[!!]` Defender disabled by GPO |
| `DisableAntiVirus` | `[!!]` Defender AV component disabled by GPO |

**MDM path:** `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender`

| Value | Verdict if = 0 |
|-------|----------------|
| `AllowRealtimeMonitoring` | `[!!]` MDM disabling real-time monitoring |

**Entanglement detection:** If GPO sets `DisableAntiSpyware = 1` AND MDM sets `AllowRealtimeMonitoring = 1`, flags `[!!]` policy conflict -- legacy GPO takes precedence unless `MDMWinsOverGP` is configured.

> **Platform note:** As of Defender platform 4.18.2108.4, `DisableAntiSpyware` is ignored if Tamper Protection is enabled or the device is MDE-onboarded. DEF003 still flags the key because its presence causes compliance report confusion.

#### Example Output (Healthy System, Defender Only)

```
=== Third-Party AV Conflict & Coexistence ===

--- Security Center AV Products ---
[OK]  Windows Defender
       State: On, Signatures: Current, Origin: Microsoft.
       Exe: C:\ProgramData\...\MsMpEng.exe (found).

--- AV Remnant Scan ---
[OK]  Registry Remnants
       No third-party AV remnant registry keys detected.

--- Leftover AV Services ---
[OK]  Leftover AV Services
       No orphaned third-party AV services found.

--- Leftover Filter Drivers ---
[OK]  Leftover Filter Drivers
       No orphaned third-party AV filter drivers found in the drivers directory.

--- Ghost Registration Analysis ---
[OK]  No Ghost Registrations
       Defender is the sole and active protector. No third-party conflicts.

--- Defender Policy Overrides ---
[OK]  DisableAntiSpyware (GPO)
       Not set or set to 0. Defender is allowed by Group Policy.
[OK]  DisableAntiVirus (GPO)
       Not set or set to 0. Defender AV component is allowed.

RESULT: No issues detected. No third-party AV conflicts or remnants found.

NEXT:   If ghost registration found       -> run DEF008 DEFRemediation to clean up
        If third-party AV active + working -> Defender passive mode is correct; verify
          compliance policy accepts this configuration
        If DisableAntiSpyware present      -> run DEF008 DEFRemediation to remove (if not policy-managed)
        If remnant drivers/services found  -> may need vendor-specific removal tool
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| AV bitmask basics, services, MDE sensor, signal gap (triage) | DEF001 DEFStatusTriage |
| Definition staleness, update sources, CDN connectivity | DEF002 DEFDefinitionHealth |
| Real-time protection, tamper protection, exclusions, ASR rules | DEF004 DEFRealtimeProtection |
| Full GPO vs MDM policy comparison | DEF005 DEFPolicyConflict |
| Platform/engine version freshness | DEF006 DEFPlatformVersion |
| Event log timeline, threat history | DEF007 DEFEventAnalysis |
| Ghost cleanup, service reset, remediation | DEF008 DEFRemediation |

DEF001 does basic ghost detection (exe path check + signal gap). DEF003 does **deep** ghost analysis: full Security Center enumeration with instance GUIDs, 10-vendor remnant scan across registry/services/drivers, and policy override detection.

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 4 check groups: Security Center deep enumeration with `productState` bitmask decode, exe path validation (`pathToSignedProductExe` + `pathToSignedReportingExe`), and instance GUID reporting. AV remnant scan across 10 vendors (registry keys, leftover services via wildcard patterns, leftover filter drivers in `System32\drivers`). Ghost registration analysis cross-referencing Security Center with `AMRunningMode` (5 scenarios including protection gap detection). Defender policy overrides (`DisableAntiSpyware`, `DisableAntiVirus`) at GPO and MDM paths with entanglement detection (GPO disable + MDM enable conflict). |

---

### DEF004 -- DEFRealtimeProtection

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Focuses on cases where Defender is present and primary but Real-Time Protection won't stay enabled, or where the protection surface is degraded by misconfigured exclusions or ASR rules. DEF001 tells the tech "RTP is off." DEF004 tells them **who turned it off, at what policy level, whether Tamper Protection is blocking their fix, whether the engine process is healthy, whether exclusions are recklessly broad, and whether ASR rules are causing the compat friction that led someone to disable RTP in the first place**.

#### Usage

```powershell
Invoke-Indago -Name DEFRealtimeProtection
```

No parameters.

#### What It Checks

##### Check 1 -- Real-Time Protection State Deep Dive

Queries `MSFT_MpComputerStatus` via CIM and reports 4 RTP sub-components individually:

| Property | What It Shows |
|----------|---------------|
| `RealTimeProtectionEnabled` | Master RTP switch |
| `OnAccessProtectionEnabled` | File-system read/write interception |
| `BehaviorMonitorEnabled` | Heuristic/behavioral analysis |
| `IoavProtectionEnabled` | IE/Edge download scanning |

Also reports `RealTimeScanDirection` (0 = both, 1 = incoming only, 2 = outgoing only). Flags non-zero as `[!]`.

**Source attribution:** When any sub-component is disabled, identifies the source by checking:

1. **GPO:** `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection` (`DisableRealtimeMonitoring`, `DisableBehaviorMonitoring`, `DisableOnAccessProtection`, `DisableIOAVProtection`)
2. **MDM:** `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender` (`AllowRealtimeMonitoring`, `AllowBehaviorMonitoring`)
3. **Local preference:** `MSFT_MpPreference.DisableRealtimeMonitoring`

| Condition | Verdict |
|-----------|---------|
| All sub-components enabled | `[OK]` |
| Any sub-component disabled | `[!!]` with source attribution |
| Scan direction != 0 | `[!]` partial scanning |

> **Key distinction from DEF001:** DEF001 reports `RealTimeProtectionEnabled` as a single boolean. DEF004 breaks RTP into 4 sub-components and identifies who disabled each one.

##### Check 2 -- Tamper Protection Diagnostics

Reads `HKLM:\SOFTWARE\Microsoft\Windows Defender\Features`:

| Value | Meaning |
|-------|---------|
| `TamperProtection` = 5 | `[OK]` Actively enabled and locked |
| `TamperProtection` = 4 | `[!]` Disabled (was previously enabled) |
| `TamperProtection` = 0 / absent | `[!]` Not configured |
| `TamperProtectionSource` = 5 | Protection from Microsoft signatures/cloud |
| `TPExclusions` = 1 | Exclusions are tamper-protected (Intune-only) |
| `ManagedDefenderProductType` = 6 | Intune standalone |
| `ManagedDefenderProductType` = 7 | Co-managed (Intune + ConfigMgr) |

**Cross-reference:** If RTP is disabled AND Tamper Protection is active (value = 5), reports `[i]` noting that RTP was disabled at a level above tamper protection (cloud policy or MDM). Local re-enable attempts will be silently reverted.

> **Key distinction from DEF001:** DEF001 shows tamper protection as a one-line informational. DEF004 decodes the full registry values, reports the protection source, TPExclusions status, and management type.

##### Check 3 -- MsMpEng.exe Process Health

Queries `Get-Process -Name MsMpEng` for the antimalware engine process:

| Metric | Threshold | Verdict |
|--------|-----------|---------|
| Process not found | -- | `[!!]` Engine not running |
| Working set > 1 GB | > 1073741824 bytes | `[!!]` Possible scan hang or definition corruption |
| Working set > 500 MB | -- | `[!]` Elevated, monitor |
| Working set <= 500 MB | -- | `[OK]` Normal |
| CPU > 30% sustained | 2-second sample | `[!!]` Possible scan loop |
| CPU > 10% sustained | -- | `[!]` Elevated CPU |
| CPU <= 10% | -- | `[OK]` Normal |

**CPU measurement:** Two snapshots of `TotalProcessorTime` 2 seconds apart, calculated as `delta / (elapsed * logicalProcessorCount)`. Reports PID, memory, CPU%, and uptime.

##### Check 4 -- Exclusion Audit

Reads `MSFT_MpPreference` for `ExclusionPath`, `ExclusionExtension`, and `ExclusionProcess`. Reports counts and flags dangerous patterns:

**Dangerous path patterns (11 rules):**

| Pattern | Severity | Reason |
|---------|----------|--------|
| `C:\` or `D:\` (root drive) | `[!!]` | Entire volume excluded |
| `C:\*` (root wildcard) | `[!!]` | All files on volume excluded |
| `C:\Windows` | `[!!]` | System directory excluded |
| `C:\Windows\Temp` | `[!!]` | Common malware staging location |
| `C:\Windows\Prefetch` | `[!]` | Malware can stage here |
| `C:\Program Files` | `[!]` | Broad, sometimes vendor-required |
| `%APPDATA%` in paths | `[!]` | User-context variable trap |
| `%LOCALAPPDATA%` in paths | `[!]` | User-context variable trap |
| `%USERPROFILE%` in paths | `[!]` | User-context variable trap |
| `*.*` at path level | `[!!]` | All files excluded |

**User-context variable trap:** When `%APPDATA%` is used in an exclusion, it resolves to `C:\Windows\system32\config\systemprofile\AppData\Roaming` in SYSTEM context -- not the user's actual folder. The exclusion misses its target and dangerously excludes the system profile instead.

**Dangerous extensions (10 types):** `.exe`, `.dll`, `.ps1`, `.bat`, `.cmd`, `.vbs`, `.js`, `.wsf`, `.scr`, `.com`

##### Check 5 -- ASR (Attack Surface Reduction) Rules

Reads `MSFT_MpPreference.AttackSurfaceReductionRules_Ids` and `AttackSurfaceReductionRules_Actions`. Maps 15 rule GUIDs to friendly names:

**Action decode:** 0 = Disabled, 1 = Block, 2 = Audit, 6 = Warn

**5 high-disruption rules** flagged with `[!]` when in Block mode:

| GUID (short) | Rule | Why It's Disruptive |
|---|---|---|
| `d4f940ab` | Block Office apps from creating child processes | Breaks COM add-ins, ERP integrations |
| `3b576869` | Block Office apps from creating executable content | Blocks legitimate deployment tools |
| `92e97fa1` | Block Win32 API calls from Office macros | Breaks financial modeling, automation |
| `9e6c4e1f` | Block credential stealing from LSASS | Conflicts with SSO and identity tools |
| `5beb7efe` | Block obfuscated script execution | False positives on minified/compiled scripts |

If high-disruption rules are in Block mode, notes that admins sometimes disable RTP as a workaround for ASR compat issues.

#### Example Output (Healthy System)

```
=== Real-Time Protection & Tamper Protection Diagnostics ===

--- Real-Time Protection State ---
[OK]  Real-Time Protection: Enabled
       All sub-components active: RTP, OnAccess, BehaviorMonitor, IOAV.
       Scan direction: Both incoming and outgoing.

--- Tamper Protection ---
[OK]  Tamper Protection: Active (value = 5)
       Source: Microsoft signatures/cloud defaults.
       Defender settings are protected from local tampering.
       Changes must come from Intune/MDE portal or cloud policy.
[i]   Exclusion Protection: Not tamper-protected (TPExclusions = 0)
       Local admins can add, modify, or remove AV exclusions.

--- MsMpEng.exe Process Health ---
[OK]  MsMpEng.exe (PID: 3456)
       Memory: 245 MB working set. Normal.
[OK]  CPU: 1.2% (measured over 2 seconds). Normal.
[i]   Uptime: 4 day(s).

--- Exclusion Audit ---
[OK]  Path Exclusions: None configured.
[OK]  Extension Exclusions: None configured.
[OK]  Process Exclusions: None configured.

--- ASR Rules ---
[i]   ASR Rules: Not configured
       No Attack Surface Reduction rules are active on this endpoint.
       Consider enabling high-value rules in Audit mode first.

RESULT: No issues detected. RTP and Tamper Protection appear healthy.

NEXT:   If disabled by GPO         -> run DEF005 DEFPolicyConflict to identify the source
        If tamper protection blocking changes -> changes must come from Intune cloud policy
        If MsMpEng stuck           -> restart WinDefend service or run DEF008 DEFRemediation
        If exclusions too broad    -> review with the security admin
        If ASR compat issues       -> switch high-disruption rules from Block to Audit
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Security Center bitmask, services, MDE sensor, signal gap | DEF001 DEFStatusTriage |
| Definition age, update sources, CDN connectivity | DEF002 DEFDefinitionHealth |
| Third-party AV conflict, ghost registrations, remnants | DEF003 DEFThirdPartyAV |
| DisableAntiSpyware / DisableAntiVirus (engine-level kill) | DEF003 DEFThirdPartyAV |
| Full GPO vs MDM policy side-by-side for all Defender settings | DEF005 DEFPolicyConflict |
| Platform/engine version freshness | DEF006 DEFPlatformVersion |
| Event log timeline, threat history | DEF007 DEFEventAnalysis |
| Service reset, ghost cleanup, remediation | DEF008 DEFRemediation |

**Overlap notes:**
- DEF003 checks `DisableAntiSpyware`/`DisableAntiVirus` (engine-level kill). DEF004 checks `DisableRealtimeMonitoring`/`DisableBehaviorMonitoring`/`DisableOnAccessProtection`/`DisableIOAVProtection` (sub-feature disables). No overlap.
- DEF001 shows tamper protection as a one-liner. DEF004 does the full registry decode with source, TPExclusions, and management type.
- DEF005 does full side-by-side policy comparison across ~15 Defender settings. DEF004 only reads policy sources for RTP-related settings to answer "why is RTP off?"

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 5 check groups: RTP sub-component breakdown (RTP, OnAccess, BehaviorMonitor, IOAV) with GPO/MDM/local source attribution via policy registry reads, Tamper Protection registry decode (TamperProtection 5/4/0 values, TamperProtectionSource, TPExclusions, ManagedDefenderProductType) with RTP cross-reference, MsMpEng.exe process health (working set 500MB/1GB thresholds, CPU 2-second dual-sample with 10%/30% thresholds, PID and uptime), exclusion audit via MSFT_MpPreference (11 dangerous path regex patterns including root drives, system folders, user-context variable traps, plus 10 dangerous extension types), ASR rule inventory (15-rule GUID-to-name table, action decode, 5 high-disruption rules flagged in Block mode). |

---

### DEF005 -- DEFPolicyConflict

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Detects policy source conflicts where GPO, Intune/MDM, and local preferences disagree on critical Defender settings. `Get-MpPreference` shows the effective merged result but never tells the tech **who set it** or whether two management systems are fighting. DEF005 answers: "For each critical Defender setting, what does GPO say, what does MDM say, and do they agree?"

This is the Defender equivalent of the firewall and BitLocker policy conflict scripts -- same side-by-side philosophy applied to the Defender surface area.

> **Key insight:** In GPO-to-Intune migrations, many organizations set `MDMWinsOverGP = 1` believing it covers all settings. It does NOT apply to Defender CSP settings. DEF005 catches this exact misconfiguration.

#### Usage

```powershell
Invoke-Indago -Name DEFPolicyConflict
```

No parameters.

#### What It Checks

##### Check 1 -- Core Protection Settings (Side-by-Side)

Reads 9 critical Defender settings from all 3 policy sources and displays side-by-side. Flags conflicts with `[!!]` and dangerous GPO overrides.

**Registry paths queried:**
- **GPO:** `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender` + subkeys
- **MDM:** `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender`
- **Local/Effective:** `Get-MpPreference`

**Settings covered:**

| Setting | GPO Value | MDM Value |
|---|---|---|
| Real-Time Protection | `DisableRealtimeMonitoring` | `AllowRealtimeMonitoring` |
| Behavior Monitoring | `DisableBehaviorMonitoring` | `AllowBehaviorMonitoring` |
| IOAV Protection | `DisableIOAVProtection` | `AllowIOAVProtection` |
| Cloud Protection (MAPS) | `SpynetReporting` | `AllowCloudProtection` |
| Sample Submission | `SubmitSamplesConsent` | `SubmitSamplesConsent` |
| Network Protection | `EnableNetworkProtection` | `EnableNetworkProtection` |
| PUA Protection | `PUAProtection` | `PUAProtection` |
| Controlled Folder Access | `EnableControlledFolderAccess` | `EnableControlledFolderAccess` |
| Scan Schedule Day | `ScanScheduleDay` | `ScanScheduleDay` |

**Conflict detection:**
- GPO and MDM both set but disagree -> `[!!]` CONFLICT
- GPO disables critical protection (RTP, Behavior, IOAV, Cloud) -> `[!!]` DANGEROUS
- Only one source sets a value -> `[OK]` with details
- Neither sets a value -> `[OK]` using defaults

**GPO inversion handling:** GPO uses `Disable*` naming (1 = disabled) while MDM uses `Allow*` naming (1 = enabled). The script normalizes this to correctly detect when GPO `DisableRealtimeMonitoring = 1` conflicts with MDM `AllowRealtimeMonitoring = 1`.

##### Check 2 -- Exclusion Source Comparison

Reads exclusion counts from all 3 policy sources per type (paths, extensions, processes). Reports whether exclusions come from multiple sources and whether they merge.

**Sources:**
- **GPO:** `HKLM:\...\Windows Defender\Exclusions\Paths`, `\Extensions`, `\Processes`
- **MDM:** `ExcludedPaths`, `ExcludedExtensions`, `ExcludedProcesses` at MDM path
- **Effective:** `Get-MpPreference` -> `ExclusionPath`, `ExclusionExtension`, `ExclusionProcess`

**Also checks:**
- `DisableLocalAdminMerge` -- if = 1, local exclusions configured via `Set-MpPreference` or the GUI are silently ignored. Only GPO/MDM exclusions apply.

| Condition | Verdict |
|---|---|
| Exclusions from single source | `[OK]` |
| Exclusions from GPO AND MDM simultaneously | `[!]` Multi-source, review for conflicts |
| `DisableLocalAdminMerge = 1` | `[!]` Local exclusions ignored |
| `DisableLocalAdminMerge` not set or = 0 | `[OK]` Merge behavior (default) |

> **Scope note:** DEF005 does NOT audit exclusions for dangerous patterns (that is DEF004 Check 4). DEF005 only answers "where are exclusions coming from, and is there a merge conflict?"

##### Check 3 -- ASR Rule Source Comparison

Reads ASR rule GUIDs and actions from GPO registry and compares against effective state from `Get-MpPreference`.

| Condition | Verdict |
|---|---|
| No ASR rules configured | `[i]` |
| GPO and effective actions agree | `[OK]` |
| GPO action differs from effective action | `[!]` Possible MDM/local override |

Reports conflicts by GUID short prefix (first 8 chars). Does not re-do full GUID-to-name mapping (that is DEF004 Check 5).

##### Check 4 -- ForceDefenderPassiveMode

Reads `HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection` -> `ForceDefenderPassiveMode`.

| Condition | Verdict |
|---|---|
| = 1, no third-party AV in SecurityCenter2 | `[!!]` Defender forced passive with no protection |
| = 1, third-party AV present | `[i]` Expected configuration |
| = 0 | `[OK]` Explicitly active |
| Not set | `[OK]` Security Center determines mode (default) |
| SecurityCenter2 unavailable (Server) | `[!]` Cannot verify, manual confirmation needed |

Third-party AV detection uses `ROOT\SecurityCenter2\AntiVirusProduct` with `productState` bitmask origin check (non-Microsoft = `0x0000` at bits 8-11).

##### Check 5 -- MDMWinsOverGP Assessment

Reads `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict` -> `MDMWinsOverGP`.

| Condition | Verdict |
|---|---|
| = 1, GPO Defender settings exist | `[!!]` FALSE SENSE OF SECURITY -- does NOT apply to Defender CSP |
| = 1, no GPO Defender settings | `[i]` Set but no conflicts |
| Not set or = 0 | `[OK]` Standard GPO precedence |

> **Critical architectural fact:** `MDMWinsOverGP` only applies to settings governed by the **Policy CSP**. It explicitly does NOT apply to settings managed by the **Defender CSP**. Even with `MDMWinsOverGP = 1`, a legacy GPO setting like `DisableRealtimeMonitoring = 1` will override Intune. This check catches this exact misconfiguration.

#### Example Output (Healthy System, Intune-Managed)

```
=== Defender Policy Source Conflict Detection ===

--- Core Protection Settings ---
[OK]  Real-Time Protection
       GPO: Not set. MDM: AllowRealtimeMonitoring = 1. Effective: Enabled.
[OK]  Behavior Monitoring
       GPO: Not set. MDM: AllowBehaviorMonitoring = 1. Effective: Enabled.
[OK]  IOAV Protection
       GPO: Not set. MDM: Not set. Effective: Enabled.
[OK]  Cloud Protection (MAPS)
       GPO: Not set. MDM: AllowCloudProtection = 1. Effective: 2.
[OK]  Sample Submission
       GPO: Not set. MDM: SubmitSamplesConsent = 3. Effective: 3.
[OK]  Network Protection
       GPO: Not set. MDM: EnableNetworkProtection = 1. Effective: 1.
[OK]  PUA Protection
       GPO: Not set. MDM: PUAProtection = 1. Effective: 1.
[OK]  Controlled Folder Access
       GPO: Not set. MDM: Not set. Effective: 0.
[OK]  Scan Schedule Day
       GPO: Not set. MDM: Not set. Effective: 0 (Everyday).

--- Exclusion Source Comparison ---
[OK]  Path Exclusions
       GPO: 0. MDM: 0. Effective: 0.
[OK]  Extension Exclusions
       GPO: 0. MDM: 0. Effective: 0.
[OK]  Process Exclusions
       GPO: 0. MDM: 0. Effective: 0.
[OK]  DisableLocalAdminMerge
       Not set or = 0. Local exclusions merge with GPO/MDM (default).

--- ASR Rule Source Comparison ---
[i]   ASR Rules: Not configured
       No ASR rules found in GPO or effective policy.

--- ForceDefenderPassiveMode ---
[OK]  ForceDefenderPassiveMode
       Not set. Defender mode determined by Security Center (default behavior).

--- MDMWinsOverGP Assessment ---
[OK]  MDMWinsOverGP
       Not set or = 0. GPO takes precedence over MDM (default behavior).

RESULT: No policy conflicts detected. GPO, MDM, and local settings are consistent.

NEXT:   If GPO conflicts found      -> remove conflicting GPO or migrate settings to Intune
        If ForcePassiveMode set      -> remove if no third-party AV is present
        If MDMWinsOverGP misleading  -> remove conflicting Defender GPO settings manually
        If exclusion merge conflict  -> review DisableLocalAdminMerge setting
        If no conflicts              -> run DEF006 DEFPlatformVersion to check platform health
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| AV running mode, Security Center bitmask, services, MDE sensor, signal gap | DEF001 DEFStatusTriage |
| Definition update sources, WSUS/MMPC config, connectivity | DEF002 DEFDefinitionHealth |
| Third-party AV remnants, ghost registrations, DisableAntiSpyware/DisableAntiVirus | DEF003 DEFThirdPartyAV |
| RTP sub-component source attribution, Tamper Protection, exclusion dangerous patterns, ASR GUID-to-name | DEF004 DEFRealtimeProtection |
| Platform/engine version comparison against known-good | DEF006 DEFPlatformVersion |
| Event log timeline, threat history, error codes | DEF007 DEFEventAnalysis |
| Service reset, ghost cleanup, remediation | DEF008 DEFRemediation |

**Overlap notes:**
- DEF004 checks `Disable*` registry values to answer "who disabled RTP?". DEF005 displays the same values side-by-side across all 3 sources to answer "do GPO and MDM agree on RTP?" Different question, complementary answers.
- DEF003 Check 4 checks `DisableAntiSpyware`/`DisableAntiVirus` (engine-level kill switches). DEF005 does NOT include these -- they are not policy-configurable Defender settings.
- DEF004 Check 4 audits exclusions for dangerous patterns. DEF005 Check 2 audits exclusion sources. No overlap.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 5 check groups: core protection settings side-by-side across GPO/MDM/Local for 9 settings (RTP, BehaviorMonitor, IOAV, MAPS, SampleSubmission, NetworkProtection, PUA, ControlledFolderAccess, ScanScheduleDay) with GPO inversion handling (Disable* vs Allow*), conflict detection, and dangerous pattern flagging. Exclusion source comparison (GPO/MDM/Local counts for paths, extensions, processes, plus DisableLocalAdminMerge). ASR rule source comparison (GPO vs effective action per GUID). ForceDefenderPassiveMode with SecurityCenter2 third-party AV cross-reference. MDMWinsOverGP assessment with Defender CSP limitation warning. |

---

### DEF006 -- DEFPlatformVersion

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Validates the structural health of the Microsoft Defender Antivirus **platform** (MoCAMP), the **antimalware engine**, and the **NIS engine**. These three components are independently versioned and updated on different cadences -- the platform monthly via KB4052623, the engine daily with definitions, and the NIS engine less frequently.

When the platform falls behind Microsoft's **N-2 support boundary**, the engine silently fails to ingest modern Security Intelligence payloads. The endpoint appears functional (services running, Defender "on") but is effectively unprotected. DEF006 catches this exact scenario -- the missing link between DEF002 (definitions stale) and DEF005 (no policy conflicts).

> **Key insight:** A deprecated platform is invisible to basic health checks. Services run, definitions download (but fail to apply), and Security Center reports "on." Only a direct version comparison against known-good baselines reveals the problem.

#### Usage

```powershell
Invoke-Indago -Name DEFPlatformVersion
```

No parameters.

#### What It Checks

##### Check 1 -- Component Version Comparison

Queries `Get-MpComputerStatus` (with CIM fallback to `MSFT_MpComputerStatus`) for three independently-versioned components:

| Property | Component | Update Vehicle | Cadence |
|---|---|---|---|
| `AMProductVersion` | Platform (MoCAMP) | KB4052623 | Monthly |
| `AMEngineVersion` | Antimalware engine | Definition updates | ~Daily |
| `NISEngineVersion` | Network Inspection engine | Less frequent | Varies |

**Hardcoded baselines (as of April 2026):**

| Component | Warning Threshold | Critical (N-2) Threshold |
|---|---|---|
| Platform | `4.18.26010.0` (~Jan 2026, 3 months behind) | `4.18.25100.0` (~Oct 2025, 6 months behind) |
| Engine | `1.1.26010.0` | `1.1.25100.0` |

**Verdict logic:**

| Condition | Verdict |
|---|---|
| At or above warning baseline | `[OK]` Current |
| Below warning but above critical | `[]` Approaching N-2 deprecation |
| Below critical baseline | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` CRITICALLY OUTDATED -- deprecated and unsupported |
| Version is `0.0.0.0` or empty | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` Defender may be broken |

NIS engine is reported as `[i]` informational only (no independent deprecation threshold).

> **Why hardcoded?** There is no native offline method to query the latest versions from Microsoft. The only options are parsing an RSS feed (requires internet, violates no-external-dependency rule) or hardcoding a conservative baseline. These thresholds should be updated in future scriptlet version bumps.

##### Check 2 -- Update Channel & Ring Configuration

Reads the update delivery channel configuration from three registry layers:

| Layer | Registry Path |
|---|---|
| GPO | `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Updates` |
| MDM | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender` |
| Local | `HKLM:\SOFTWARE\Microsoft\Windows Defender` |

**Values checked:** `PlatformUpdatesChannel`, `EngineUpdatesChannel`

**Integer-to-channel decode table:**

| Value | Channel | Description |
|---|---|---|
| 0 | Not Configured | Default (immediate GA) |
| 2 | Beta | Earliest adopter ring |
| 3 | Current (Preview) | Slight delay from Beta |
| 4 | Current (Staged) | Pilot production ring |
| 5 | Current (Broad) | Most conservative GA ring |
| 6 | Critical -- Time Delay | 48-hour intentional delay |

**Verdict logic:**

| Condition | Verdict |
|---|---|
| Channel 0-3 or not set | `[OK]` with decoded values |
| Channel 4+ (Staged/Broad/Delayed) | `[i]` Delayed ring -- intentional but explains version lag |

Also reports:
- `DefinitionUpdatesChannel` (GPO) if configured
- `PlatformUpdatesGradualRolloutPercentage` if configured (fleet throttling)

> **Scope note:** This does NOT duplicate DEF005's policy comparison. DEF005 compares protection settings (RTP, MAPS, ASR, etc.). DEF006 compares *update delivery ring* settings -- an entirely different policy surface.

##### Check 3 -- Platform Update Events (Last 30 Days)

Queries `Microsoft-Windows-Windows Defender/Operational` event log for platform-specific events.

**Success tracking:**

| Event ID | Significance |
|---|---|
| 2002 | Successful engine/platform update -- confirms update pipeline is working |

**Deprecation/expiration warnings:**

| Event ID | Name | Verdict |
|---|---|---|
| 2007 | `MALWAREPROTECTION_PLATFORM_ALMOSTOUTOFDATE` | `[]` Approaching N-2 |
| 5100 | `MALWAREPROTECTION_EXPIRATION_WARNING_STATE` | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` Grace period ending |
| 5101 | `MALWAREPROTECTION_DISABLED_EXPIRED_STATE` | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` Platform expired, protection force-disabled |

**Platform update failure detection:**

Queries Events 2001/2003 and filters for platform-specific failures by matching keywords (`platform`, `engine update`, `MoCAMP`) and known platform HRESULTs. Translates error codes via a 10-entry HRESULT table:

| HRESULT | Translation |
|---|---|
| `0x80310059` | BitLocker encryption conflict blocking platform update (PCR 7 / Secure Boot) |
| `0x80070643` | Fatal installation error -- .NET corruption or insufficient WinRE partition (<250 MB) |
| `0x80240016` | Update locked -- another installation in progress |
| `0x80508007` | Out of memory -- platform payload failed to unpack |
| `0x80290401` | TPM Platform Crypto Device not ready |
| `0x80508023` | Platform too old -- update rejected by the engine (N-2 exceeded) |
| `0x80070005` | Access denied -- permissions issue during update |
| `0x80508026` | Engine update failed |
| `0x800F0922` | CBS session error -- insufficient WinRE partition or pending reboot |
| `0x80240022` | All updates failed -- payload corrupted in transit |

**Configuration change tracking:**

Scans Event 5007 for `PlatformUpdatesChannel` or `EngineUpdatesChannel` changes -- reports count if detected.

> **Overlap note:** DEF002 already queries Event IDs 2000, 2001, 2003 for *signature* updates. DEF006 queries Event 2002 (platform/engine success) and Events 2007, 5100, 5101 (platform deprecation) which DEF002 does not cover. Events 2001/2003 are filtered specifically for platform-related content to avoid duplicating DEF002's signature failure analysis.

##### Check 4 -- MoCAMP Update Mechanism Health

Three sub-checks targeting the platform update pipeline:

**4a -- Orphaned MoCAMPUpdateStarted Lock:**

Reads `HKLM:\SOFTWARE\Microsoft\Windows Defender` -> `MoCAMPUpdateStarted`. If present, the MoCAMP engine believes an update is in progress and will reject all subsequent update attempts. This is a **critical finding** -- the update pipeline is deadlocked.

Common cause: a previous platform update was interrupted by power loss, crash, or forced termination.

| Condition | Verdict |
|---|---|
| Value absent | `[OK]` Pipeline clear |
| Value present | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` Update lock blocking all platform updates |

**4b -- Platform Staging Directory:**

Inspects `C:\ProgramData\Microsoft\Windows Defender\Platform` for version folders:

| Condition | Verdict |
|---|---|
| 1-3 folders | `[OK]` with latest folder name |
| >3 folders | `[]` Excessive staging, may indicate failed cleanup |
| Directory missing | `[]` Unexpected -- should exist on all Win10/11 |

Also compares the latest staged folder version against the running platform version to detect:
- Staged version newer than running -> reboot may be required
- Staged version older than running -> normal post-update state

**4c -- Update Delivery Services:**

Checks `wuauserv` (Windows Update) and `BITS` -- these handle the HTTP payload delivery of KB4052623:

| Condition | Verdict |
|---|---|
| Running or Manual start type (stopped) | `[OK]` or `[i]` |
| Disabled | `[python3 -c "
import json, re
with open('Scriptlets/ScriptletCatalog.json') as f:
    data = json.load(f)
for e in data:
    if e['Id'] == 'DEF006':
        s = e['Script']
        # Check for PS7 syntax
        issues = []
        if '??' in s: issues.append('null-coalescing ??')
        if '?.' in s: issues.append('null-conditional ?.')
        if re.search(r'\?\s', s): issues.append('possible ternary ?')
        if '-AsHashtable' in s: issues.append('-AsHashtable')
        if '-AsByteStream' in s: issues.append('-AsByteStream')
        if 'ForEach-Object -Parallel' in s: issues.append('ForEach-Object -Parallel')
        if '&&' in s: issues.append('pipeline chain &&')
        if '||' in s: issues.append('pipeline chain ||')
        if 'Get-WmiObject' in s: issues.append('Get-WmiObject')
        # Check for non-ASCII
        non_ascii = []
        for i, c in enumerate(s):
            if ord(c) > 127:
                non_ascii.append(f'pos {i}: {repr(c)}')
        if non_ascii:
            issues.append(f'Non-ASCII chars: {non_ascii[:5]}')
        if issues:
            print('PS 5.1 VIOLATIONS:')
            for i in issues: print(f'  - {i}')
        else:
            print('No PS 5.1 violations found.')
        break
"]` Platform updates cannot be delivered |
| Service not found | `[]` |

> **Scope note:** This is NOT the same as DEF001's service check. DEF001 checks WinDefend/WdNisSvc/Sense health broadly. DEF006 checks wuauserv/BITS because they are the **platform update delivery mechanism** -- distinct from the Defender service itself.

##### Check 5 -- WSUS Version Pinning Analysis

Correlates platform version staleness with WSUS configuration:

1. Reads `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` -> `WUServer`
2. Reads the signature update `FallbackOrder` to determine if WSUS is in the update chain
3. If WSUS is configured AND platform version is behind baseline:
   - Flags that KB4052623 may not be approved on the WSUS server
   - Recommends verifying WSUS approval or adding MMPC to FallbackOrder

Also checks `ForceUpdateFromMU` -- if enabled, definitions can bypass WSUS to Microsoft Update.

| Condition | Verdict |
|---|---|
| WSUS not configured | `[OK]` Direct Microsoft Update (default) |
| WSUS configured, platform current | `[OK]` KB4052623 appears approved |
| WSUS configured, platform behind | `[]` KB4052623 may not be approved |

> **Scope note:** DEF006 does NOT re-test WSUS TCP connectivity (DEF002 already defers that to WU002). It only reads the WSUS configuration to correlate with platform staleness.

#### Example Output (Healthy System)

```
=== Defender Platform & Engine Version Check ===

--- Component Versions ---
[OK]  Platform Version (AMProductVersion)
       4.18.26030.2. Current (at or above baseline 4.18.26010.0).
[OK]  Engine Version (AMEngineVersion)
       1.1.26030.1. Current.
[i]   NIS Engine Version
       2.1.9700.0. (NIS engine does not have an independent deprecation threshold.)

--- Update Channel & Ring ---
[OK]  Platform Update Channel
       GPO: Not set. MDM: Not set. Local: Not set.
[OK]  Engine Update Channel
       GPO: Not set. MDM: Not set. Local: Not set.

--- Platform Update Events (last 30 days) ---
[OK]  Platform/Engine Update Success (Event 2002)
       3 successful update(s) in last 30 days. Most recent: 2026-04-01 09:22.

--- MoCAMP Update Mechanism ---
[OK]  MoCAMPUpdateStarted Lock: Not present
       No orphaned update lock. Platform update pipeline is clear.
[OK]  Platform Staging Directory: 2 version folder(s)
       Latest: 4.18.26030.2.
[OK]  Windows Update (wuauserv): Stopped (start type: Manual)
[OK]  Background Intelligent Transfer (BITS): Stopped (start type: Manual)

--- WSUS Pinning Analysis ---
[OK]  WSUS: Not configured
       Platform updates are sourced directly from Microsoft Update (default).

RESULT: No issues detected. Defender platform and engine are current.

NEXT:   If platform outdated         -> force update via: MpCmdRun.exe -SignatureUpdate -MMPC
        If WSUS holding back         -> approve Defender platform updates (KB4052623) on WSUS
        If MoCAMP lock present       -> run DEF008 DEFRemediation to reset the update path
        If platform current          -> run DEF007 DEFEventAnalysis for event-level investigation
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| AV running mode, Security Center bitmask, services, MDE sensor, signal gap | DEF001 DEFStatusTriage |
| Definition update sources, WSUS/MMPC config, connectivity, signature events | DEF002 DEFDefinitionHealth |
| Third-party AV remnants, ghost registrations, DisableAntiSpyware/DisableAntiVirus | DEF003 DEFThirdPartyAV |
| RTP sub-component source attribution, Tamper Protection, exclusion patterns, ASR | DEF004 DEFRealtimeProtection |
| GPO vs MDM vs Local protection policy comparison (9 settings) | DEF005 DEFPolicyConflict |
| Event log timeline, threat history, error codes | DEF007 DEFEventAnalysis |
| Service reset, ghost cleanup, remediation | DEF008 DEFRemediation |

**Overlap notes:**
- DEF002 checks *signature* update source connectivity and `FallbackOrder`. DEF006 reads `FallbackOrder` only to *correlate* WSUS presence with platform staleness -- it does not re-test connectivity.
- DEF002 queries signature events (2000/2001/2003). DEF006 queries platform events (2002/2007/5100/5101). Events 2001/2003 are shared but DEF006 filters for platform-specific content only.
- DEF005 compares *protection* policies (RTP, MAPS, etc.) across GPO/MDM/Local. DEF006 compares *update channel/ring* policies -- entirely different registry surface.
- DEF001 checks WinDefend/WdNisSvc/Sense services. DEF006 checks wuauserv/BITS -- the platform *update delivery* services, not the Defender services themselves.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 5 check groups: Component version comparison (platform, engine, NIS) against hardcoded baselines (warn 4.18.26010.0, critical 4.18.25100.0) with N-2 deprecation awareness. Update channel/ring decode (PlatformUpdatesChannel, EngineUpdatesChannel) across GPO/MDM/Local with 0-6 integer-to-channel mapping, delayed ring detection, DefinitionUpdatesChannel, GradualRolloutPercentage. Platform update event log queries (Event 2002 success, Events 2007/5100/5101 deprecation/expiration warnings, Events 2001/2003 filtered for platform-specific failures) with 10-entry HRESULT translation table. MoCAMP mechanism health (orphaned MoCAMPUpdateStarted lock detection, platform staging directory inspection with version comparison, wuauserv/BITS service state). WSUS version pinning correlation (WSUS server detection + platform staleness cross-reference + ForceUpdateFromMU). |

---


### DEF007 -- DEFEventAnalysis

**Version:** 1.0
**Category:** DefenderEndpoint
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Pulls and correlates Defender events to build a chronological timeline of protection state changes and threat activity. Translates error codes into plain English with scriptlet routing.

This is the "what happened and when" diagnostic -- the final investigative tool before the DEF008 remediation script. After DEF001-DEF006 have identified *what* is wrong, DEF007 explains *when* it happened and *why*.

#### Usage

```powershell
Invoke-Indago -Name DEFEventAnalysis
Invoke-Indago -Name DEFEventAnalysis -Param1 "14"   # last 14 days
```

**Parameters:**

| Parameter | Description | Default |
|---|---|---|
| Param1 | DaysBack -- number of days of event history to pull (1-90) | 7 |

#### What It Checks

##### Data Source

DEF007 reads **event logs only** via `Get-WinEvent` with optimized `-FilterXPath` queries. It does NOT query WMI, registry, services, or `Get-Mp*` cmdlets -- those are the domain of DEF001-DEF006.

| Log Channel | Purpose |
|---|---|
| `Microsoft-Windows-Windows Defender/Operational` | Primary: scans, definitions, threats, config changes |
| `Application` (Source: `SecurityCenter`) | Security Center state changes and WMI sync errors |
| `Microsoft-Windows-Windows Defender/WHC` | Health assessments and compliance telemetry (if available) |

##### Section 1: Protection State Timeline

Events from `Microsoft-Windows-Windows Defender/Operational`:

| Event ID | Meaning |
|---|---|
| 1000 | Scan Started -- scan type and triggering user |
| 1001 | Scan Completed -- duration, correlation with 1000 |
| 1002 | Scan Cancelled -- flags patterns of aborted scans |
| 1005 | Scan Failed -- engine crash or corruption, error code extraction |
| 1150 | Service Healthy -- hourly heartbeat confirming engine operational |
| 2000 | Definition Update Started |
| 2001 | Definition Update Succeeded -- new version applied |
| 2002 | Definition Update Failed -- error code extraction |
| 5007 | Configuration Changed -- setting name and old/new value |

| Condition | Verdict |
|---|---|
| Scan failed (Event 1005) | `[python3 << 'PYEOF'
import json

with open('/tmp/DEF007_full.ps1', 'r') as f:
    script_body = f.read()

with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

entry = {
    "Id": "DEF007",
    "Name": "DEFEventAnalysis",
    "DisplayName": "Defender Event Log & Threat History Analysis",
    "Category": "DefenderEndpoint",
    "Description": "Pulls and correlates Defender events to build a timeline of protection state changes and threat activity. Queries Operational log for scan events (start/complete/cancel/fail), definition updates (success/fail), configuration changes (Event 5007), and service health heartbeats (Event 1150). Queries threat events (detection, remediation success/failure, quarantine operations) with ThreatStatusID decode and AdditionalActionsBitMask decode. Queries SecurityCenter events from Application log (Event 15/16/17) for state changes and WMI sync failures. Queries WHC log if available. Extracts HRESULTs from event payloads with 10-entry embedded translation map and scriptlet routing.",
    "ExecutionContext": "System",
    "Parameters": {
        "Param1": "DaysBack -- number of days of event history to pull (default: 7, max: 90)"
    },
    "Script": script_body,
    "Tags": ["defender", "event-log", "timeline", "threats", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. Event logs only -- does NOT query WMI, registry, services, or Get-Mp* cmdlets (those are DEF001-DEF006 domain). 3 output sections: (1) Protection state timeline from Operational log: Event 1000 scan start, 1001 scan complete, 1002 scan cancelled, 1005 scan failed, 1150 service healthy heartbeat, 2000/2001/2002 definition update start/success/fail, 5007 configuration change. Summary statistics and notable events. (2) Threat activity: Event 1006/1116 detection, 1007/1117 action OK, 1008/1118/1119 action failed, 1009 quarantine restore, 1011 quarantine delete. ThreatStatusID decode (0-107 incl. 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4=FullScan, 8=Reboot, 16=Manual, 32768=Offline). Up to 10 detections and all action failures shown. (2b) SecurityCenter events from Application log: Event 15 state change, 16 status update error (ghost AV), 17 validation failure (DC040780 WMI sync). (2c) WHC log if available with graceful fallback. (3) HRESULT summary: 10-entry embedded map (0x80508023/0x80508019/0x80070005/0x800106ba/0x80508007/0x80501001/0x80508014/0x80508017/0x8050A003/0x80508026) with plain-English translations and scriptlet routing. Configurable time window via Param1."
}

insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'DEF006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find DEF006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: DEF007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    def007 = [e for e in verify if e['Id'] == 'DEF007']
    if def007:
        print(f"DEF007 found. Name={def007[0]['Name']}, Script={len(def007[0]['Script'])} chars")
    else:
        print("ERROR: DEF007 not found after insertion")
PYEOF]` With HRESULT extraction |
| >= 3 scan cancellations | `[]` Pattern of aborted scans |
| Definition update failed (Event 2002) | `[python3 << 'PYEOF'
import json

with open('/tmp/DEF007_full.ps1', 'r') as f:
    script_body = f.read()

with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

entry = {
    "Id": "DEF007",
    "Name": "DEFEventAnalysis",
    "DisplayName": "Defender Event Log & Threat History Analysis",
    "Category": "DefenderEndpoint",
    "Description": "Pulls and correlates Defender events to build a timeline of protection state changes and threat activity. Queries Operational log for scan events (start/complete/cancel/fail), definition updates (success/fail), configuration changes (Event 5007), and service health heartbeats (Event 1150). Queries threat events (detection, remediation success/failure, quarantine operations) with ThreatStatusID decode and AdditionalActionsBitMask decode. Queries SecurityCenter events from Application log (Event 15/16/17) for state changes and WMI sync failures. Queries WHC log if available. Extracts HRESULTs from event payloads with 10-entry embedded translation map and scriptlet routing.",
    "ExecutionContext": "System",
    "Parameters": {
        "Param1": "DaysBack -- number of days of event history to pull (default: 7, max: 90)"
    },
    "Script": script_body,
    "Tags": ["defender", "event-log", "timeline", "threats", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. Event logs only -- does NOT query WMI, registry, services, or Get-Mp* cmdlets (those are DEF001-DEF006 domain). 3 output sections: (1) Protection state timeline from Operational log: Event 1000 scan start, 1001 scan complete, 1002 scan cancelled, 1005 scan failed, 1150 service healthy heartbeat, 2000/2001/2002 definition update start/success/fail, 5007 configuration change. Summary statistics and notable events. (2) Threat activity: Event 1006/1116 detection, 1007/1117 action OK, 1008/1118/1119 action failed, 1009 quarantine restore, 1011 quarantine delete. ThreatStatusID decode (0-107 incl. 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4=FullScan, 8=Reboot, 16=Manual, 32768=Offline). Up to 10 detections and all action failures shown. (2b) SecurityCenter events from Application log: Event 15 state change, 16 status update error (ghost AV), 17 validation failure (DC040780 WMI sync). (2c) WHC log if available with graceful fallback. (3) HRESULT summary: 10-entry embedded map (0x80508023/0x80508019/0x80070005/0x800106ba/0x80508007/0x80501001/0x80508014/0x80508017/0x8050A003/0x80508026) with plain-English translations and scriptlet routing. Configurable time window via Param1."
}

insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'DEF006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find DEF006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: DEF007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    def007 = [e for e in verify if e['Id'] == 'DEF007']
    if def007:
        print(f"DEF007 found. Name={def007[0]['Name']}, Script={len(def007[0]['Script'])} chars")
    else:
        print("ERROR: DEF007 not found after insertion")
PYEOF]` With HRESULT extraction |
| No definition updates in time window | `[]` Definitions may be stale |
| Configuration changes detected (Event 5007) | `[]` Up to 5 most recent shown |
| No health heartbeats (Event 1150) | `[]` Engine may not be running |
| Healthy state | `[OK]` |

##### Section 2: Threat Activity

Events from `Microsoft-Windows-Windows Defender/Operational`:

| Event ID | Meaning |
|---|---|
| 1006 | Malware Detected -- threat name, severity, path |
| 1007 | Action Taken (cleaned) |
| 1008 | Action Failed -- critical, degraded state |
| 1009 | Quarantine Restored -- item restored by user |
| 1011 | Quarantine Deleted -- item permanently purged |
| 1116 | Threat Detected (variant) |
| 1117 | Action Performed (variant) |
| 1118 | Action Failed (variant) |
| 1119 | Action Critical Failure |

**ThreatStatusID decode table (embedded):**

| ID | Status | Verdict |
|---|---|---|
| 0 | Unknown | `[]` |
| 1 | Detected | `[]` Awaiting action |
| 2 | Cleaned | `[OK]` |
| 3 | Quarantined | `[OK]` |
| 4 | Removed | `[OK]` |
| 5 | Allowed | `[]` Verify intentional |
| 6 | Blocked | `[OK]` |
| 102 | Quarantine Failed | `[python3 << 'PYEOF'
import json

with open('/tmp/DEF007_full.ps1', 'r') as f:
    script_body = f.read()

with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

entry = {
    "Id": "DEF007",
    "Name": "DEFEventAnalysis",
    "DisplayName": "Defender Event Log & Threat History Analysis",
    "Category": "DefenderEndpoint",
    "Description": "Pulls and correlates Defender events to build a timeline of protection state changes and threat activity. Queries Operational log for scan events (start/complete/cancel/fail), definition updates (success/fail), configuration changes (Event 5007), and service health heartbeats (Event 1150). Queries threat events (detection, remediation success/failure, quarantine operations) with ThreatStatusID decode and AdditionalActionsBitMask decode. Queries SecurityCenter events from Application log (Event 15/16/17) for state changes and WMI sync failures. Queries WHC log if available. Extracts HRESULTs from event payloads with 10-entry embedded translation map and scriptlet routing.",
    "ExecutionContext": "System",
    "Parameters": {
        "Param1": "DaysBack -- number of days of event history to pull (default: 7, max: 90)"
    },
    "Script": script_body,
    "Tags": ["defender", "event-log", "timeline", "threats", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. Event logs only -- does NOT query WMI, registry, services, or Get-Mp* cmdlets (those are DEF001-DEF006 domain). 3 output sections: (1) Protection state timeline from Operational log: Event 1000 scan start, 1001 scan complete, 1002 scan cancelled, 1005 scan failed, 1150 service healthy heartbeat, 2000/2001/2002 definition update start/success/fail, 5007 configuration change. Summary statistics and notable events. (2) Threat activity: Event 1006/1116 detection, 1007/1117 action OK, 1008/1118/1119 action failed, 1009 quarantine restore, 1011 quarantine delete. ThreatStatusID decode (0-107 incl. 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4=FullScan, 8=Reboot, 16=Manual, 32768=Offline). Up to 10 detections and all action failures shown. (2b) SecurityCenter events from Application log: Event 15 state change, 16 status update error (ghost AV), 17 validation failure (DC040780 WMI sync). (2c) WHC log if available with graceful fallback. (3) HRESULT summary: 10-entry embedded map (0x80508023/0x80508019/0x80070005/0x800106ba/0x80508007/0x80501001/0x80508014/0x80508017/0x8050A003/0x80508026) with plain-English translations and scriptlet routing. Configurable time window via Param1."
}

insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'DEF006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find DEF006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: DEF007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    def007 = [e for e in verify if e['Id'] == 'DEF007']
    if def007:
        print(f"DEF007 found. Name={def007[0]['Name']}, Script={len(def007[0]['Script'])} chars")
    else:
        print("ERROR: DEF007 not found after insertion")
PYEOF]` Degraded -- manual intervention |
| 103 | Remove Failed | `[python3 << 'PYEOF'
import json

with open('/tmp/DEF007_full.ps1', 'r') as f:
    script_body = f.read()

with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

entry = {
    "Id": "DEF007",
    "Name": "DEFEventAnalysis",
    "DisplayName": "Defender Event Log & Threat History Analysis",
    "Category": "DefenderEndpoint",
    "Description": "Pulls and correlates Defender events to build a timeline of protection state changes and threat activity. Queries Operational log for scan events (start/complete/cancel/fail), definition updates (success/fail), configuration changes (Event 5007), and service health heartbeats (Event 1150). Queries threat events (detection, remediation success/failure, quarantine operations) with ThreatStatusID decode and AdditionalActionsBitMask decode. Queries SecurityCenter events from Application log (Event 15/16/17) for state changes and WMI sync failures. Queries WHC log if available. Extracts HRESULTs from event payloads with 10-entry embedded translation map and scriptlet routing.",
    "ExecutionContext": "System",
    "Parameters": {
        "Param1": "DaysBack -- number of days of event history to pull (default: 7, max: 90)"
    },
    "Script": script_body,
    "Tags": ["defender", "event-log", "timeline", "threats", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. Event logs only -- does NOT query WMI, registry, services, or Get-Mp* cmdlets (those are DEF001-DEF006 domain). 3 output sections: (1) Protection state timeline from Operational log: Event 1000 scan start, 1001 scan complete, 1002 scan cancelled, 1005 scan failed, 1150 service healthy heartbeat, 2000/2001/2002 definition update start/success/fail, 5007 configuration change. Summary statistics and notable events. (2) Threat activity: Event 1006/1116 detection, 1007/1117 action OK, 1008/1118/1119 action failed, 1009 quarantine restore, 1011 quarantine delete. ThreatStatusID decode (0-107 incl. 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4=FullScan, 8=Reboot, 16=Manual, 32768=Offline). Up to 10 detections and all action failures shown. (2b) SecurityCenter events from Application log: Event 15 state change, 16 status update error (ghost AV), 17 validation failure (DC040780 WMI sync). (2c) WHC log if available with graceful fallback. (3) HRESULT summary: 10-entry embedded map (0x80508023/0x80508019/0x80070005/0x800106ba/0x80508007/0x80501001/0x80508014/0x80508017/0x8050A003/0x80508026) with plain-English translations and scriptlet routing. Configurable time window via Param1."
}

insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'DEF006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find DEF006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: DEF007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    def007 = [e for e in verify if e['Id'] == 'DEF007']
    if def007:
        print(f"DEF007 found. Name={def007[0]['Name']}, Script={len(def007[0]['Script'])} chars")
    else:
        print("ERROR: DEF007 not found after insertion")
PYEOF]` Degraded -- manual intervention |
| 104 | Allow Failed | `[]` |
| 105 | Abandoned | `[]` |
| 107 | Blocked Failed | `[python3 << 'PYEOF'
import json

with open('/tmp/DEF007_full.ps1', 'r') as f:
    script_body = f.read()

with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

entry = {
    "Id": "DEF007",
    "Name": "DEFEventAnalysis",
    "DisplayName": "Defender Event Log & Threat History Analysis",
    "Category": "DefenderEndpoint",
    "Description": "Pulls and correlates Defender events to build a timeline of protection state changes and threat activity. Queries Operational log for scan events (start/complete/cancel/fail), definition updates (success/fail), configuration changes (Event 5007), and service health heartbeats (Event 1150). Queries threat events (detection, remediation success/failure, quarantine operations) with ThreatStatusID decode and AdditionalActionsBitMask decode. Queries SecurityCenter events from Application log (Event 15/16/17) for state changes and WMI sync failures. Queries WHC log if available. Extracts HRESULTs from event payloads with 10-entry embedded translation map and scriptlet routing.",
    "ExecutionContext": "System",
    "Parameters": {
        "Param1": "DaysBack -- number of days of event history to pull (default: 7, max: 90)"
    },
    "Script": script_body,
    "Tags": ["defender", "event-log", "timeline", "threats", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. Event logs only -- does NOT query WMI, registry, services, or Get-Mp* cmdlets (those are DEF001-DEF006 domain). 3 output sections: (1) Protection state timeline from Operational log: Event 1000 scan start, 1001 scan complete, 1002 scan cancelled, 1005 scan failed, 1150 service healthy heartbeat, 2000/2001/2002 definition update start/success/fail, 5007 configuration change. Summary statistics and notable events. (2) Threat activity: Event 1006/1116 detection, 1007/1117 action OK, 1008/1118/1119 action failed, 1009 quarantine restore, 1011 quarantine delete. ThreatStatusID decode (0-107 incl. 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4=FullScan, 8=Reboot, 16=Manual, 32768=Offline). Up to 10 detections and all action failures shown. (2b) SecurityCenter events from Application log: Event 15 state change, 16 status update error (ghost AV), 17 validation failure (DC040780 WMI sync). (2c) WHC log if available with graceful fallback. (3) HRESULT summary: 10-entry embedded map (0x80508023/0x80508019/0x80070005/0x800106ba/0x80508007/0x80501001/0x80508014/0x80508017/0x8050A003/0x80508026) with plain-English translations and scriptlet routing. Configurable time window via Param1."
}

insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'DEF006':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find DEF006 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: DEF007 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    def007 = [e for e in verify if e['Id'] == 'DEF007']
    if def007:
        print(f"DEF007 found. Name={def007[0]['Name']}, Script={len(def007[0]['Script'])} chars")
    else:
        print("ERROR: DEF007 not found after insertion")
PYEOF]` Degraded |

**AdditionalActionsBitMask decode:**

| Bit | Meaning |
|---|---|
| 4 | Full Scan Required |
| 8 | Reboot Required |
| 16 | Manual Steps Required |
| 32768 | Offline Scan Required |

Up to 10 detections and all action failures are shown in the output.

##### Section 2b: Security Center Events

Events from `Application` log (Source: `SecurityCenter`):

| Event ID | Meaning |
|---|---|
| 15 | State change logged |
| 16 | Error updating status -- often ghost AV related |
| 17 | Validation failure (DC040780) -- WMI sync issue |

##### Section 2c: WHC Log

Queries `Microsoft-Windows-Windows Defender/WHC` if available. Gracefully skips if the channel does not exist. Extracts HRESULTs from WHC events for inclusion in the error summary.

##### Section 3: HRESULT Error Code Summary

HRESULTs are extracted from all event payloads via regex `0x[0-9A-Fa-f]{8}`. Unique codes are listed with translations and routing:

| Code | Symbolic Name | Translation | Routing |
|---|---|---|---|
| `0x80508023` | ERR_MP_THREAT_NOT_FOUND | Threat resolved before engine could act | info |
| `0x80508019` | ERR_MP_NOT_FOUND | Internal engine rollback/failure | DEF006 |
| `0x80070005` | E_ACCESSDENIED | Access denied -- Tamper Protection or permissions | DEF004 |
| `0x800106ba` | RPC_S_SERVER_UNAVAILABLE | WinDefend service crashed | DEF001 |
| `0x80508007` | ERR_MP_NO_MEMORY | Memory exhaustion during scan/update | system resources |
| `0x80501001` | ERROR_MP_ACTIONS_FAILED | Remediation action failed | full/offline scan |
| `0x80508014` | ERROR_MP_RESTORE_FAILED | Quarantine restore failed | info |
| `0x80508017` | ERROR_MP_REMOVE_FAILED | Threat removal failed -- file locked | offline scan |
| `0x8050A003` | SCAN_ABORTED | Scan aborted -- resource conflict/timeout | retry scan |
| `0x80508026` | ENGINE_UPDATE_FAILED | Engine update failed | DEF006 |

#### Example Output (Healthy Endpoint, No Threats)

```
=== Defender Event Log & Threat History Analysis ===
[i]   Time Window: last 7 day(s)
       Cutoff: 2026-03-28 22:19:00

--- Protection State Timeline ---
[i]   Protection Event Summary
       42 protection event(s) in the last 7 day(s): 7 scan start, 7 scan complete,
       0 scan cancelled, 0 scan failed, 14 def update OK, 0 def update fail,
       0 config change, 14 health heartbeat.
[OK]  Definition Updates
       14 successful update(s). Last: 2026-04-04 21:15:00. No failures.
[OK]  Service Health Heartbeat (Event 1150)
       14 heartbeat(s). Last: 2026-04-04 21:00:00. Engine and platform confirmed operational.

--- Threat Activity ---
[OK]  Threat Events
       No threat activity events in the last 7 day(s). No malware detected.

--- Security Center Events ---
[OK]  Security Center Events
       No SecurityCenter error events in the last 7 day(s).

--- Error Code Summary ---
[OK]  Error Codes
       No HRESULT error codes extracted from events. No known error conditions.

RESULT: No issues detected in Defender event timeline. Protection state healthy.

NEXT:   If active threats unresolved  -> run a full scan: Start-MpScan -ScanType FullScan
        If definition rollback         -> force update: Update-MpSignature
        If platform/engine errors      -> run DEF006 DEFPlatformVersion
        If access denied errors        -> run DEF004 DEFRealtimeProtection (Tamper Protection)
        If service crashed             -> run DEF001 DEFStatusTriage
        Escalate timeline to security team if threats were detected.
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| Point-in-time AV status (RTP, mode, definitions age) | DEF001 DEFStatusTriage |
| Definition update pipeline (source, CDN, tasks) | DEF002 DEFDefinitionHealth |
| Third-party AV conflicts, ghost registrations | DEF003 DEFThirdPartyAV |
| RTP sub-components, Tamper Protection, exclusions, ASR | DEF004 DEFRealtimeProtection |
| Policy conflicts (GPO/MDM/Local side-by-side) | DEF005 DEFPolicyConflict |
| Platform/engine/NIS versions, update channel | DEF006 DEFPlatformVersion |
| Remediation and recovery actions | DEF008 DEFRemediation |

**Non-overlap notes:**
- DEF007 reads *event logs only*. It does NOT query WMI, registry, services, or Get-Mp* cmdlets.
- DEF002 checks definition update *pipeline configuration*. DEF007 checks definition update *events* (success/fail with timestamps).
- DEF004 reads RTP sub-component *state*. DEF007 reads configuration change *events* (Event 5007).
- DEF006 reads component *versions*. DEF007 reads platform update *error codes* and routes to DEF006.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 3 output sections + 2 supplementary. (1) Protection state timeline from Operational log: Event 1000/1001/1002/1005 scan lifecycle, Event 1150 service healthy heartbeat, Event 2000/2001/2002 definition update lifecycle, Event 5007 configuration change. Summary statistics with notable event detail (up to 5 config changes shown). (2) Threat activity: Event 1006/1116 detection (up to 10 shown with threat name/severity extraction), Event 1007/1117 action OK, Event 1008/1118/1119 action failed (all shown), Event 1009 quarantine restore, Event 1011 quarantine delete. ThreatStatusID decode (12 statuses: 0 Unknown through 107 Blocked Failed, including 102 Quarantine Failed, 103 Remove Failed). AdditionalActionsBitMask decode (4/8/16/32768). (2b) SecurityCenter events from Application log: Event 15 state change, Event 16 status update error, Event 17 validation failure. (2c) WHC log with graceful fallback if channel unavailable. (3) HRESULT summary: regex extraction from all event payloads, 10-entry embedded translation map with scriptlet routing. Configurable time window via Param1 (default 7, max 90). |

---
## BitLocker Suite

### BL001 -- BLStatusSnapshot

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Fast triage snapshot of BitLocker encryption reality on this machine, right now. Answers the question every tech asks when Intune marks a device non-compliant for encryption:

> Is this drive actually encrypted? If so, is the protection active? If not, did encryption ever start -- or was it never attempted?

Intune's encryption status can lag reality by hours or days. This script gives ground truth in under 10 seconds. Every other BitLocker scriptlet (BL002-BL010) references BL001 as the starting point.

#### Usage

```powershell
# Requires Administrator or SYSTEM context
Invoke-Indago -Name BLStatusSnapshot
```

> **Note:** BitLocker queries require elevated privileges. If run in a non-elevated PowerShell window, the script will report `[!!] ACCESS DENIED` and advise running as Administrator or via the RMM tool. This is by design -- the script detects the privilege gap rather than silently failing.

#### Parameters

None.

#### What It Checks

##### Check 1 -- Volume Encryption Status

Queries `Get-BitLockerVolume` for all fixed drives (OS and fixed data volumes -- removable drives are excluded). For each volume, reports:

| Property | Meaning |
|----------|---------|
| MountPoint | Drive letter (C:, D:, etc.) |
| VolumeType | OperatingSystem vs FixedData |
| VolumeStatus | FullyEncrypted, FullyDecrypted, EncryptionInProgress, DecryptionInProgress, EncryptionPaused |
| EncryptionPercentage | Progress if encryption/decryption is in progress |
| ProtectionStatus | On or Off -- **Off means the encryption key is unprotected** |
| EncryptionMethod | XTS-AES-128, XTS-AES-256, Aes128, Aes256, or None |
| KeyProtector | Types present: Tpm, RecoveryPassword, ExternalKey, etc. |
| LockStatus | Locked or Unlocked |

**Verdict logic:**

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| FullyEncrypted + Protection On + has Tpm + has RecoveryPassword | `[OK]` | Fully encrypted and properly protected |
| FullyEncrypted + Protection On + no RecoveryPassword | `[!]` | Encrypted but no recovery key -- escrow may have failed |
| FullyEncrypted + Protection **Off** | `[!!]` | **Ghost state** -- see below |
| EncryptionInProgress | `[i]` | Reports percentage; normal during provisioning |
| EncryptionPaused | `[!!]` | Encryption interrupted -- needs intervention |
| DecryptionInProgress | `[!]` | Someone or something is actively decrypting |
| FullyDecrypted | `[!!]` | Not encrypted at all |

**Ghost State Detection:**

The most dangerous finding is `FullyEncrypted` + `ProtectionStatus = Off`. This "ghost state" means the volume data has been through cryptographic conversion, but the encryption key is sitting **unprotected in the clear** on the disk. The data looks encrypted but is trivially accessible. This commonly occurs when:

- OEM pre-provisioning encrypted during OOBE but never bound a key protector
- A key protector was removed (intentionally or by policy conflict) without decrypting first
- BitLocker was suspended indefinitely and the protection was never resumed

The script flags this as `[!!]` and directs the tech to BL009 BLTpmRemediation.

**WMI Fallback:**

If `Get-BitLockerVolume` fails (BitLocker PowerShell module not loaded, missing prerequisites), the script falls back to direct WMI queries against `ROOT\CIMv2\Security\MicrosoftVolumeEncryption\Win32_EncryptableVolume`. The raw `uint32` values are decoded using these mappings:

| Property | Value | Meaning |
|----------|-------|---------|
| ConversionStatus | 0 | Fully Decrypted |
| ConversionStatus | 1 | Fully Encrypted |
| ConversionStatus | 2 | Encryption In Progress |
| ConversionStatus | 3 | Decryption In Progress |
| ConversionStatus | 4 | Encryption Paused |
| ProtectionStatus | 0 | Off |
| ProtectionStatus | 1 | On |
| ProtectionStatus | 2 | Unknown |
| EncryptionMethod | 0 | None |
| EncryptionMethod | 1 | AES-128 with Diffuser (legacy) |
| EncryptionMethod | 2 | AES-256 with Diffuser (legacy) |
| EncryptionMethod | 3 | AES-128 |
| EncryptionMethod | 4 | AES-256 |
| EncryptionMethod | 6 | XTS-AES-128 |
| EncryptionMethod | 7 | XTS-AES-256 |

WMI-sourced volumes are marked with `(WMI)` in the output to indicate the fallback path.

**Error handling:**

If both `Get-BitLockerVolume` and the WMI fallback fail, the script distinguishes between:

| Error | Verdict | Message |
|-------|---------|---------|
| Access denied | `[!!]` | Script needs Administrator or SYSTEM privileges |
| WMI namespace not found | `[!!]` | BitLocker not available on this Windows edition (e.g., Home) |
| Other errors | `[!!]` | Shows actual error messages from both attempts and suggests BL002 |

##### Check 2 -- OS Drive Letter Validation

Confirms the OS drive is `C:` via `$env:SystemDrive`.

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| OS on `C:` | `[OK]` | Standard configuration |
| OS on any other letter | `[!!]` | Non-standard -- Intune policies and remediation scripts assume C: |

**Why it matters:** Non-standard OS drive letters (D:, E:) are a frequent source of false compliance failures. When Intune's BitLocker CSP policy targets `C:` but the OS lives on `D:`, encryption may "succeed" on an empty partition while the actual OS drive remains unencrypted.

##### Check 3 -- Last BitLocker Event

Pulls the single most recent event from the `Microsoft-Windows-BitLocker/BitLocker Management` event log. This is a quick peek -- enough for triage, not a full timeline (that's BL007's job).

**Event ID reference (embedded mapping):**

| Event ID | Category | Meaning |
|----------|----------|---------|
| 768 | Success | Encryption started successfully |
| 770 | Action | Decryption started |
| 771 | Action | Decryption paused or stopped |
| 775 | Info | Encryption method and key protector set |
| 778 | Warning | Volume reverted to unprotected state |
| 805 | Warning | Volume unlocked with recovery key (protector failure) |
| 810 | Warning | BitLocker cannot use Secure Boot for integrity validation |
| 846 | Failure | Recovery key escrow to Entra ID **FAILED** |
| 851 | Failure | Silent encryption **FAILED** |
| 853 | Failure | TPM not found or bootable media blocking |
| 854 | Failure | WinRE not configured -- encryption blocked |

**Verdict logic:**

| Last Event | Verdict |
|------------|---------|
| Success event (768, 775) | `[OK]` |
| Failure event (846, 851, 853, 854) | `[!!]` with direction to run BL007 |
| Warning event (778, 805, 810, 770, 771) | `[!]` |
| No events found | `[i]` Encryption may never have been attempted |
| Log not accessible | `[i]` with error details |

##### Check 4 -- BDESVC Service Health

Checks the BitLocker Drive Encryption Service (`BDESVC`), which is the master service for all BitLocker operations including encryption, decryption, key management, and recovery key escrow.

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Running | `[OK]` | Operational |
| Stopped + Manual start type | `[OK]` | Normal demand-start behavior (same pattern as WU001's BITS service) |
| Disabled | `[!!]` | All BitLocker operations will fail |
| Not found | `[!!]` | BitLocker may not be available on this edition |

#### Example Output (Healthy Encrypted System)

```
=== BitLocker Status Snapshot ===

[OK]  Volume C:
       Status: FullyEncrypted. Protection: On. Method: XtsAes256.
       Type: OperatingSystem. Lock: Unlocked. Protectors: Tpm, RecoveryPassword.
[OK]  OS Drive Letter
       OS is on C: as expected. Intune policies will target the correct volume.
[OK]  Last BitLocker Event (ID 775, 2026-03-15 09:22)
       Encryption method and key protector set
       The encryption method and key protector have been set for volume C:.
[OK]  BitLocker Service (BDESVC)
       Stopped, start type: Manual. This is expected -- service starts on demand.

RESULT: No issues detected. BitLocker appears healthy.

NEXT:   If not encrypted and no errors  -> run BL002 BLTpmHealth to check TPM readiness
        If encryption failed            -> run BL007 BLEventAnalysis for the failure reason
        If suspended                    -> run BL009 BLTpmRemediation to resume or restart
        If encrypted but Intune non-compliant -> force Intune sync (INT001)
        If ghost state (encrypted, protection off) -> run BL009 BLTpmRemediation
        If no recovery key              -> run BL005 BLEscrowCheck
```

#### Scope Boundaries

BL001 is deliberately scoped to fast triage. The following concerns are handled by other scriptlets:

| Concern | Handled By |
|---------|------------|
| TPM health, version, firmware, lockout state | BL002 BLTpmHealth |
| UEFI vs Legacy BIOS, Secure Boot, GPT vs MBR, partition geometry | BL003 BLHardwarePrereqs |
| Intune MDM enrollment, BitLocker CSP policy settings | BL004 BLIntunePolicy |
| Recovery key escrow status, AAD connectivity, key protector GUIDs | BL005 BLEscrowCheck |
| GPO vs MDM policy conflict detection | BL006 BLPolicyConflict |
| Full event log timeline, HRESULT error code translation | BL007 BLEventAnalysis |
| WinRE status, `manage-bde` deep diagnostics, encryption readiness dry run | BL008 BLReadinessCheck |
| TPM re-initialization, key protector cleanup, remediation | BL009 BLTpmRemediation |
| Force encryption, escrow, progress monitoring | BL010 BLForceEncrypt |

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. Queries `Get-BitLockerVolume` with WMI `Win32_EncryptableVolume` fallback. Ghost state detection (encrypted + protection off). OS drive letter validation. Last BitLocker management event with Event ID mapping (768, 770, 771, 775, 778, 805, 810, 846, 851, 853, 854). BDESVC demand-start service check. Access-denied detection for non-elevated sessions. `NEXT:` footer routing to BL002/BL005/BL007/BL009/INT001. |

---

### BL002 -- BLTpmHealth

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Diagnoses **why** BitLocker can't encrypt -- is the TPM the blocker? BL001 tells the tech "this volume is not encrypted." BL002 drills into the TPM hardware that BitLocker depends on: is it present, correctly provisioned, running vulnerable firmware, or locked out?

The TPM is the single most common BitLocker blocker in managed environments. Failure modes include: TPM disabled in BIOS, not provisioned/owned, TPM 1.2 when Intune requires 2.0, known firmware vulnerabilities (Infineon ROCA, STMicro TPM-FAIL), and dictionary attack lockout.

#### Usage

```powershell
Invoke-Indago -Name BLTpmHealth
```

No parameters. The script reads all relevant sources automatically.

#### What It Checks

**Check 1: TPM Presence & State**

Primary source: `Get-Tpm` cmdlet (PS 5.1+, `TrustedPlatformModule` module).

| Property | What We Check | Verdict |
|---|---|---|
| `TpmPresent` | Is TPM hardware detected by the OS? | `[!!]` if `False` -- BIOS check needed |
| `TpmReady` | Aggregate Windows readiness flag | `[OK]` if `True`; `[!!]` if `False` |
| `TpmEnabled` | Is the TPM enabled? | `[!!]` if not enabled |
| `TpmActivated` | Is the TPM activated for crypto? | `[!!]` if not activated |
| `TpmOwned` | Has Windows taken ownership? | `[!]` if not owned, checks `AutoProvisioning` |

**Early exit:** If `TpmPresent` is `False`, reports `[!!]` with BIOS guidance and skips remaining checks.

**Fallback:** If `Get-Tpm` fails entirely (module missing), falls back to `tpmtool.exe getdeviceinformation` and parses stdout for basic diagnostics (presence, version, manufacturer, lockout, initialization). If both fail, reports `[!!]` "TPM infrastructure unavailable."

**Check 2: TPM Version**

Source: `Get-CimInstance -Namespace 'ROOT\CIMv2\Security\MicrosoftTpm' -ClassName Win32_Tpm`

| Property | What We Report |
|---|---|
| `SpecVersion` | Parsed for major version (1.2 vs 2.0). `[OK]` for 2.0, `[!]` for 1.2 with guidance. |
| `PhysicalPresenceVersionInfo` | PPI version (informational) |

Note: `Get-Tpm` does not cleanly expose 1.2 vs 2.0 -- the `Win32_Tpm` WMI class is required for accurate version detection.

**Check 3: Manufacturer & Firmware Vulnerability Check**

Source: `Get-Tpm` (`ManufacturerIdTxt`, `ManufacturerVersion`, `ManufacturerVersionFull20`)

| Manufacturer | CVE | Affected Firmware | Safe Firmware | Severity |
|---|---|---|---|---|
| Infineon (`IFX`) | CVE-2017-15361 (ROCA) | TPM 1.2 fw < 4.34/6.43; TPM 2.0 fw < 7.63 | >= 7.63.x | `[!!]` -- RSA key compromise |
| STMicro (`STM`) | CVE-2019-16863 (TPM-FAIL) | Branches 71.x < 71.16, 73.x < 73.20, 74.x < 74.20 | 71.16, 73.20, 74.20 | `[!!]` -- ECDSA key extraction |

All findings include explicit guidance to visit the OEM's support site for a firmware update. The script cannot fix BIOS-level TPM issues.

**Check 4: Lockout State**

Source: `Get-Tpm` lockout properties

| Property | What We Report |
|---|---|
| `LockedOut` | Boolean -- is the TPM refusing auth commands? |
| `LockoutCount` | Current tally of failed authorizations |
| `LockoutMax` | Threshold before hard lockout (typically 32 for TPM 2.0) |
| `LockoutHealTime` | Duration for count to decrement by 1 |

If locked out, calculates estimated heal duration: `LockoutCount * LockoutHealTime` of **continuous powered-on time**. Explicitly states that shutdowns, hibernation, and deep sleep pause the timer. No exact unlock time can be predicted. No native method exists to clear the lockout programmatically (modern Windows discards the owner auth password).

**Check 5: Attestation & Provisioning Readiness**

| Check | Source | Verdict |
|---|---|---|
| TBS (TPM Base Services) | `Get-Service 'TBS'` | `[OK]` running; `[!!]` stopped/disabled/missing |
| Auto-Provisioning | `Get-Tpm` `AutoProvisioning` property | Reported if `TpmOwned = False` |
| Owner Auth Retention | `HKLM:\SOFTWARE\Policies\Microsoft\TPM\OSManagedAuthLevel` | `[i]` informational with meaning |

OSManagedAuthLevel values:

| Value | Meaning |
|---|---|
| 0 (None) | OS stores no owner auth -- no programmatic TPM clear |
| 2 (Delegated) | Partial programmatic control |
| 4 (Full) | Full programmatic TPM management available |
| 5 (Default) | Modern default -- retains lockout auth only |

#### Output Structure

```
=== TPM Health & Readiness ===

--- TPM Presence & State ---
[OK]  TPM Present
       TpmPresent: True. The operating system detects the TPM hardware.
[OK]  TPM Ready
       TpmReady: True. TPM is fully compliant with Windows standards.
[OK]  TPM Enabled & Activated
       TpmEnabled: True. TpmActivated: True.
[OK]  TPM Ownership
       TpmOwned: True. Windows has taken ownership of the TPM.

--- TPM Version ---
[OK]  TPM Specification Version
       Version: 2.0 (SpecVersion: 2.0, 0, 1.16). Meets modern Intune requirements.
[i]   Physical Presence Interface: 1.3

--- TPM Manufacturer & Firmware ---
[i]   Manufacturer: INTC (Intel). Firmware: 500.8.0.0
       No known firmware vulnerabilities for this manufacturer/version combination.

--- Lockout State ---
[OK]  TPM Lockout
       Not locked out. LockoutCount: 0 of 32 max. No dictionary attack activity.

--- Attestation & Provisioning ---
[OK]  TPM Base Services (TBS)
       Service is running. TPM stack is operational.
[OK]  Auto-Provisioning
       TPM is owned. Provisioning was successful.
[i]   Owner Auth Retention
       OSManagedAuthLevel: 5. Default (modern) -- Retains lockout auth, discards full owner.
       A TPM clear requires physical presence (reboot + BIOS key press).

RESULT: No issues detected. TPM is healthy and ready for BitLocker.

NEXT:   If TPM not present         -> check BIOS settings (often disabled by default)
        If TPM 1.2                 -> may need hardware upgrade or BIOS setting to enable 2.0 mode
        If firmware flagged        -> visit OEM support site for TPM firmware update
        If TPM locked out          -> wait for lockout to expire, then retry
        If TPM ready               -> run BL003 BLHardwarePrereqs to check other prerequisites
```

#### Boundary with Other Scriptlets

| Scriptlet | What it handles (NOT BL002's job) |
|---|---|
| BL001 BLStatusSnapshot | Volume encryption status, key protectors, lock state, OS drive letter, last BitLocker event |
| BL003 BLHardwarePrereqs | UEFI vs Legacy BIOS, Secure Boot, GPT vs MBR, system partition, Modern Standby |
| BL004 BLIntunePolicy | MDM enrollment, BitLocker CSP settings, policy-hardware comparison |
| BL005 BLEscrowCheck | Recovery key escrow to AAD, device registration, escrow endpoint connectivity |
| BL006 BLPolicyConflict | GPO vs MDM BitLocker policy conflicts |
| BL007 BLEventAnalysis | Full BitLocker event log timeline and error code analysis |

#### Changelog

| Version | Changes |
|---------|---------|
| 1.0 | Initial release. 5 check groups: TPM presence/state (Get-Tpm with tpmtool.exe fallback), TPM version (Win32_Tpm WMI SpecVersion for 1.2 vs 2.0), manufacturer firmware vulnerability scanning (Infineon ROCA CVE-2017-15361, STMicro TPM-FAIL CVE-2019-16863 with version-range matching), lockout state with heal time calculation, attestation/provisioning readiness (TBS service, auto-provisioning, owner auth retention). Early exit when TPM not present. |

---

### BL003 -- BLHardwarePrereqs

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Validates all hardware and firmware prerequisites that must be met before BitLocker can be enabled. Many of these are BIOS settings that PowerShell can detect but **cannot change**. The script clearly distinguishes between "PowerShell can fix this" and "tech must enter BIOS setup."

BL001 tells the tech "this drive is not encrypted." BL002 confirms "the TPM is healthy." BL003 checks everything else at the hardware/firmware layer: boot mode, Secure Boot, disk partition scheme, system partition geometry, power model, and OEM-specific quirks.

#### Usage

```powershell
Invoke-Indago -Name BLHardwarePrereqs
```

No parameters.

#### What It Checks

##### Check 1 -- Boot Mode (UEFI vs Legacy BIOS)

**Primary method:** `Confirm-SecureBootUEFI` cmdlet behavior:
- Returns `$true` or `$false` = machine is UEFI
- Throws "not supported on this platform" = machine is Legacy BIOS

**Fallback methods:** (1) Check `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State` presence (UEFI indicator). (2) Parse `bcdedit /enum {current}` for `.efi` vs `.exe` in the boot path.

| Condition | Verdict |
|-----------|---------|
| UEFI confirmed | `[OK]` Compatible with Intune silent encryption |
| Legacy BIOS | `[!!]` Silent BitLocker NOT supported. Convert to UEFI using MBR2GPT.exe |
| Indeterminate | `[!]` Could not determine boot mode |

##### Check 2 -- Secure Boot Status

**Primary method:** `Confirm-SecureBootUEFI` return value (`$true` = enabled, `$false` = disabled).

**Registry cross-reference:** `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State\UEFISecureBootEnabled` (DWORD: 1 = enabled, 0 = disabled).

| Condition | Verdict |
|-----------|---------|
| Enabled | `[OK]` PCR 7 validation will work |
| Disabled (UEFI) | `[!!]` PCR 7 binding will fail. Enable in BIOS. |
| Not available (Legacy BIOS) | `[i]` Convert to UEFI first |

##### Check 3 -- Disk Partition Scheme (GPT vs MBR)

**Method:** `Get-Disk` on the boot disk (identified by `IsBoot` or `IsSystem` property, fallback to Disk 0).

**CIM fallback:** `Win32_DiskPartition` with type string matching for `GPT*` prefix.

| Condition | Verdict |
|-----------|---------|
| GPT | `[OK]` Compatible with UEFI and BitLocker |
| MBR | `[!!]` Requires conversion to GPT via MBR2GPT.exe |
| RAW / Unknown | `[!!]` No recognized partition table |

##### Check 4 -- System Partition Validation

**Method:** `Get-Partition` on the boot disk to find the EFI System Partition (GPT type GUID `{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`) or the System partition on Legacy. Then `Get-Volume` for format info.

Three sub-checks:

1. **Existence:** Does the system partition exist?
2. **Size:** >= 260 MB ideal, >= 100 MB minimum, < 100 MB critical
3. **Format:** FAT32 expected for UEFI, NTFS for Legacy

| Condition | Verdict |
|-----------|---------|
| Found, >= 260 MB, correct format | `[OK]` Meets all requirements |
| Found, 100-259 MB | `[!]` Minimum met but WinRE may not fit |
| Found, < 100 MB | `[!!]` Below minimum. Repartitioning needed. |
| Not found | `[!!]` Cannot stage pre-boot authentication |
| Wrong format (e.g. NTFS on UEFI) | `[!]` Non-standard layout |

##### Check 5 -- Modern Standby / InstantGo

**Primary method:** Parse `powercfg /a` output for "Standby (S0 Low Power Idle)" strings.

**Registry checks:**
- `HKLM:\SYSTEM\CurrentControlSet\Control\Power\CsEnabled` (1 = Modern Standby active)
- `HKLM:\SYSTEM\CurrentControlSet\Control\Power\PlatformAoAcOverride` (0 = forcefully disabled)

| Condition | Verdict |
|-----------|---------|
| Supported + CsEnabled = 1 | `[OK]` Background Intune policy delivery optimal |
| Not supported | `[i]` Common on desktops. Not a BitLocker blocker. |
| Supported but PlatformAoAcOverride = 0 | `[!]` Forcefully disabled. May impede policy delivery. |

##### Check 6 -- Machine Identification & OEM Quirk Detection

**Method:** `Get-CimInstance Win32_ComputerSystem` (Manufacturer, Model) and `Get-CimInstance Win32_BIOS` (SMBIOSBIOSVersion, ReleaseDate).

Reports manufacturer, model, and BIOS version as informational items. Then flags known OEM issues:

| OEM | Known Issue | Verdict |
|-----|-------------|---------|
| Dell | UEFI Bluetooth Stack causes PCR drift; TPM PPI overrides needed for silent provisioning | `[!]` Advisory |
| Lenovo | Firmware updates shift Secure Boot cert DB, triggering BitLocker recovery prompts fleet-wide | `[!]` Advisory |
| HP | Fast Boot causes recovery key loop after cold boot / hibernation | `[!]` Advisory |
| VM (Hyper-V, VMware) | No OEM quirks apply; notes virtual TPM dependency | `[i]` Informational |

> These are awareness items. We cannot detect actual BIOS settings from the OS. Every OEM advisory states "This cannot be fixed by a script -- tech must enter BIOS setup."

#### Example Output (Healthy UEFI Dell System)

```
=== Hardware & Firmware Prerequisites ===

--- Boot Mode ---
[OK]  Boot Mode
       UEFI. Compatible with Intune silent encryption.

--- Secure Boot ---
[OK]  Secure Boot
       Enabled. PCR 7 validation will work for BitLocker binding.

--- Disk Partition Scheme ---
[OK]  Partition Style
       GPT (Disk 0). Compatible with UEFI and BitLocker.

--- System Partition ---
[OK]  System Partition
       Found. Size: 260 MB. Format: FAT32. Meets all requirements.

--- Modern Standby ---
[OK]  Modern Standby
       Supported and active (CsEnabled = 1).
       Background Intune policy delivery will work optimally.

--- Machine Identification ---
[i]   Manufacturer: Dell Inc.
       Model: Latitude 5540
       BIOS Version: 1.18.2 (Released: 2025-11-15)

[!]   Dell System Advisory
       Dell systems may have "UEFI Bluetooth Stack" enabled in BIOS, which causes
       PCR measurement drift and prompts for the BitLocker recovery key after reboots.
       If this occurs, check BIOS > Connection > Disable "Enable UEFI Bluetooth Stack".
       Also verify TPM Physical Presence Interface (PPI) overrides are enabled
       in BIOS for silent TPM provisioning.
       These settings cannot be fixed by a script -- tech must enter BIOS setup.

RESULT: 1 warning(s) found. Review the flagged items above.

NEXT:   If Legacy BIOS        -> convert to UEFI (MBR2GPT.exe) -- requires planning
        If Secure Boot off    -> enable in BIOS settings
        If MBR disk           -> convert to GPT before enabling BitLocker
        If all prereqs met    -> run BL004 BLIntunePolicy to check MDM configuration
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Encryption status, key protectors, OS drive letter, BDESVC | BL001 BLStatusSnapshot |
| TPM presence, version, firmware vulns, lockout, attestation | BL002 BLTpmHealth |
| Intune MDM enrollment, BitLocker CSP policy settings | BL004 BLIntunePolicy |
| Recovery key escrow, AAD connectivity | BL005 BLEscrowCheck |
| GPO vs MDM policy conflict (FVE keys) | BL006 BLPolicyConflict |
| Full event log timeline, HRESULT codes | BL007 BLEventAnalysis |
| WinRE status, manage-bde deep diagnostics, readiness dry run | BL008 BLReadinessCheck |
| TPM remediation, key protector cleanup | BL009 BLTpmRemediation |

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 6 check groups: boot mode detection (Confirm-SecureBootUEFI with bcdedit and registry fallbacks), Secure Boot status with registry cross-reference, disk partition scheme GPT/MBR via Get-Disk with Win32_DiskPartition CIM fallback, system partition validation (EFI partition existence, size thresholds at 100/260 MB, FAT32/NTFS format check), Modern Standby detection via powercfg /a + CsEnabled + PlatformAoAcOverride registry, OEM identification with Dell/Lenovo/HP quirk advisories (UEFI Bluetooth Stack, firmware PCR drift, Fast Boot loops) and VM detection (Hyper-V, VMware). |

---

### BL004 -- BLIntunePolicy

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Bridges the gap between what Intune expects and what the local machine is configured for regarding BitLocker. BL001 tells the tech "this drive is not encrypted." BL002 confirms "the TPM is healthy." BL003 confirms "the hardware prerequisites are met." BL004 answers the next question: **Has the machine actually received the BitLocker policy from Intune, and is the policy internally consistent with the hardware?**

A machine can pass every hardware check and still fail BitLocker encryption because it's not enrolled in Intune, the BitLocker CSP payload never arrived, the policy demands a cipher the hardware doesn't support, or the policy requires silent encryption but also demands a TPM+PIN (contradictory).

#### Usage

```powershell
Invoke-Indago -Name BLIntunePolicy
```

No parameters.

#### What It Checks

##### Check 1 -- MDM Enrollment Status via dsregcmd /status

Executes `dsregcmd.exe /status` and parses the structured text output with regex for key enrollment fields:

| Field | Section | What It Tells Us |
|-------|---------|------------------|
| `AzureAdJoined` | Device State | Is the machine joined to Entra ID? |
| `DomainJoined` | Device State | Is the machine joined to on-prem AD? |
| `WorkplaceJoined` | User State | Is this a BYOD registration? |
| `MdmUrl` | Tenant Details | Is there an MDM endpoint configured? |
| `DeviceId` | Device State | Entra ID device object GUID (informational) |

**5 derived join states:**

| AzureAdJoined | DomainJoined | WorkplaceJoined | State |
|---|---|---|---|
| YES | NO | - | Entra ID Joined (cloud-native) |
| YES | YES | - | Hybrid Entra ID Joined |
| NO | YES | - | On-prem AD only (no cloud join) |
| NO | NO | YES | Workplace Joined (BYOD) |
| NO | NO | NO | Not joined to anything |

| Condition | Verdict |
|-----------|---------|
| AzureAdJoined + MdmUrl present | `[OK]` Enrolled and MDM URL configured |
| AzureAdJoined + MdmUrl empty | `[!!]` Joined but no MDM URL -- license or scope issue |
| Not Entra joined | `[!!]` Intune policies cannot be delivered |
| Workplace Joined only | `[!]` BYOD -- no device-level BitLocker policies |
| Hybrid joined | `[i]` Note about dual policy delivery (GPO + MDM) |

##### Check 2 -- BitLocker CSP Settings from Registry

Reads `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker`:

| Registry Value | What It Controls | Decode |
|---|---|---|
| `RequireDeviceEncryption` | Master Intune BitLocker switch | 1 = Required |
| `EncryptionMethodByDriveType` | Cipher strength (XML encoded) | Parsed for OS/Fixed/Removable cipher integers |
| `AllowStandardUserEncryption` | Bypass UAC for standard users | 1 = Allowed (needed for Autopilot) |
| `AllowWarningForOtherDiskEncryption` | Third-party encryption warning | 0 = Suppressed (needed for silent) |
| `SystemDrivesRequireStartupAuthentication` | Pre-boot auth config (XML) | TPM-only vs TPM+PIN detection |

**Cipher integer mapping:**

| Integer | Algorithm |
|---------|-----------|
| 3 | AES-CBC 128-bit |
| 4 | AES-CBC 256-bit |
| 6 | XTS-AES 128-bit |
| 7 | XTS-AES 256-bit |

If the registry path doesn't exist, reports `[!]` -- Intune has not delivered a BitLocker policy.

##### Check 3 -- Policy vs Hardware Comparison

Cross-references CSP settings from Check 2 against known hardware capabilities:

| Scenario | Verdict |
|----------|---------|
| Policy demands XTS-AES but OS build < 10586 (pre-1511) | `[!!]` XTS not supported |
| Policy requires TPM+PIN but silent encryption expected | `[!!]` Silent impossible |
| AllowWarningForOtherDiskEncryption not suppressed | `[!]` Breaks silent provisioning |
| Policy cipher differs from currently encrypted volume | `[!]` Full decrypt/re-encrypt required |
| All settings compatible | `[OK]` Silent path is clear |

> **Note:** Only reads current encryption method for narrow comparison -- does not duplicate BL001's full volume status.

##### Check 4 -- Intune Management Extension Logs

**Log location:** `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`

- Reads last 5000 lines of the flat file
- Searches for `BitLocker` keyword (case-insensitive)
- Displays last 20 matching entries with timestamp and message
- Parses IME log format: `<![LOG[message]LOG]!><time="" date="" ...>`
- If no matches: `[i]` no BitLocker activity in log
- If log missing: `[!]` IME may not be installed

##### Check 5 -- MDM Enrollment Health

**Sub-check 5a: EnterpriseMgmt Scheduled Tasks**

Queries `Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*'` for MDM sync tasks. Reports task name, last run time, and last result code. Flags non-zero results as failures.

**Sub-check 5b: MDM Enrollment Certificate**

Searches `Cert:\LocalMachine\My` for certificates issued by `SC_Online_Issuing` or `Microsoft Intune MDM Device CA`. Reports issuer, expiration date, and days remaining. Flags expired certificates as `[!!]` and certificates expiring within 30 days as `[!]`.

#### Example Output (Healthy Enrolled System)

```
=== Intune Policy & MDM Enrollment Check ===

--- MDM Enrollment Status ---
[OK]  Entra ID Joined (cloud-native)
       AzureAdJoined: YES. DomainJoined: NO.
[OK]  MDM URL Configured
       MdmUrl: https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc
       Intune enrollment channel is present.
[i]   DeviceId: a1b2c3d4-e5f6-7890-abcd-ef1234567890

--- BitLocker CSP Policy ---
[OK]  RequireDeviceEncryption: 1 (Required)
       Intune is requiring BitLocker encryption on this device.
[i]   Encryption Method: XTS-AES 256-bit (OS), XTS-AES 256-bit (Fixed), AES-CBC 128-bit (Removable)
[OK]  AllowStandardUserEncryption: 1 (Allowed)
[OK]  AllowWarningForOtherDiskEncryption: 0 (Suppressed -- silent encryption enabled)
[OK]  Startup Authentication: TPM-only (silent compatible)

--- Policy vs Hardware ---
[OK]  Cipher Compatibility
       XTS-AES is supported on this OS build (22621).
[OK]  Silent Encryption Coherence
       Policy settings are compatible with silent encryption path.

--- Intune Management Extension Logs ---
[i]   BitLocker-related IME entries: 3 found. Showing last 3.
       [04-02-2026 14:22:15] BitLocker CSP policy applied successfully
       [04-02-2026 14:22:14] RequireDeviceEncryption set to 1
       [04-02-2026 14:21:58] Processing BitLocker configuration policy

--- MDM Enrollment Health ---
[OK]  MDM Sync Tasks: 2 found
       Task: Schedule #1 created by OMA-DM client
       Last run: 2026-04-03 12:15. Result: 0x0 (Success).
[OK]  MDM Device Certificate
       Issuer: SC_Online_Issuing. Expires: 2027-04-03. Valid (365 days remaining).

RESULT: No issues detected. Intune BitLocker policy is present and coherent.

NEXT:   If not MDM enrolled       -> re-enroll the device in Intune
        If policy not received    -> force Intune sync and wait 15 minutes
        If policy conflicts       -> run BL006 BLPolicyConflict to check GPO vs MDM
        If policy looks correct   -> run BL005 BLEscrowCheck to verify key escrow
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Volume encryption status, ghost state, key protectors | BL001 BLStatusSnapshot |
| TPM presence, version, firmware, lockout, attestation | BL002 BLTpmHealth |
| UEFI/BIOS, Secure Boot, GPT/MBR, system partition, OEM quirks | BL003 BLHardwarePrereqs |
| Recovery key escrow, AAD connectivity, escrow endpoints | BL005 BLEscrowCheck |
| GPO vs MDM BitLocker policy conflict (FVE keys) | BL006 BLPolicyConflict |
| Full event log timeline, HRESULT translation | BL007 BLEventAnalysis |
| WinRE status, manage-bde diagnostics, readiness dry run | BL008 BLReadinessCheck |
| TPM remediation, key protector cleanup | BL009 BLTpmRemediation |

**Overlap notes:**
- BL004 reads `PolicyManager\current\device\BitLocker` (MDM side). BL006 compares `Policies\Microsoft\FVE` (GPO+MDM merged enforcement). No overlap.
- BL004 parses `dsregcmd` for enrollment status. BL005 dives deeper into device registration (PRT tokens, device certificates for AAD trust, escrow endpoints). BL004 is "are we enrolled?" -- BL005 is "can we escrow?"
- BL004 reads current encryption method for narrow cipher-mismatch comparison. BL001 does the full volume status report. No overlap.

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 5 check groups: dsregcmd /status parsing for MDM enrollment (AzureAdJoined, DomainJoined, WorkplaceJoined, MdmUrl, DeviceId with 5 derived join states), BitLocker CSP registry decode at PolicyManager/current/device/BitLocker (RequireDeviceEncryption, EncryptionMethodByDriveType XML regex for OS/Fixed/Removable cipher integers mapped to 4 algorithms, AllowStandardUserEncryption, AllowWarningForOtherDiskEncryption, SystemDrivesRequireStartupAuthentication with TPM+PIN detection via UseTPMPIN/UseTPMKeyPIN XML parsing), policy-hardware cross-reference (XTS vs OS build 10586 threshold, TPM+PIN vs silent, AllowWarning coherence, cipher mismatch with Get-BitLockerVolume), IME log scan (last 5000 lines of IntuneManagementExtension.log, BitLocker keyword search, 20 most recent matches with timestamp extraction), MDM enrollment health (EnterpriseMgmt scheduled tasks with last run/result, MDM device certificate from Cert:\\LocalMachine\\My with 30-day expiration warning). |

---

### BL005 -- BLEscrowCheck

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Traces the recovery key escrow pipeline when BitLocker encryption silently fails. The sneakiest failure mode: Intune requires encryption, BitLocker activates, tries to escrow the recovery key to Entra ID, the escrow fails silently, and BitLocker **rolls back encryption** -- invisible unless you specifically look for it.

BL001 catches the downstream symptom ("volume not encrypted" or "no recovery key"). BL005 diagnoses the **escrow pipeline itself**: Is escrow required by policy? Can the device authenticate to Entra? Has escrow been attempted, and what happened? Can the machine reach the cloud endpoints?

#### Usage

```powershell
Invoke-Indago -Name BLEscrowCheck
```

No parameters.

#### What It Checks

##### Check 1 -- Escrow Policy Requirements

Reads the FVE registry hive to determine whether the escrow gate is active -- meaning encryption is blocked until the recovery key is successfully backed up.

**Registry path:** `HKLM:\SOFTWARE\Policies\Microsoft\FVE`

| Value | Meaning | Verdict |
|---|---|---|
| `OSRequireActiveDirectoryBackup` = 1 | OS drive encryption BLOCKED until key is escrowed | `[i]` (escalated to `[!!]` CRITICAL if escrow has failed in Check 3) |
| `OSRequireActiveDirectoryBackup` = 0 or not set | Escrow not required for encryption to proceed | `[OK]` |
| `FDVRequireActiveDirectoryBackup` = 1 | Fixed data drives also gated by escrow | `[i]` informational |
| `OSActiveDirectoryInfoToStore` | 1 = key + packages (forensic), 2 = password only | `[i]` informational |

> **Why this matters:** When `OSRequireActiveDirectoryBackup = 1` and escrow fails, BitLocker is architecturally blocked -- encryption will never begin. The OS silently rolls back any encryption attempt, generating Event 778 (rollback) and Event 851 (silent encryption failed).

##### Check 2 -- AAD Device Registration & Identity Health

Executes `dsregcmd.exe /status` and parses **escrow-relevant** identity fields (not the enrollment fields BL004 already covers).

| Field | What BL005 Checks | Verdict |
|---|---|---|
| `AzureAdJoined` | Is cloud escrow structurally possible? | `[OK]` YES, `[!!]` NO |
| `AzureAdPrt` | Primary Refresh Token present for background auth? | `[OK]` YES, `[!!]` NO |
| `DeviceAuthStatus` | Can the device authenticate to Entra? | `[OK]` SUCCESS, `[!!]` FAILED (zombie) |
| `TpmProtected` | Identity key stored in hardware TPM? | `[OK]` YES, `[!]` NO |
| `TenantId` | Which Entra tenant receives the escrow | `[i]` informational |

**Zombie PRT detection:** If `AzureAdJoined = YES` but `DeviceAuthStatus = FAILED`, the device is in a "zombie" state -- it believes it's joined but its tokens are rejected by the cloud STS. Escrow transmissions will be rejected. Reports `[!!]` with `dsregcmd /leave` + `/join` guidance.

> **Key distinction from BL004:** BL004 Check 1 reads `AzureAdJoined`, `DomainJoined`, `WorkplaceJoined`, `MdmUrl`, `DeviceId` (enrollment status). BL005 reads `AzureAdPrt`, `DeviceAuthStatus`, `TpmProtected`, `TenantId` (identity health for escrow). Completely different fields, complementary purpose.

##### Check 3 -- Escrow Event History (Last 7 Days)

Queries `Microsoft-Windows-BitLocker/BitLocker Management` for escrow-specific events.

| Event ID | Category | What We Report |
|---|---|---|
| 845 | Success | Recovery key backed up to Entra ID. Timestamp + volume. |
| 846 | Failure | Escrow **FAILED**. Timestamp + HRESULT from message body. |
| 851 | Failure | Silent encryption failed (downstream of 846 when escrow gate active). |
| 858 | Failure | Key rotation failed (device not ready / domain unreachable). |
| 778 | Rollback | Volume reverted to unprotected state (encryption rolled back). |

**HRESULT translation table (6 codes):**

| HRESULT | Translation |
|---|---|
| `0x80072f9a` | SYSTEM lacks cert access or SSL inspection breaking Entra auth |
| `0x80310059` | Overlapping operation -- GPO/MDM collision or filter driver interference |
| `0x80072efe` | Connection aborted -- firewall, VPN, or proxy dropped payload |
| `0x8007054B` | DNS failure -- cannot resolve Entra ID endpoint |
| `0x80310018` | TPM not owned -- cannot generate Volume Master Key |
| `0x803100B5` | No pre-boot keyboard or WinRE missing -- slate device block |

**Critical escalation:** If Event 846 (escrow failed) is found AND `OSRequireActiveDirectoryBackup = 1`, reports `[!!]` CRITICAL -- encryption is architecturally blocked and will never start.

**200-key limit hint:** If 3+ failures with zero successes in the 7-day window, notes the Entra ID 200-key hard limit as a possible cause (cannot be detected locally -- admin must check Entra portal).

> **Key distinction from BL001:** BL001 Check 3 shows the single most recent BitLocker management event of any type. BL005 does a targeted multi-event search for 5 escrow-specific Event IDs over a 7-day window with HRESULT translation.

##### Check 4 -- Escrow Endpoint Connectivity

TCP 443 reachability test (3-second timeout) to cloud endpoints required for the escrow transmission. Since Indago runs as SYSTEM, these naturally test in the SYSTEM network context -- exactly how the real escrow operates.

| Endpoint | Purpose | Verdict |
|---|---|---|
| `login.microsoftonline.com` | OAuth token acquisition for escrow auth | `[!!]` if unreachable |
| `enterpriseregistration.windows.net` | Device Registration Service -- accepts the key payload | `[!!]` if unreachable |
| `device.login.microsoftonline.com` | Device identity verification and compliance | `[!!]` if unreachable |

##### Check 5 -- Recovery Key Protector Status

Reads `Get-BitLockerVolume` for the OS volume and examines the `KeyProtector` array.

- Lists all protectors by type (Tpm, RecoveryPassword, ExternalKey, etc.)
- For each `RecoveryPassword` protector: extracts the `KeyProtectorId` GUID
- Cross-references GUID against successful Event 845 messages from Check 3
- Reports whether each recovery key has confirmed escrow evidence

| Condition | Verdict |
|---|---|
| RecoveryPassword GUID found in Event 845 | `[OK]` Escrow confirmed |
| RecoveryPassword GUID NOT found in Event 845 | `[!]` No escrow confirmation in last 7 days |
| No RecoveryPassword protector exists | `[!!]` No key to escrow |
| Volume not encrypted | `[i]` Key protectors not applicable |

##### Check 6 -- WinRE Status (Lightweight)

Executes `reagentc.exe /info` and parses for WinRE enabled/disabled status.

| Condition | Verdict |
|---|---|
| WinRE Enabled | `[OK]` Silent encryption and key rotation prerequisites met |
| WinRE Disabled | `[!!]` Silent encryption will fail (Event 854), key rotation will fail (Event 858) |
| Could not query | `[!]` WinRE status unknown |

> **Scope note:** This is a lightweight check -- just enabled/disabled. BL008 BLReadinessCheck does the full WinRE diagnostics (image path, partition, version).

#### Example Output (Healthy Escrowed System)

```
=== Recovery Key Escrow Diagnostics ===

--- Escrow Policy Requirements ---
[i]   Escrow Policy: OSRequireActiveDirectoryBackup = 1
       Encryption will NOT begin until the recovery key is backed up to AD/AAD.
       If escrow fails, encryption is blocked indefinitely.

--- AAD Device Registration & Identity Health ---
[OK]  AzureAdJoined: YES
       Device is joined to Entra ID. Cloud escrow is structurally possible.
[OK]  AzureAdPrt: YES
       Primary Refresh Token is present. Background auth to AAD will work.
[OK]  DeviceAuthStatus: SUCCESS
       Device can authenticate to Entra ID. Identity is healthy.
[OK]  TpmProtected: YES
       Device identity key is stored in hardware TPM. Secure.
[i]   TenantId: a1b2c3d4-e5f6-7890-abcd-ef1234567890
       Escrow will target this Entra ID tenant.

--- Escrow Event History (Last 7 Days) ---
[OK]  Escrow Success (Event 845): 1 in last 7 days
       Last successful escrow: 2026-04-02 14:30.
       Recovery key was backed up to Entra ID.

--- Escrow Endpoint Connectivity ---
[OK]  login.microsoftonline.com:443 -- Reachable
       OAuth token acquisition for escrow authentication
[OK]  enterpriseregistration.windows.net:443 -- Reachable
       Device Registration Service -- accepts the key payload
[OK]  device.login.microsoftonline.com:443 -- Reachable
       Device identity verification and compliance checks

--- Recovery Key Protector Status ---
[i]   Key Protectors on C:: 2 total (Tpm, RecoveryPassword)
[OK]  RecoveryPassword A1B2C3D4-E5F6-7890-ABCD-EF1234567890
       Escrow confirmed -- Event 845 found for this key protector.

--- WinRE Status ---
[OK]  WinRE: Enabled
       Windows Recovery Environment is active. Silent encryption and
       key rotation prerequisites are met.

RESULT: No escrow issues detected. Recovery key pipeline appears healthy.

NEXT:   If escrow failed due to connectivity -> fix network (see WU003 WUNetworkCheck)
        If device registration broken       -> run dsregcmd /leave then re-join
        If escrow gate active + key missing  -> run BL009 BLTpmRemediation
        If no escrow events + volume decrypted -> policy may not have triggered -- run BL004
        If repeated 846 despite healthy state -> check Entra portal for 200-key limit
        If WinRE disabled                    -> reagentc /enable or run BL008 BLReadinessCheck
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| Volume encryption status, ghost state, key protector presence, BDESVC | BL001 BLStatusSnapshot |
| TPM presence, version, firmware, lockout, attestation | BL002 BLTpmHealth |
| UEFI, Secure Boot, GPT/MBR, system partition, Modern Standby, OEM quirks | BL003 BLHardwarePrereqs |
| MDM enrollment status, BitLocker CSP settings, policy-hardware comparison | BL004 BLIntunePolicy |
| GPO vs MDM BitLocker policy conflict (FVE keys) | BL006 BLPolicyConflict |
| Full event log timeline, comprehensive HRESULT translation | BL007 BLEventAnalysis |
| Full WinRE diagnostics, manage-bde, readiness dry run | BL008 BLReadinessCheck |
| Key protector cleanup, forced escrow, TPM remediation | BL009 BLTpmRemediation |

**Overlap notes:**
- BL001 Check 3 shows the single most recent BitLocker event. BL005 Check 3 does a targeted 7-day search for 5 escrow-specific Event IDs with HRESULT translation. No overlap.
- BL004 Check 1 reads `dsregcmd` for enrollment fields (AzureAdJoined, DomainJoined, MdmUrl, DeviceId). BL005 Check 2 reads `dsregcmd` for identity health fields (AzureAdPrt, DeviceAuthStatus, TpmProtected, TenantId). Complementary, no duplicate fields.
- BL004 Check 2 reads `PolicyManager\current\device\BitLocker` (MDM CSP). BL005 Check 1 reads `Policies\Microsoft\FVE` (GPO escrow gate). Different registry paths, different questions.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 6 check groups: escrow policy requirements from FVE registry (OSRequireActiveDirectoryBackup gate, FDVRequireActiveDirectoryBackup, OSActiveDirectoryInfoToStore), AAD device registration via dsregcmd /status parsing for AzureAdPrt/DeviceAuthStatus/TpmProtected/TenantId with zombie PRT detection, escrow event history 7-day window for Event IDs 845/846/851/858/778 with 6-code HRESULT table and 200-key limit hint, escrow endpoint connectivity TCP 443 to login.microsoftonline.com + enterpriseregistration.windows.net + device.login.microsoftonline.com with 3-second timeout, recovery key protector status with GUID-to-Event 845 cross-reference for escrow confirmation, lightweight WinRE check via reagentc /info. |

---

### BL006 -- BLPolicyConflict

**Version:** 1.0
**Category:** BitLocker
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Detects group policy vs MDM conflicts that silently block BitLocker encryption in hybrid-managed environments. A single orphaned GPO registry value in the FVE hive can completely override an Intune BitLocker policy, causing silent encryption failures that are extremely difficult to diagnose without direct registry comparison.

BL006 answers: "Are there conflicting or orphaned GPO settings that are blocking MDM-driven BitLocker encryption?"

> **Key insight:** `MDMWinsOverGP = 1` does NOT fully apply to settings governed by the BitLocker CSP. Many BitLocker GPO settings lack a direct 1:1 mapping in the modern BitLocker CSP, so legacy FVE registry values will continue to override MDM policy even when MDMWinsOverGP is enabled. This is the same architectural limitation as with the Defender CSP (see DEF005).

#### Usage

```powershell
Invoke-Indago -Name BLPolicyConflict
```

No parameters.

#### What It Checks

##### Check 1 -- GPO-Delivered BitLocker Settings (FVE Registry)

Reads and decodes all known BitLocker Group Policy settings from `HKLM:\SOFTWARE\Policies\Microsoft\FVE`.

**Settings enumerated:**

| Registry Value | Decoded Meaning |
|---|---|
| `EncryptionMethodWithXtsOs` | OS drive cipher: 3=AES-CBC-128, 4=AES-CBC-256, 6=XTS-AES-128, 7=XTS-AES-256 |
| `EncryptionMethodWithXtsFdv` | Fixed data drive cipher (same mapping) |
| `EncryptionMethodWithXtsRdv` | Removable drive cipher (same mapping) |
| `UseTPM` | 0=Do not allow, 1=Require, 2=Allow TPM |
| `UseTPMPIN` | 0=Do not allow, 1=Require, 2=Allow startup PIN |
| `UseTPMKey` | 0=Do not allow, 1=Require, 2=Allow startup key |
| `UseTPMKeyPIN` | 0=Do not allow, 1=Require, 2=Allow TPM+Key+PIN |
| `MinimumPIN` | Minimum PIN length (4-20) |
| `OSRecovery` | 1=Allow recovery |
| `OSRequireActiveDirectoryBackup` | 1=Must escrow to AD DS before enabling |
| `OSActiveDirectoryInfoToStore` | 1=Passwords+packages, 2=Passwords only |
| `EnableBDEWithNoTPM` | 1=Allow BitLocker without TPM |

**Legacy platform validation subkeys:**
- `HKLM:\...\FVE\OSPlatformValidation_BIOS`
- `HKLM:\...\FVE\OSPlatformValidation_UEFI`

These legacy PCR profile keys are a primary cause of silent encryption failure on Intune-managed devices (HRESULT `0x80310059`).

| Condition | Verdict |
|---|---|
| FVE path absent | `[OK]` No GPO BitLocker settings |
| FVE path present with values | `[i]` Report each setting with decoded meaning |
| Legacy platform validation subkeys present | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` May block MDM encryption |

##### Check 2 -- MDM-Delivered BitLocker Settings (PolicyManager)

Reads BitLocker CSP settings from `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker`.

**Settings read:**

| Registry Value | Meaning |
|---|---|
| `RequireDeviceEncryption` | 1=Encryption required |
| `EncryptionMethodByDriveType` | XML-encoded cipher configuration (parsed for OS drive cipher value) |
| `SystemDrivesRequireStartupAuthentication` | XML-encoded startup auth config (parsed for PIN requirement) |
| `SystemDrivesMinimumPINLength` | Minimum PIN length |
| `AllowWarningForOtherDiskEncryption` | 0=Silent encryption, 1=Show warnings |

XML fields are parsed using regex pattern matching to extract `EncryptionMethodWithXtsOsDropDown_Name` and `ConfigureTPMPINUsageDropDown_Name` values.

> **Scope note:** BL004 also reads `PolicyManager\current\device\BitLocker` to report what MDM configured. BL006 reads the same path but solely to compare against GPO values for conflict detection. Different question, complementary answers.

| Condition | Verdict |
|---|---|
| Path absent | `[i]` No MDM BitLocker settings |
| `RequireDeviceEncryption = 1` | `[OK]` MDM requires encryption |
| Path exists but encryption not required | `[i]` MDM path exists but not actively managing encryption |

##### Check 3 -- Conflict Detection (GPO vs MDM)

Performs side-by-side comparison of specific policy facets:

**3a -- Encryption Method:**

| Condition | Verdict |
|---|---|
| GPO and MDM specify different cipher | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` CONFLICT -- GPO takes precedence |
| GPO and MDM agree | `[OK]` No cipher conflict |
| Only GPO sets cipher | `[i]` GPO value used, no MDM counterpart |

**3b -- Startup Authentication (PIN):**

| Condition | Verdict |
|---|---|
| GPO requires PIN but MDM says TPM-only | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` CONFLICT -- blocks silent encryption |
| GPO requires PIN, MDM silent encryption enabled | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` PIN requirement blocks silent encryption |
| GPO and MDM agree on PIN setting | `[OK]` No conflict |

**3c -- AD Backup Deadlock:**

| Condition | Verdict |
|---|---|
| GPO requires AD DS backup + machine NOT domain-joined | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` DEADLOCK -- encryption can never succeed (HRESULT `0x80072f9a`) |
| GPO requires AD DS backup + machine domain-joined + Intune-managed | `[]` Dual-escrow requirement in hybrid |

**3d -- Minimum PIN Length:**

| Condition | Verdict |
|---|---|
| GPO and MDM specify different PIN lengths | `[]` Warning |
| GPO and MDM agree | `[OK]` No conflict |

##### Check 4 -- MDMWinsOverGP Assessment

Reads `MDMWinsOverGP` from `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict`.

> **Critical architectural fact:** `MDMWinsOverGP` only applies to settings governed by the Policy CSP that have explicit ADMX-backed or GPRegistryMapped mappings. Many BitLocker GPO settings lack a 1:1 mapping in the BitLocker CSP, so `MDMWinsOverGP=1` does NOT guarantee MDM supremacy for BitLocker specifically.

| Condition | Verdict |
|---|---|
| `MDMWinsOverGP = 1` + GPO FVE settings exist | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` FALSE SENSE OF SECURITY -- BitLocker CSP not fully covered |
| `MDMWinsOverGP = 1` + no FVE conflicts | `[i]` Active but no conflicts |
| Not set or = 0 + FVE + MDM settings exist | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` GPO takes precedence, Intune may be ignored |
| Not set or = 0 + no FVE settings | `[OK]` Standard behavior |

##### Check 5 -- Orphaned GPO Settings Detection

Detects "tattooed" FVE registry values left behind from previous domain membership. Uses `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` to determine domain-join state.

| Condition | Verdict |
|---|---|
| FVE has values + machine NOT domain-joined | `[python3 << 'PYEOF'
import json

# Read the script
with open('/tmp/BL006_full.ps1', 'r') as f:
    script_body = f.read()

# Read the catalog
with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
    catalog = json.load(f)

# Build the new entry
entry = {
    "Id": "BL006",
    "Name": "BLPolicyConflict",
    "DisplayName": "BitLocker Group Policy vs MDM Conflict Detection",
    "Category": "BitLocker",
    "Description": "Detects group policy vs MDM conflicts that silently block BitLocker encryption. Reads GPO settings from HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE and MDM settings from PolicyManager, compares encryption method, startup authentication, recovery password, and PIN length. Checks MDMWinsOverGP assessment with BitLocker CSP limitation warning. Detects orphaned (tattooed) GPO settings from previous domain membership.",
    "ExecutionContext": "System",
    "Parameters": {},
    "Script": script_body,
    "Tags": ["bitlocker", "gpo", "mdm", "conflict", "hybrid", "diagnostic"],
    "Version": "1.0",
    "Notes": "Read-only diagnostic. 5 check groups: (1) GPO-delivered BitLocker settings from FVE registry with cipher/TPM usage decode tables and legacy PCR validation subkey detection. (2) MDM-delivered BitLocker settings from PolicyManager with XML parsing for EncryptionMethodByDriveType and SystemDrivesRequireStartupAuthentication. (3) Conflict detection comparing encryption method, startup PIN, AD backup deadlock, and minimum PIN length between GPO and MDM. (4) MDMWinsOverGP assessment at PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning (MDMWinsOverGP does NOT fully apply to BitLocker CSP settings). (5) Orphaned GPO settings detection via domain-join state check with specific dangerous patterns (legacy PCR profiles, AD backup on non-domain device, orphaned PIN requirement)."
}

# Find insertion point -- after BL005
insert_idx = None
for i, e in enumerate(catalog):
    if e['Id'] == 'BL005':
        insert_idx = i + 1
        break

if insert_idx is None:
    print("ERROR: Could not find BL005 in catalog")
else:
    catalog.insert(insert_idx, entry)
    with open('Scriptlets/ScriptletCatalog.json', 'w') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"SUCCESS: BL006 inserted at index {insert_idx}")
    print(f"Catalog now has {len(catalog)} entries")
    
    # Verify
    with open('Scriptlets/ScriptletCatalog.json', 'r') as f:
        verify = json.load(f)
    bl006 = [e for e in verify if e['Id'] == 'BL006']
    if bl006:
        print(f"BL006 found with Name={bl006[0]['Name']}")
    else:
        print("ERROR: BL006 not found after insertion")
PYEOF]` Orphaned -- tattooed from previous domain |
| FVE has values + domain-joined + Intune-managed (hybrid) | `[]` GPO settings in hybrid -- review for conflicts |
| FVE has values + domain-joined only | `[OK]` Expected from Active Directory |
| No FVE values | `[OK]` Clean registry |

**Specific dangerous orphan patterns flagged:**
- `OSPlatformValidation_BIOS` / `OSPlatformValidation_UEFI` subkeys (primary cause of `0x80310059`)
- `OSRequireActiveDirectoryBackup = 1` on non-domain device (causes `0x80072f9a`)
- `UseTPMPIN = 1` on non-domain device (blocks silent MDM encryption)

#### Example Output (Healthy System, Intune-Managed, No GPO)

```
=== BitLocker Group Policy vs MDM Conflict Detection ===

--- GPO BitLocker Settings (FVE Registry) ---
[OK]  GPO BitLocker Settings
       HKLM:\...\FVE path does not exist. No GPO BitLocker settings are configured.

--- MDM BitLocker Settings (PolicyManager) ---
[OK]  RequireDeviceEncryption (MDM)
       RequireDeviceEncryption = 1. MDM requires device encryption.
[i]   OS Drive Cipher (MDM)
       EncryptionMethodByDriveType OS cipher = 7 (XTS-AES 256-bit)
[i]   Silent Encryption (MDM)
       AllowWarningForOtherDiskEncryption = 0. Silent encryption enabled (no user warnings).

--- Conflict Detection ---
[OK]  Conflict Summary
       No GPO BitLocker settings present. No GPO vs MDM conflicts possible.

--- MDMWinsOverGP Assessment ---
[OK]  MDMWinsOverGP Assessment
       MDMWinsOverGP is not set. Standard GPO precedence (default behavior). No active conflict detected.

--- Orphaned GPO Settings ---
[OK]  Orphaned GPO Settings
       No GPO BitLocker settings in FVE registry. No orphaned settings possible.

RESULT: No policy conflicts detected. GPO and MDM BitLocker settings are consistent.

NEXT:   If conflicts found         -> set MDMWinsOverGP=1, or remove conflicting GPO settings
        If orphaned GPO settings   -> clear HKLM:\SOFTWARE\Policies\Microsoft\FVE manually
        If no conflicts            -> run BL007 BLEventAnalysis for the failure timeline
```

#### Scope Boundaries

| Concern | Handled By |
|---|---|
| Volume encryption status, protection, key protectors, drive letters, BDESVC | BL001 BLStatusSnapshot |
| TPM presence, state, version, firmware, lockout, attestation | BL002 BLTpmHealth |
| UEFI/BIOS, Secure Boot, GPT/MBR, system partition, Modern Standby | BL003 BLHardwarePrereqs |
| MDM enrollment, BitLocker CSP decode, policy-hardware cross-reference, IME logs | BL004 BLIntunePolicy |
| Escrow policy, AAD identity, escrow events, cloud connectivity, key protector status, WinRE | BL005 BLEscrowCheck |
| Event log timeline, error code translation | BL007 BLEventAnalysis |
| Encryption readiness dry run | BL008 BLReadinessCheck |
| TPM repair, key protector remediation | BL009 BLTpmRemediation |
| Forced encryption | BL010 BLForceEncrypt |

**Overlap notes:**
- BL004 reads `PolicyManager\current\device\BitLocker` to report MDM configuration. BL006 reads the same path to compare against GPO. Different question, complementary answers.
- BL005 reads 3 specific FVE keys (OSRequireActiveDirectoryBackup, FDVRequireActiveDirectoryBackup, OSActiveDirectoryInfoToStore) for escrow pipeline analysis. BL006 reads the full FVE hive for encryption method, startup auth, and recovery settings. Disjoint policy surfaces.
- DEF005 performs an analogous MDMWinsOverGP assessment for Defender CSP. BL006 does the same for BitLocker CSP. Same architectural insight (MDMWinsOverGP does NOT apply to all CSP settings), different policy domains.

#### Version History

| Version | Changes |
|---|---|
| 1.0 | Initial build. 5 check groups: GPO-delivered BitLocker settings from FVE registry with cipher method decode table (3=AES-CBC-128, 4=AES-CBC-256, 6=XTS-AES-128, 7=XTS-AES-256), TPM usage decode table (0=Do not allow, 1=Require, 2=Allow) for UseTPM/UseTPMPIN/UseTPMKey/UseTPMKeyPIN, MinimumPIN, OSRecovery, OSRequireActiveDirectoryBackup, OSActiveDirectoryInfoToStore, EnableBDEWithNoTPM, plus legacy platform validation subkey (OSPlatformValidation_BIOS/UEFI) detection. MDM-delivered BitLocker settings from PolicyManager with RequireDeviceEncryption, EncryptionMethodByDriveType XML parsing for OS cipher, SystemDrivesRequireStartupAuthentication XML parsing for PIN requirement, SystemDrivesMinimumPINLength, AllowWarningForOtherDiskEncryption silent encryption detection. Side-by-side conflict detection: encryption method mismatch, startup PIN vs silent encryption conflict, AD backup deadlock (OSRequireActiveDirectoryBackup=1 on non-domain device with HRESULT 0x80072f9a), minimum PIN length mismatch. MDMWinsOverGP assessment from PolicyManager/current/device/ControlPolicyConflict with BitLocker CSP limitation warning. Orphaned GPO settings detection via Win32_ComputerSystem.PartOfDomain with hybrid environment awareness and specific dangerous orphan patterns (legacy PCR profiles, AD backup on non-domain, orphaned PIN requirement). |

---

## Firewall Suite

### FW001 -- FWStatusTriage

**Version:** 1.0
**Category:** Firewall
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Fast triage snapshot of Windows Firewall reality. Answers the question every tech asks when Intune marks a device non-compliant for firewall:

> Is the firewall actually running? If it's off, is it off because of a policy, a third-party product, or a broken service? And what is Intune *actually seeing* vs reality?

The critical insight is that **Intune reads firewall health from Security Center (WMI), not directly from the firewall service**. A machine can have all three firewall profiles enabled and actively filtering traffic, but if Security Center's WMI repository has a stale third-party ghost registration reporting "off", Intune marks it non-compliant. FW001 checks both views and flags the gap.

> **Design note:** Unlike the WU and BitLocker suites, the firewall suite has a **much higher "this needs a human decision" rate**. A GPO intentionally disabling the Domain profile for a perimeter-firewall environment is completely valid -- blindly re-enabling it could break network connectivity. FW001's output clearly distinguishes between "genuinely broken" and "needs human review."

#### Usage

```powershell
Invoke-Indago -Name FWStatusTriage
```

#### Parameters

None.

#### What It Checks

##### Check 1 -- Firewall Profile Status

Queries `Get-NetFirewallProfile` for all three profiles (Domain, Private, Public) and correlates each with active network adapters via `Get-NetConnectionProfile`.

**Why the correlation matters:** `Get-NetFirewallProfile` alone tells you if a profile is *configured* as enabled, but not whether it's *actively filtering* on any network adapter. A machine disconnected from all networks can show Domain profile `Enabled = True`, but nothing is being filtered because no adapter is using that profile. The adapter correlation tells the tech which profile is live right now.

For each profile, reports:

| Property | Meaning |
|----------|---------|
| Name | Domain, Private, or Public |
| Enabled | True or False |
| Active Adapters | Which network interfaces are currently bound to this profile |

**Verdict logic:**

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Enabled + has active adapters | `[OK]` | Actively filtering traffic |
| Enabled + no active adapters | `[OK]` | Configured correctly, no adapter using this profile currently |
| Disabled + has active adapters | `[!!]` | **Critical** -- traffic on these adapters is UNFILTERED |
| Disabled + no active adapters | `[!]` | Disabled but not currently live. Risk if an adapter reconnects. |

**Default action deviation flags:**

Only non-standard configurations are flagged. The expected defaults (Inbound=Block, Outbound=Allow) produce no output.

| Deviation | Verdict | Meaning |
|-----------|---------|---------|
| DefaultInboundAction = Allow | `[!]` | All inbound traffic permitted unless explicitly blocked. Significant security risk. |
| DefaultOutboundAction = Block | `[i]` | Restrictive outbound. Not common but valid in hardened environments. |

##### Check 2 -- Security Center Cross-Reference

Queries `ROOT\SecurityCenter2:FirewallProduct` via WMI and compares what Security Center reports against the ground truth from Check 1. This is exactly what Intune reads for compliance evaluation.

For each registered firewall product, the script:
1. Decodes the `productState` bitmask (same methodology as DEF001 -- bits 12-15 for engine state)
2. Identifies whether it's the native Windows Firewall (GUID `{D68DDC3A-831F-4fae-9E44-DA132C1ACF46}`) or third-party
3. Validates the reporting executable exists on disk (ghost detection)
4. Counts total registered products (multiple = ghost probable)

**Verdict logic:**

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Only native Windows Firewall, state On | `[OK]` | Consistent |
| Third-party firewall registered and On | `[i]` | Windows Firewall may be correctly deferred |
| Third-party registered but Off/Expired | `[!!]` | Registered but not protecting |
| Third-party registered + executable missing | `[!!]` | **Ghost registration** -- stale entry from uninstalled product |
| Native firewall reporting Off | `[!!]` | Intune will report non-compliant |
| Multiple firewall products registered | `[!]` | Ghost registration is probable |

**Desync detection (cross-reference with Check 1):**

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Security Center says On, but profiles are disabled | `[!!]` | False sense of security -- Intune sees compliant, but traffic may be unfiltered |
| All profiles enabled, but Security Center says Off | `[!!]` | Intune will incorrectly flag non-compliant. Likely a ghost registration. |

**Windows Server:** The `SecurityCenter2` namespace is not available on Windows Server. The script reports `[i]` and skips the cross-reference. The remaining checks still work on Server.

##### Check 3 -- MpsSvc Service Health

Checks the Windows Defender Firewall service (`MpsSvc`), which is the master service for all firewall operations.

> **Important difference from previous scriptlets:** Unlike `BDESVC` (BL001), `BITS` (WU001), and `WdNisSvc` (DEF001) which are demand-start services (Manual + Stopped = OK), `MpsSvc` must **always** be Running with Automatic start type. Stopped is always a problem.

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| Running + Automatic | `[OK]` | Operational |
| Running + other start type | `[!]` | Running but wrong start type -- may not survive reboot |
| Stopped + Automatic | `[!!]` | Crashed or stopped. Should be running. |
| Stopped + Manual | `[!!]` | Wrong start type and stopped |
| Disabled | `[!!]` | Cannot start. All network filtering is inactive. |
| Not found | `[!!]` | Critical system component missing |

##### Check 4 -- Active Network Adapters

Lists all active network connections with their firewall profile binding. This is the topology context that the other 3 checks reference.

For each connection, reports:

| Property | Meaning |
|----------|---------|
| Name | Network name (e.g., "Contoso Corp", "Unidentified network") |
| InterfaceAlias | Adapter name (e.g., "Ethernet", "Wi-Fi") |
| NetworkCategory | Profile applied: Domain, Private, or Public |
| IPv4Connectivity | Connection state (Internet, LocalNetwork, NoTraffic) |
| IPv6Connectivity | Connection state |

If no active connections are found, reports `[i]` noting the machine may be offline.

#### Example Output (Healthy System)

```
=== Firewall Status Triage ===

[OK]  Domain Profile
       Enabled. Active on: Ethernet.
[OK]  Private Profile
       Enabled. No adapters currently using this profile.
[OK]  Public Profile
       Enabled. No adapters currently using this profile.
[OK]  Security Center: Windows Defender Firewall
       State: On. Native Windows Firewall registered and active.
[OK]  Firewall Service (MpsSvc)
       Running, start type: Automatic. Operational.
[i]   Network: Contoso Corp (Ethernet)
       Profile: Domain. IPv4: Internet. IPv6: NoTraffic.

RESULT: No issues detected. Firewall appears healthy.

NEXT:   If firewall disabled by policy    -> run FW002 FWPolicyConflict to find the source
        If third-party firewall detected   -> run FW003 FWThirdParty for details
        If MpsSvc stopped/disabled         -> run FW006 FWRemediation to restart
        If Security Center mismatch        -> run FW003 FWThirdParty (likely ghost registration)
```

#### Example Output (Ghost Registration Causing Non-Compliance)

```
=== Firewall Status Triage ===

[OK]  Domain Profile
       Enabled. Active on: Wi-Fi.
[OK]  Private Profile
       Enabled. No adapters currently using this profile.
[OK]  Public Profile
       Enabled. No adapters currently using this profile.
[OK]  Security Center: Windows Defender Firewall
       State: On. Native Windows Firewall registered and active.
[!!]  Security Center: Norton 360
       GHOST REGISTRATION -- product registered but executable not found on disk.
       Path: C:\Program Files\Norton Security\Engine\22.21.5.40\NortonSecurity.exe
       Intune reads this stale entry and may report firewall non-compliant.
       Run FW003 FWThirdParty to investigate and FW006 FWRemediation to clean up.
[!]   Security Center Product Count
       2 firewall products registered. Ghost registration is probable.
       Run FW003 FWThirdParty for detailed analysis.
[OK]  Firewall Service (MpsSvc)
       Running, start type: Automatic. Operational.
[i]   Network: Contoso Corp (Wi-Fi)
       Profile: Domain. IPv4: Internet. IPv6: NoTraffic.

RESULT: 1 issue(s) and 1 warning(s) found. Review items marked [!!] and [!] above.

NEXT:   If firewall disabled by policy    -> run FW002 FWPolicyConflict to find the source
        If third-party firewall detected   -> run FW003 FWThirdParty for details
        If MpsSvc stopped/disabled         -> run FW006 FWRemediation to restart
        If Security Center mismatch        -> run FW003 FWThirdParty (likely ghost registration)
```

#### Scope Boundaries

FW001 is deliberately scoped to fast triage. The following concerns are handled by other scriptlets:

| Concern | Handled By |
|---------|------------|
| GPO registry reads (`HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall`) | FW002 FWPolicyConflict |
| MDM/Intune policy reads (`HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Firewall`) | FW002 FWPolicyConflict |
| MDMWinsOverGP check and GPO-vs-MDM conflict detection | FW002 FWPolicyConflict |
| Side-by-side policy source comparison (Local vs GPO vs MDM) | FW002 FWPolicyConflict |
| Third-party firewall registry scan (Uninstall keys, install paths) | FW003 FWThirdParty |
| Ghost registration cleanup (WMI `.Delete()`) | FW003 (diagnose) / FW006 (remediate) |
| WFP callout driver enumeration | FW003 FWThirdParty |
| BFE and RpcSs service dependency chain | FW004 FWServiceHealth |
| WFP state diagnostics (`netsh wfp show state`) | FW004 FWServiceHealth |
| Firewall log file analysis (`pfirewall.log`) | FW004 FWServiceHealth |
| Service security descriptor (SDDL) validation | FW004 FWServiceHealth |
| Firewall event log timeline (Event IDs 2003, 2004, 5024, 5025) | FW004 FWServiceHealth |
| Rule count, duplicate detection, bloat analysis | FW005 FWRuleDiagnostic |
| Profile re-enable, service restart, ghost cleanup, firewall reset | FW006 FWRemediation |

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. Firewall profile status via `Get-NetFirewallProfile` with active adapter correlation via `Get-NetConnectionProfile`. Security Center `FirewallProduct` cross-reference with `productState` bitmask decoding, ghost detection (exe path validation), and desync detection (Security Center vs profile state). MpsSvc always-Automatic service check (different pattern from demand-start services). Active network adapter inventory with profile binding. Default action deviation flags (Inbound=Allow, Outbound=Block). `NEXT:` footer routing to FW002/FW003/FW006. |

---

### FW002 -- FWPolicyConflict

**Version:** 1.0
**Category:** Firewall
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Answers the question "a firewall profile is disabled -- **WHO disabled it, and WHY?**"

FW001 detects that a profile is disabled. FW002 reads firewall configuration from **all three independent policy sources** (Local, GPO, MDM) and displays them side-by-side, making invisible policy conflicts immediately visible.

The **#1 real-world root cause** of "Intune says firewall is non-compliant" is a stale domain GPO that sets `EnableFirewall = 0` on the Domain profile. This was standard practice 10+ years ago in on-prem environments. When the machine is migrated to Entra ID join, the GPO values are **tattooed** into the `SOFTWARE\Policies` registry hive. GPO overrides MDM by default. The firewall stays disabled. The tech has no idea why. FW002 makes this invisible chain visible and explains it.

#### Usage

```powershell
Invoke-Indago -Name FWPolicyConflict
```

No parameters.

#### What It Checks

##### Check 1 -- Side-by-Side Policy Comparison

For each profile (Domain, Private, Public), reads `EnableFirewall` from 3 independent registry sources:

| Source | Registry Path | Profile Subkeys |
|--------|--------------|-----------------|
| **Local** | `HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy` | `DomainProfile`, `StandardProfile` (=Private), `PublicProfile` |
| **GPO** | `HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall` | `DomainProfile`, `PrivateProfile`, `PublicProfile` |
| **MDM** | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Firewall` | `EnableFirewall_Domain`, `EnableFirewall_Private`, `EnableFirewall_Public` |

Note: Local registry uses `StandardProfile` for Private (historical naming from pre-Vista Windows). GPO uses `PrivateProfile`. MDM uses flat value names with a profile suffix.

`EnableFirewall` values: `1` = Enabled, `0` = Disabled. Absent = system default (Enabled).

**Verdict logic:**

| Condition | Verdict | Meaning |
|-----------|---------|---------|
| All sources agree, all enabled | `[OK]` | No conflict |
| All sources agree, all disabled | `[!!]` | Intentional but firewall is off |
| Sources disagree | `[!!]` | Policy conflict detected |

**Special scenario (user-requested callout):** When GPO disables a profile while MDM wants it enabled and `MDMWinsOverGP` is not active, the output explicitly explains:
- GPO is overriding MDM
- The firewall stays disabled despite Intune policy
- Intune reports non-compliant but the GPO silently wins
- How to fix it (set MDMWinsOverGP=1 or remove the GPO)

##### Check 2 -- EnableFirewall=0 Summary

A focused summary that flags **every** instance of `EnableFirewall = 0` from any source. Provides quick scan for the tech after the detailed side-by-side.

Special callout for GPO `EnableFirewall = 0` on Domain profile -- the #1 legacy artifact, with guidance about Zero Trust incompatibility and tattooing on non-domain-joined machines.

##### Check 3 -- MDMWinsOverGP Conflict Resolution

Source: `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict`

| Value | Meaning |
|-------|---------|
| `MDMWinsOverGP = 1` | MDM takes precedence over GPO |
| `MDMWinsOverGP = 0` or absent | GPO wins by default |

Also validates **confirmation keys** (`MDMWinsOverGP_ProviderSet`, `MDMWinsOverGP_WinningProvider`). If `MDMWinsOverGP = 1` but confirmation keys are absent, the setting is staged but not yet active (reboot needed).

| Condition | Verdict |
|-----------|---------|
| `MDMWinsOverGP = 1` + confirmation keys present | `[OK]` -- MDM wins, GPO ignored |
| `MDMWinsOverGP = 1` + no confirmation keys | `[!]` -- Staged but not active, reboot needed |
| `MDMWinsOverGP = 0` or absent + GPO keys exist | `[!]` -- GPO wins, MDM may be silently overridden |
| `MDMWinsOverGP = 0` or absent + no GPO keys | `[i]` -- No conflict to resolve |

##### Check 4 -- Orphaned GPO Detection

Detects the "tattooed GPO" scenario: GPO registry keys are present but the machine is no longer domain-joined.

Detection logic:
1. Check if GPO keys exist at `HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall`
2. Check domain join status via `Get-CimInstance Win32_ComputerSystem` (`PartOfDomain`)
3. GPO keys present + not domain-joined = **orphaned GPO**

| Condition | Verdict |
|-----------|---------|
| GPO keys present + domain-joined | `[i]` -- Keys expected, verify with GPO owner |
| GPO keys present + NOT domain-joined | `[!!]` -- Orphaned GPO, tattooed remnants |
| No GPO keys | `[OK]` -- No risk |

#### Example Output (GPO Conflict with Explanation)

```
=== Firewall Policy Source & Conflict Detection ===

--- Domain Profile: Policy Sources ---
[!!]  Domain Profile -- Policy CONFLICT
       Local:  EnableFirewall = 1 (Enabled)
       GPO:    EnableFirewall = 0 (DISABLED)
       MDM:    EnableFirewall = 1 (Enabled)

       ROOT CAUSE: GPO is explicitly disabling this profile.
       MDMWinsOverGP is NOT set to 1, so GPO takes precedence over MDM.
       RESULT: The firewall stays DISABLED despite Intune wanting it enabled.
       Intune reports non-compliant, but the GPO silently overrides the MDM policy.
       FIX: Set MDMWinsOverGP=1 via Intune policy, or remove the GPO.

--- Private Profile: Policy Sources ---
[OK]  Private Profile -- No Conflict
       Local:  EnableFirewall = 1 (Enabled)
       GPO:    Not configured
       MDM:    Not configured

--- Public Profile: Policy Sources ---
[OK]  Public Profile -- No Conflict
       Local:  EnableFirewall = 1 (Enabled)
       GPO:    Not configured
       MDM:    Not configured

--- EnableFirewall=0 Summary ---
[!!]  GPO disables Domain Profile (HKLM:\...\DomainProfile\EnableFirewall = 0)
       Legacy GPO artifact detected. This GPO disables the firewall when the machine
       connects to the corporate network. Incompatible with modern Zero Trust.
       This machine is NOT domain-joined. The GPO key is a tattooed remnant.

--- MDMWinsOverGP ---
[!]   MDMWinsOverGP Not Configured (GPO Wins by Default)
       MDMWinsOverGP is not set. In hybrid environments, GPO takes precedence by default.
       GPO firewall registry keys ARE present on this machine.
       If Intune should control the firewall, deploy MDMWinsOverGP=1 via Intune.

--- Orphaned GPO Check ---
[!!]  ORPHANED GPO Detected
       Machine is NOT domain-joined, but GPO firewall registry keys are present.
       These are tattooed remnants from a previous domain membership.
       Options:
         1. Remove the GPO registry keys manually
         2. Set MDMWinsOverGP=1 via Intune to force MDM precedence

RESULT: 3 issue(s) and 1 warning(s) found. Policy conflicts need attention.

NEXT:   If GPO is intentionally disabling firewall -> escalate to GPO owner, do NOT override
        If stale GPO -> remove the registry keys or set MDMWinsOverGP=1
        If MDM policy missing -> check Intune policy assignment and force sync
        If no conflicts -> run FW003 FWThirdParty to check for third-party interference
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Firewall profile live state (enabled/disabled via `Get-NetFirewallProfile`) | FW001 FWStatusTriage |
| Active adapter correlation | FW001 |
| Security Center cross-reference | FW001 |
| MpsSvc service health | FW001 |
| Third-party firewall detection (SecurityCenter2, Uninstall keys) | FW003 FWThirdParty |
| WFP callout driver enumeration | FW003 |
| BFE/RpcSs dependency chain, WFP state, log analysis | FW004 FWServiceHealth |
| Rule count, duplicates, bloat | FW005 FWRuleDiagnostic |
| Profile re-enable, service restart, GPO cleanup | FW006 FWRemediation |

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 4 check groups: side-by-side policy comparison from 3 sources (Local/GPO/MDM) per profile, EnableFirewall=0 detection with legacy GPO callout, MDMWinsOverGP conflict resolution with ProviderSet/WinningProvider confirmation key validation, orphaned GPO detection via `Win32_ComputerSystem.PartOfDomain`. Explicit root-cause explanation when GPO overrides MDM due to missing MDMWinsOverGP. `NEXT:` footer routing to FW003/FW006. |

---

### FW003 -- FWThirdParty

**Version:** 1.0
**Category:** Firewall
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Detects third-party firewalls interfering with Windows Firewall -- either **actively managing traffic** or **left behind as ghost registrations** after uninstallation.

FW001 detects that the firewall is disabled or that Security Center shows a desync. FW002 identifies whether GPO/MDM policy conflicts are the root cause. FW003 goes deeper into the **third-party product layer**: the products themselves, their remnants on disk and in the registry, the "Managed by Vendor" yield state, and orphaned kernel-level WFP filter drivers.

The **#1 silent compliance failure** in managed fleets is the "ghost state": a third-party firewall was uninstalled, but its Security Center WMI registration persists. Windows continues yielding to the absent product, leaving the endpoint with **zero active firewalls**. FW003 provides the detailed forensic analysis to identify and classify these scenarios.

#### Usage

```powershell
Invoke-Indago -Name FWThirdParty
```

No parameters.

#### What It Checks

##### Check 1 -- Security Center FirewallProduct Deep Enumeration

**Method:** `Get-CimInstance -Namespace ROOT/SecurityCenter2 -ClassName FirewallProduct`

For each registered product, extracts and decodes all properties:

| Property | What We Report |
|----------|----------------|
| `displayName` | Product name |
| `instanceGuid` | Unique installation GUID |
| `pathToSignedProductExe` | Primary executable path |
| `productState` | Full bitmask decode (see below) |

**productState Bitmask Decode:**

| Field | Mask | Values |
|-------|------|--------|
| ProductState | `0xF000` | `0x1000` = On, `0x0000` = Off, `0x2000` = Snoozed, `0x3000` = Expired |
| SignatureStatus | `0x00F0` | `0x00` = Up to date, `0x10` = Out of date |
| ProductOwner | `0x0F00` | `0x000` = Third-party, `0x100` = Microsoft |

**Identification:** Native Windows Firewall identified by GUID `{D68DDC3A-831F-4fae-9E44-DA132C1ACF46}` or display name matching `*Windows Defender*` / `*Windows Firewall*`.

| Condition | Verdict |
|-----------|---------|
| Only native Windows Firewall, state On | `[OK]` No third-party interference |
| Third-party registered, state On, exe exists | `[i]` Active third-party firewall managing traffic |
| Third-party registered, state Off/Expired/Snoozed, exe exists | `[!!]` Installed but not protecting |
| Third-party registered, exe missing | `[!!]` Ghost registration |
| SecurityCenter2 not available (Server) | `[i]` Skip, remaining checks still run |

**Difference from FW001:** FW001 performs a light Security Center check (name + on/off + basic ghost flag). FW003 performs full productState bitmask decode (ProductState, SignatureStatus, ProductOwner bits) and cross-references against disk/registry evidence.

##### Check 2 -- Third-Party Firewall Remnant Scan

Scans two independent evidence sources for 14 known third-party firewall vendors:

**Registry scan:** Both 64-bit and WOW6432Node Uninstall keys:
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
- `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`

**Vendor coverage:**

| Vendor | Match Patterns | Install Path | Vendor Registry |
|--------|---------------|--------------|-----------------|
| Symantec / Broadcom | `*Symantec*`, `*Endpoint Protection*` | `C:\Program Files\Symantec\...` | `HKLM:\SOFTWARE\Symantec\InstalledApps` |
| McAfee / Trellix | `*McAfee*`, `*Trellix*` | `C:\Program Files\McAfee\...` | `HKLM:\SOFTWARE\McAfee\Endpoint Security` |
| Sophos | `*Sophos*` | `C:\Program Files\Sophos` | `HKLM:\SOFTWARE\Sophos` |
| ESET | `*ESET*` | `C:\Program Files\ESET\...` | `HKLM:\SOFTWARE\ESET` |
| Comodo | `*Comodo*`, `*COMODO*` | `C:\Program Files\COMODO\...` | `HKLM:\SOFTWARE\ComodoGroup` |
| ZoneAlarm | `*ZoneAlarm*`, `*Zone Labs*` | `C:\Program Files\Zone Labs\...` | `HKLM:\SOFTWARE\Zone Labs` |
| GlassWire | `*GlassWire*` | `C:\Program Files (x86)\GlassWire` | `HKLM:\SOFTWARE\GlassWire` |
| TinyWall | `*TinyWall*` | `C:\Program Files\TinyWall` | `HKLM:\SOFTWARE\TinyWall` |
| Kaspersky | `*Kaspersky*` | -- | `HKLM:\SOFTWARE\KasperskyLab` |
| Norton | `*Norton*` | -- | -- |
| Bitdefender | `*Bitdefender*` | -- | `HKLM:\SOFTWARE\Bitdefender` |
| F-Secure / WithSecure | `*F-Secure*`, `*WithSecure*` | -- | `HKLM:\SOFTWARE\F-Secure` |
| Trend Micro | `*Trend Micro*` | -- | `HKLM:\SOFTWARE\TrendMicro` |
| CrowdStrike | `*CrowdStrike*` | `C:\Program Files\CrowdStrike` | `HKLM:\SYSTEM\CrowdStrike` |

| Condition | Verdict |
|-----------|---------|
| No third-party products found | `[OK]` Clean |
| Product found in Uninstall registry | `[i]` Installed (name, version, publisher) |
| No Uninstall entry but install dir or vendor registry exists | `[!]` Remnant detected, incomplete uninstall |

##### Check 3 -- "Managed by Vendor" State Detection

**Method:** Read `EnableFirewall` from the local firewall service parameter registry for each profile.

**Path:** `HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy`
- Subkeys: `DomainProfile`, `StandardProfile` (=Private), `PublicProfile`
- Value: `EnableFirewall` (DWORD: 0 = Disabled/yielding, 1 = Enabled)

> **Note:** FW002 reads `EnableFirewall` from the **GPO** (`SOFTWARE\Policies`) and **MDM** (`SOFTWARE\Microsoft\PolicyManager`) policy hives. FW003 reads from the **local service parameters** hive (`SYSTEM\CurrentControlSet\Services\SharedAccess`), which is the direct mechanism for "Managed by Vendor" yielding. Different registry paths, different diagnostic purpose.

| Condition | Verdict |
|-----------|---------|
| All profiles EnableFirewall = 1 | `[OK]` No "Managed by Vendor" state |
| EnableFirewall = 0 + active third-party (On in SC) | `[i]` Expected -- Windows yielding to vendor |
| EnableFirewall = 0 + NO active third-party | `[!!]` Ghost "Managed by Vendor" -- endpoint UNPROTECTED |

##### Check 4 -- Ghost Registration Analysis

Cross-references Check 1 (Security Center entries) against Check 2 (disk + registry evidence) for each third-party Security Center entry.

Evidence grid per product:

1. Does `pathToSignedProductExe` exist on disk?
2. Does the product appear in Uninstall registry?
3. Does the vendor install directory or registry key exist?

**Ghost confidence classifications:**

| Classification | Evidence | Verdict |
|----------------|----------|---------|
| Confirmed Ghost | SC entry + exe missing + no Uninstall entry | `[!!]` Product fully removed but SC registration persists |
| Partial Uninstall | SC entry + exe missing + Uninstall entry present | `[!!]` Uninstaller failed to complete |
| Inactive Product | SC entry + exe present + state not On | `[!]` Installed but not protecting |
| Active Product | SC entry + exe present + state On | `[OK]` No ghost concern |
| Orphaned Remnant | No SC entry + vendor files/registry remain | `[!]` Not causing compliance issues but dirty |

##### Check 5 -- WFP Callout Driver Detection

**Method:** `fltmc instances` -- enumerate minifilter driver instances.

> **Note:** Mapping WFP callout GUIDs to specific driver files is not possible with native PowerShell (requires NtQuerySystemInformation or PE header parsing). `fltmc instances` provides practical minifilter/callout driver detection.

Known vendor filter driver patterns:

| Vendor | Filter Names |
|--------|-------------|
| Symantec | `SymEFA`, `SRTSP`, `BHDrvx64` |
| McAfee / Trellix | `mfehidk`, `mfefirek` |
| Sophos | `SophosED`, `SAVOnAccess` |
| ESET | `eamonm`, `ekrn` |
| Kaspersky | `klif`, `kneps` |
| Norton | `SymEFA`, `ccSet` |
| Bitdefender | `bdselfpr`, `BDSandBox` |
| Trend Micro | `TmPreFlt`, `TmFileEncDmk` |
| CrowdStrike | `CSAgent`, `csagent` |

| Condition | Verdict |
|-----------|---------|
| Only Microsoft filter drivers | `[OK]` No third-party WFP interference |
| Known vendor drivers + product installed | `[i]` Expected |
| Known vendor drivers + product NOT installed | `[!!]` Orphaned kernel filter driver |
| Unknown non-Microsoft drivers | `[i]` May be VPN, EDR, backup software |

#### Example Output (Ghost Registration)

```
=== Third-Party Firewall Detection ===

--- Security Center: Registered Firewall Products ---
[OK]  Windows Defender Firewall
       State: On. GUID: {D68DDC3A-831F-4fae-9E44-DA132C1ACF46}.
       Owner: Microsoft. Signatures: Up to date.
[!!]  Norton 360
       GHOST REGISTRATION -- product registered but executable NOT found on disk.
       GUID: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}. Claimed state: On.
       Path: C:\Program Files\Norton Security\Engine\22.21.5.40\NortonSecurity.exe
       Windows Firewall cannot reactivate while this ghost persists.
       Run FW006 FWRemediation to remove the ghost registration.

--- Third-Party Firewall Remnant Scan ---
[!]   Norton -- Remnant Detected
       Vendor registry key found: HKLM:\SOFTWARE\Symantec
       No Uninstall entry found -- product may be partially uninstalled.
       Run vendor cleanup tool to fully remove remnants.

--- "Managed by Vendor" State ---
[!!]  Domain Profile: EnableFirewall = 0
       Windows Firewall is set to yield to a third-party product.
       BUT no active third-party firewall was detected in Security Center.
       RESULT: This profile has ZERO active firewalls.
       Run FW006 FWRemediation to restore Windows Firewall.
[OK]  Private Profile: EnableFirewall = 1
       Windows Firewall is not yielding on this profile.
[OK]  Public Profile: EnableFirewall = 1
       Windows Firewall is not yielding on this profile.

--- Ghost Registration Analysis ---
[!!]  CONFIRMED GHOST: Norton 360
       Security Center registration present but product is NOT installed.
       - Executable: MISSING (C:\Program Files\Norton Security\Engine\22.21.5.40\NortonSecurity.exe)
       - Uninstall entry: MISSING
       - Vendor remnants: PRESENT (orphaned registry/files)
       Windows Firewall cannot reactivate while this ghost persists.
       Run FW006 FWRemediation to remove the ghost registration.

--- WFP Filter Driver Check ---
[OK]  No Third-Party WFP Filter Drivers Detected
       Only Microsoft filter drivers are active.

RESULT: 3 issue(s) and 1 warning(s) found. Review items above.

NEXT:   If ghost registration found     -> run FW006 FWRemediation to clean up
        If active third-party firewall   -> coordinate with vendor for proper configuration
        If WFP filter drivers orphaned   -> manual removal required (driver-level)
        If no third-party issues         -> run FW004 FWServiceHealth for deeper plumbing checks
```

#### Example Output (Clean System)

```
=== Third-Party Firewall Detection ===

--- Security Center: Registered Firewall Products ---
[OK]  Windows Defender Firewall
       State: On. GUID: {D68DDC3A-831F-4fae-9E44-DA132C1ACF46}.
       Owner: Microsoft. Signatures: Up to date.

--- Third-Party Firewall Remnant Scan ---
[OK]  No Third-Party Firewall Remnants
       No known third-party firewall products or remnants found in registry or on disk.

--- "Managed by Vendor" State ---
[OK]  Domain Profile: EnableFirewall = 1
       Windows Firewall is not yielding on this profile.
[OK]  Private Profile: EnableFirewall = 1
       Windows Firewall is not yielding on this profile.
[OK]  Public Profile: EnableFirewall = 1
       Windows Firewall is not yielding on this profile.

--- Ghost Registration Analysis ---
[OK]  No Third-Party Security Center Entries
       No third-party firewall products registered. No ghost risk.

--- WFP Filter Driver Check ---
[OK]  No Third-Party WFP Filter Drivers Detected
       Only Microsoft filter drivers are active.

RESULT: No issues detected. No third-party firewall interference found.

NEXT:   If ghost registration found     -> run FW006 FWRemediation to clean up
        If active third-party firewall   -> coordinate with vendor for proper configuration
        If WFP filter drivers orphaned   -> manual removal required (driver-level)
        If no third-party issues         -> run FW004 FWServiceHealth for deeper plumbing checks
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Firewall profile live state (enabled/disabled via `Get-NetFirewallProfile`) | FW001 FWStatusTriage |
| Active adapter correlation | FW001 |
| MpsSvc service health | FW001 |
| GPO registry reads (`HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall`) | FW002 FWPolicyConflict |
| MDM policy reads (`HKLM\SOFTWARE\Microsoft\PolicyManager`) | FW002 FWPolicyConflict |
| MDMWinsOverGP conflict resolution | FW002 FWPolicyConflict |
| Orphaned GPO detection (tattooed keys on non-domain machines) | FW002 FWPolicyConflict |
| BFE/RpcSs dependency chain, WFP state, log analysis | FW004 FWServiceHealth |
| Rule count, duplicates, bloat | FW005 FWRuleDiagnostic |
| Profile re-enable, ghost cleanup, service restart, reset | FW006 FWRemediation |

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 5 check groups: Security Center FirewallProduct deep enumeration with full productState bitmask decode (ProductState/SignatureStatus/ProductOwner), third-party firewall remnant scan covering 14 vendors (Symantec, McAfee/Trellix, Sophos, ESET, Comodo, ZoneAlarm, GlassWire, TinyWall, Kaspersky, Norton, Bitdefender, F-Secure/WithSecure, Trend Micro, CrowdStrike) via Uninstall registry + install paths + vendor-specific registry, "Managed by Vendor" state detection via SharedAccess EnableFirewall per-profile, ghost registration cross-reference analysis with confidence scoring (confirmed ghost, partial uninstall, inactive, orphaned remnant), WFP filter driver detection via fltmc instances with vendor driver matching. `NEXT:` footer routing to FW004/FW006. |

---

### FW004 -- FWServiceHealth

**Version:** 1.0
**Category:** Firewall
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

Goes deeper into the firewall plumbing when the obvious causes (policy conflicts, third-party products) have been ruled out. FW001 tells the tech "the firewall is off." FW002 identifies "GPO is disabling it." FW003 says "a ghost registration is interfering." FW004 answers the next question: **"The configuration looks correct and there's no third-party interference -- so why isn't the firewall actually working?"**

The Windows Firewall is not a monolithic service. It's a user-mode orchestrator (`MpsSvc`) sitting on top of a dependency chain: `RpcSs` (RPC) -> `BFE` (Base Filtering Engine) -> `MpsSvc`. If any link in the chain breaks, the entire firewall fails -- often silently.

#### Usage

```powershell
Invoke-Indago -Name FWServiceHealth
```

No parameters.

#### What It Checks

##### Check 1 -- Service Dependency Chain

Validates the three-tier dependency chain bottom-up:

| Service | Display Name | Role | Dependency |
|---------|-------------|------|-----------|
| `RpcSs` | Remote Procedure Call | Foundation for COM/DCOM | None |
| `BFE` | Base Filtering Engine | User-mode WFP orchestrator | Depends on RpcSs |
| `MpsSvc` | Windows Defender Firewall | Translates profiles into WFP filters | Depends on BFE |

For each service, reports status, start type, and Win32 exit code from `Win32_Service`.

| Condition | Verdict |
|-----------|---------|
| Running + Automatic | `[OK]` |
| Running + not Automatic | `[!]` May not survive reboot |
| Stopped + Automatic | `[!!]` Should be running |
| Stopped + Disabled | `[!!]` Intentionally disabled |
| StartPending / StopPending | `[!!]` Stuck in transitional state |
| ExitCode != 0 (while running) | `[!]` Previous unclean shutdown |

If a lower-tier service is down, explains the cascade:
- RpcSs down -> BFE cannot start -> MpsSvc cannot start -> firewall dead
- BFE down -> MpsSvc cannot communicate with WFP -> rules not enforced

##### Check 2 -- WFP State

Checks whether the Windows Filtering Platform kernel engine is responsive by running `netsh wfp show state` to a temporary file.

| Condition | Verdict |
|-----------|---------|
| Command succeeds + file has content | `[OK]` WFP engine responsive |
| Command fails (non-zero exit) | `[!!]` WFP not responding |
| Command succeeds but file very small | `[!]` WFP may be degraded |

> **Note:** Full WFP XML parsing (filter ID matching, rule tracing) is not performed here due to known malformed XML bugs on Win10 22H2. FW004 checks WFP **infrastructure health**; rule-level diagnostics belong in FW005.

##### Check 3 -- Firewall Log Configuration & Recent Activity

**Sub-check 3a:** Queries `Get-NetFirewallProfile` for log settings per profile (LogBlocked, LogAllowed, LogFileName, LogMaxSizeKilobytes). Firewall logging is **disabled by default** on all Windows editions -- techs often have zero visibility into drops.

| Condition | Verdict |
|-----------|---------|
| LogBlocked = True | `[OK]` Drops are being recorded |
| LogBlocked = False | `[!]` Drops NOT logged -- enable for troubleshooting |
| LogMaxSize <= 4096 | `[i]` Default size, consider increasing |

**Sub-check 3b:** If logging is enabled, checks the log file: existence, size (flags near 4 MB default limit), and reads the tail for recent DROP entries and `INFO-EVENTS-LOST` entries.

| Condition | Verdict |
|-----------|---------|
| Log file exists | `[OK]` |
| Log missing but logging enabled | `[!!]` |
| Log near 4 MB limit | `[!]` Rolling over rapidly |
| `INFO-EVENTS-LOST` found | `[!!]` Extreme load -- firewall dropping telemetry |
| Recent DROP entries | `[i]` Reports last few for context |

##### Check 4 -- Service Security Descriptor (SDDL) Validation

Runs `sc.exe sdshow MpsSvc` and validates that the SDDL contains the two critical ACEs:
- `SY` (LocalSystem) -- SYSTEM must have access
- `BA` (Built-in Administrators) -- Admins must have access

Advanced malware (ZeroAccess) and aggressive "optimization" scripts modify the SDDL to prevent the firewall from starting. The service silently fails with "Access Denied."

| Condition | Verdict |
|-----------|---------|
| Both SY and BA ACEs present | `[OK]` Permissions intact |
| SY or BA missing | `[!!]` Service descriptor tampered |
| Cannot retrieve SDDL | `[!]` Cannot validate |

> **Note:** Does not compare against a full reference SDDL (varies between Windows versions). Only validates the two critical security principals.

##### Check 5 -- Firewall Event Log Errors

Queries two log sources for the last 24 hours:

**WFAS log** (`Microsoft-Windows-Windows Firewall With Advanced Security/Firewall`):

| Event ID | Meaning |
|----------|---------|
| 2003 | Firewall profile could not be applied |

**System log** (firewall service failures):

| Event ID | Meaning |
|----------|---------|
| 5027 | MpsSvc unable to retrieve security policy |
| 5028 | MpsSvc unable to parse security policy |
| 5030 | Windows Firewall Service failed to start |
| 5035 | Windows Firewall Driver failed to start |
| 5037 | Windows Firewall Driver critical runtime error |

| Condition | Verdict |
|-----------|---------|
| No error events in 24h | `[OK]` |
| Service failure events (5027-5037) | `[!!]` Critical |
| Profile events (2003) | `[!!]` |

#### Example Output (Healthy System, Logging Disabled)

```
=== Firewall Service Dependencies & WFP Health ===

--- Service Dependency Chain ---
[OK]  RpcSs (Remote Procedure Call)
       Running, start type: Automatic. Exit code: 0.
[OK]  BFE (Base Filtering Engine)
       Running, start type: Automatic. Exit code: 0.
[OK]  MpsSvc (Windows Defender Firewall)
       Running, start type: Automatic. Exit code: 0.

--- WFP State ---
[OK]  Windows Filtering Platform
       WFP engine is responsive. State file generated (142 KB).

--- Firewall Log Configuration ---
[!]   Domain Profile Log
       LogBlocked: False. LogAllowed: False.
       Firewall drops are NOT being logged. Enable for troubleshooting.
[!]   Private Profile Log
       LogBlocked: False. LogAllowed: False.
       Firewall drops are NOT being logged. Enable for troubleshooting.
[!]   Public Profile Log
       LogBlocked: False. LogAllowed: False.
       Firewall drops are NOT being logged. Enable for troubleshooting.

--- Service Security Descriptor ---
[OK]  MpsSvc SDDL
       Both SY (SYSTEM) and BA (Administrators) ACEs are present.
       Service permissions are intact.

--- Firewall Event Log ---
[OK]  No Errors (Last 24h)
       No firewall service failure events found in System or WFAS logs.

RESULT: 3 warning(s) found. Review items marked [!] above.

NEXT:   If BFE or RpcSs stopped     -> restart the dependency chain (run FW006 FWRemediation)
        If service descriptor tampered -> run FW006 FWRemediation to reset
        If WFP degraded             -> may require reboot or deeper investigation
        If all clean                -> run FW005 FWRuleDiagnostic to check for rule corruption
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Firewall profile enabled/disabled state | FW001 FWStatusTriage |
| Active adapter correlation | FW001 |
| Security Center FirewallProduct cross-reference | FW001 |
| GPO/MDM policy reads for EnableFirewall | FW002 FWPolicyConflict |
| MDMWinsOverGP conflict resolution | FW002 |
| Orphaned GPO detection | FW002 |
| Third-party firewall detection, ghost analysis | FW003 FWThirdParty |
| WFP callout driver detection (fltmc) | FW003 |
| Rule count, duplicates, bloat | FW005 FWRuleDiagnostic |
| Profile re-enable, ghost cleanup, service restart | FW006 FWRemediation |

**Overlap notes:**
- FW001 performs a basic MpsSvc check (Running/Stopped, Automatic/Manual/Disabled). FW004 checks the **full dependency chain** (RpcSs -> BFE -> MpsSvc) with exit codes, validates the SDDL, and checks WFP health. Different depth.
- FW003 detects third-party WFP filter drivers via `fltmc instances`. FW004 checks WFP **infrastructure** via `netsh wfp show state`. Different aspects of the same platform.

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 5 check groups: service dependency chain (RpcSs/BFE/MpsSvc) with Get-Service status, StartType, and Win32_Service ExitCode validation plus cascade failure explanation, WFP state check via netsh wfp show state to temp file with responsiveness verification, firewall log configuration audit via Get-NetFirewallProfile (LogBlocked/LogAllowed per profile, log file existence/size with 4MB threshold, tail 50 lines for DROP and INFO-EVENTS-LOST detection), MpsSvc SDDL validation via sc.exe sdshow with SY/BA ACE presence check for malware tampering detection, firewall event log scan (WFAS log ID 2003, System log IDs 5027/5028/5030/5035/5037, last 24h window). `NEXT:` footer routing to FW005/FW006. |

---

### FW005 -- FWRuleDiagnostic

**Version:** 1.0
**Category:** Firewall
**Context:** System
**Type:** Diagnostic (read-only)

#### Purpose

When the firewall service runs but behaves erratically -- slow boot, Security Center timeout reporting "firewall off", or Intune non-compliance despite all policies and services looking correct -- the root cause is often **extreme rule bloat**. Thousands of accumulated, orphaned, or duplicate firewall rules overwhelm the `MpsSvc` service's ability to parse and load the rule set into the Windows Filtering Platform (WFP) within acceptable timeframes.

FW001-FW004 systematically eliminate the obvious causes: profile state, policy conflicts, third-party products, and service health. FW005 is the next-level diagnostic: **"The service is running, policies are correct, no third-party interference -- so why is the firewall choking?"** The answer is usually buried in the rule store itself.

#### Usage

```powershell
Invoke-Indago -Name FWRuleDiagnostic
```

No parameters.

#### What It Checks

##### Check 1 -- Total Rule Count

Counts all firewall rules using CIM (`MSFT_NetFirewallRule` in `ROOT/StandardCimv2`) with a 30-second timeout. If CIM hangs or fails (common on severely bloated systems where `Get-NetFirewallRule` takes 10+ minutes), falls back to counting registry values at `HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules`.

> **CIM vs Registry note:** CIM counts all rules including GPO-deployed and MDM-deployed rules. The registry fallback only counts local rules, which may undercount the total. The source is reported in the output.

| Count | Verdict | Meaning |
|-------|---------|---------|
| < 500 | `[OK]` | Healthy |
| 500-3000 | `[i]` | Normal for managed environments |
| 3001-10000 | `[!]` | Elevated, worth investigating |
| > 10000 | `[!!]` | Extreme bloat, likely causing MpsSvc startup delays and Security Center timeout |

##### Check 2 -- Rules Per Profile

Parses the `Profile=` field from each registry rule string to count rules targeting each firewall profile (Domain, Private, Public, All).

A disproportionate concentration in one profile -- e.g., 8000 rules targeting Public but only 200 targeting Domain -- suggests user-level application rule sprawl (the `%LocalAppData%` phenomenon).

| Condition | Verdict |
|-----------|---------|
| Balanced distribution | `[OK]` |
| One profile has >70% of all rules | `[!]` Disproportionate concentration |
| Any profile has >5000 rules | `[!]` Likely auto-generated application rules |

##### Check 3 -- Duplicate Rule Detection

Identifies functionally identical rules using a 6-field fingerprint: **Name + Direction + Action + Program + Protocol + LocalPort**.

**Method:** Parses each rule's pipe-delimited registry string to extract the 6 fields. Builds a hash-based fingerprint and groups rules. Two rules with the same fingerprint are true duplicates regardless of their GUID/value name.

Reports:
- Total duplicate groups (unique fingerprints that appear more than once)
- Total redundant rules (individual copies beyond the first)
- Top 5 worst offenders (rule name + copy count)

| Condition | Verdict |
|-----------|---------|
| No duplicates | `[OK]` |
| < 50 duplicate groups | `[i]` Minor, common in managed environments |
| 50-500 duplicate groups | `[!]` Significant bloat |
| > 500 duplicate groups | `[!!]` Extreme duplication, likely runaway auto-rule generator |

##### Check 4 -- Invalid Application Paths (Orphaned Rules)

Rules with `App=` (Program property) pointing to executables that no longer exist on disk. These cause parsing errors during MpsSvc startup and contribute to boot-time bloat.

**The `%LocalAppData%` problem:** Running as SYSTEM, `%LocalAppData%` resolves to `C:\Windows\System32\config\systemprofile\AppData\Local` -- useless for validating user-level application rules. The script handles this by:
1. Detecting rules containing `%LocalAppData%`, `%APPDATA%`, or `%USERPROFILE%`
2. Enumerating all user profile directories from `C:\Users\*`
3. Reconstructing the full path per user profile
4. Testing if the executable exists in ANY user profile
5. Also handles hardcoded user paths (`C:\Users\JohnDoe\AppData\Local\...`) the same way
6. System variables (`%ProgramFiles%`, `%SystemRoot%`, etc.) are expanded normally

Reports:
- Total orphaned rule count
- Percentage of app-path rules that are orphaned
- Top 5 example paths

| Condition | Verdict |
|-----------|---------|
| No orphaned rules | `[OK]` |
| < 50 orphaned | `[i]` Minor, routine cleanup |
| 50-500 orphaned | `[!]` Significant bloat |
| > 500 orphaned | `[!!]` Major cause of MpsSvc startup delay |

##### Check 5 -- Firewall Rule Store Size

Measures the aggregate byte size of all registry values at `FirewallRules` (Unicode REG_SZ, 2 bytes per character).

The combined firewall and IPsec rule configuration that `MpsSvc` must load into memory has a hard limit of approximately **14 MB**. Beyond this, the service fails to compile the rules into WFP kernel filters.

| Size | Verdict | Meaning |
|------|---------|---------|
| < 2 MB | `[OK]` | Normal |
| 2-5 MB | `[i]` | Growing, monitor |
| 5-10 MB | `[!]` | Large, may cause startup delays |
| > 10 MB | `[!!]` | Approaching MpsSvc payload limit |

##### Check 6 -- Enabled vs Disabled Ratio

Windows ships hundreds of disabled rules by default (Remote Desktop, file sharing, etc.). A large disabled count is normal. But thousands of **enabled** custom rules is a red flag -- every enabled rule is evaluated per-packet by WFP.

| Condition | Verdict |
|-----------|---------|
| < 500 enabled | `[OK]` |
| 500-2000 enabled | `[i]` Normal for managed environments |
| 2001-5000 enabled | `[!]` Heavy, may slow per-packet evaluation |
| > 5000 enabled | `[!!]` Extreme, likely auto-generated |

##### Check 7 -- Rule Corruption Events (Event ID 4953)

Queries the Security event log for Event ID 4953 in the last 7 days. This event is logged when Windows Firewall ignores a rule because it could not be parsed -- a direct indicator of a corrupted rule string in the registry.

| Condition | Verdict |
|-----------|---------|
| No Event 4953 in 7 days | `[OK]` No rule corruption detected |
| Event 4953 found | `[!!]` Rule corruption confirmed, with event count and last occurrence |

> **Key distinction from FW004:** FW004 Check 5 covers service failure events (5027, 5028, 5030, 5035, 5037) and profile application events (2003). FW005 Check 7 covers Event 4953, which is specifically a rule-level corruption event -- different scope.

#### Example Output (Healthy System)

```
=== Rule Corruption & Bloat Diagnostics ===

[OK]  Total Rule Count
       287 rules (source: CIM). Healthy rule count.
[OK]  Rules Per Profile
       Domain: 45, Private: 32, Public: 58, All: 152 (of 287 local). Distribution is balanced.
[OK]  Duplicate Rules
       No duplicate rules found. Each rule has a unique fingerprint (Name+Direction+Action+Program+Protocol+Port).
[OK]  Orphaned Application Paths
       All 94 rules with application paths point to valid executables.
[OK]  Rule Store Size
       0.38 MB. Rule store size is healthy.
[OK]  Enabled vs Disabled Rules
       142 enabled, 145 disabled (of 287 local). Healthy.
[OK]  Rule Corruption Events (4953)
       No Event 4953 (unparseable rule) in last 7 days. No rule corruption detected.

RESULT: No rule bloat or corruption issues detected.

NEXT:   If rule count extreme        -> consider a firewall reset via FW006 FWRemediation
        If many duplicates           -> clean up via policy management tool or reset
        If orphaned paths            -> remove stale rules manually or via script
        If Event 4953 detected       -> identify the malformed rule from event detail
        If all clean                 -> the issue is likely policy or service-level (FW001-FW004)
```

#### Example Output (Bloated System)

```
=== Rule Corruption & Bloat Diagnostics ===

[!!]  Total Rule Count
       14327 rules (source: Registry (local rules only)). EXTREME BLOAT -- likely causing
       MpsSvc startup delays, Security Center timeout, and Intune non-compliance.
       Consider a firewall reset via FW006 FWRemediation.
[!]   Rules Per Profile
       Domain: 102, Private: 89, Public: 12841, All: 1295 (of 14327 local).
       One profile has >70% of all rules -- disproportionate concentration.
[!!]  Duplicate Rules
       1247 duplicate groups, 11983 redundant rules.
       Top: Google Chrome (342x), Microsoft Teams (287x), Spotify (198x),
       WebexHost (156x), Docker Desktop (112x).
       Extreme duplication -- likely runaway auto-rule generator. Consider reset via FW006.
[!!]  Orphaned Application Paths
       8234 of 12156 rules point to missing executables (67.7%).
       Major cause of MpsSvc startup delay. These cause parsing errors on every boot.
       - C:\Users\jdoe\AppData\Local\Google\Chrome\Application\chrome.exe
       - C:\Users\deleteduser\AppData\Local\Spotify\spotify.exe
       - C:\Users\temp01\AppData\Local\Programs\Microsoft VS Code\Code.exe
[!!]  Rule Store Size
       11.73 MB. Approaching MpsSvc payload limit (~14 MB). Service may fail to compile
       rules into WFP. Reset via FW006.
[!!]  Enabled vs Disabled Rules
       11489 enabled, 2838 disabled (of 14327 local). Extreme -- every enabled rule
       is evaluated per-packet.
[!!]  Rule Corruption Events (4953)
       47 events in last 7 days. A rule was ignored because it could not be parsed.
       Last: 2026-04-03 09:15.

RESULT: 6 issue(s) and 1 warning(s) found. Review items marked [!!] above.

NEXT:   If rule count extreme        -> consider a firewall reset via FW006 FWRemediation
        If many duplicates           -> clean up via policy management tool or reset
        If orphaned paths            -> remove stale rules manually or via script
        If Event 4953 detected       -> identify the malformed rule from event detail
        If all clean                 -> the issue is likely policy or service-level (FW001-FW004)
```

#### Scope Boundaries

| Concern | Handled By |
|---------|------------|
| Firewall profile enabled/disabled state | FW001 FWStatusTriage |
| Active adapter correlation | FW001 |
| Security Center cross-reference | FW001 |
| MpsSvc service health | FW001 |
| GPO registry reads (`EnableFirewall`) | FW002 FWPolicyConflict |
| MDM policy reads | FW002 |
| MDMWinsOverGP conflict resolution | FW002 |
| Orphaned GPO detection | FW002 |
| Third-party firewall detection, ghost analysis | FW003 FWThirdParty |
| WFP callout driver detection (fltmc) | FW003 |
| BFE/RpcSs dependency chain | FW004 FWServiceHealth |
| WFP infrastructure state | FW004 |
| Firewall log analysis | FW004 |
| Service SDDL validation | FW004 |
| Service failure events (5027, 5028, 5030, 5035, 5037), profile events (2003) | FW004 |
| Profile re-enable, ghost cleanup, service restart, firewall reset | FW006 FWRemediation |

**Overlap notes:**
- FW004 Check 5 covers service failure events (5027/5028/5030/5035/5037) and profile events (2003). FW005 Check 7 covers Event 4953 (rule ignored because unparseable). Different event IDs, different diagnostic purpose.
- FW001 Check 1 reads `Get-NetFirewallProfile` for profile enabled/disabled state. FW005 Check 2 counts rules per profile from registry. Different question (is it on? vs how many rules?).

#### Version History

| Version | Changes |
|---------|---------|
| 1.0 | Initial build. 7 check groups: total rule count via CIM MSFT_NetFirewallRule with 30-second timeout and registry fallback (thresholds: 500/3000/10000), per-profile distribution from registry pipe-delimited Profile= field with 70% concentration and 5000 threshold flags, 6-field duplicate detection (Name+Direction+Action+Program+Protocol+LocalPort) via hash-based fingerprinting with top-5 offender reporting, orphaned application path validation with SYSTEM-context %LocalAppData%/%APPDATA%/%USERPROFILE% expansion against C:\Users\* profiles plus absolute user path validation, registry store size measurement (Unicode byte calculation) against 14 MB MpsSvc payload limit (thresholds: 2/5/10 MB), enabled vs disabled ratio from Active= field (thresholds: 500/2000/5000), Event ID 4953 (rule ignored because unparseable) from Security log 7-day window. `NEXT:` footer routing to FW006. |