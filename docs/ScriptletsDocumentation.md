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