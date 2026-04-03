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