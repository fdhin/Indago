# Indago

[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/Indago?style=flat-square&label=PSGallery)](https://www.powershellgallery.com/packages/Indago/)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/Indago?style=flat-square&label=Downloads)](https://www.powershellgallery.com/packages/Indago/)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue?style=flat-square)](https://docs.microsoft.com/en-us/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

A self-contained Windows administration toolkit designed for **SYSTEM-context RMM sessions**. Pre-built troubleshooting and repair scriptlets that you can invoke with simple commands — no copy-paste, no special characters, no script blocks, no module downloads.

## The Problem

When running PowerShell as `NT AUTHORITY\SYSTEM` through RMM software (Zoho Assist, ConnectWise, Datto, etc.):

- **No copy-paste** — you're typing everything by hand
- **Special characters are hostile** — pipes `|`, braces `{ }`, backticks, and `$()` are painful or impossible to type
- **No user profile** — `$env:USERPROFILE`, `$HOME`, and `$env:PSModulePath` point nowhere useful
- **No internet** — you can't `Install-Module` or pull scripts from GitHub on a locked-down endpoint
- **Need user context** — tasks like HKCU registry, AppData application updates, and user-profile cleanup must run as the logged-on user, not SYSTEM

## The Solution

Indago bundles everything into a single folder:

1. **A library of pre-built scriptlets** — tested admin tasks stored in a JSON catalog, invokable by name
2. **A user-context execution engine** — based on [RunAsUser](https://github.com/KelvinTegelaar/RunAsUser), uses Win32 `CreateProcessAsUser` to execute scripts as the logged-on user with admin elevation, without typing any passwords
3. **A type-friendly interface** — every command uses simple `Verb-Noun` syntax with `Param1`–`Param5` string parameters. No script blocks, no pipes required

---

## Installation

### From PowerShell Gallery

```powershell
Install-Module -Name Indago -Scope AllUsers
```

> **For RMM deployment:** Install the module on a reference machine, then deploy the installed module folder to endpoints via your RMM. The module installs to `C:\Program Files\WindowsPowerShell\Modules\Indago\` — copy that folder to your endpoints.

### Manual Deployment (Offline / Air-Gapped)

Copy the `Indago` folder to the target machine:

```
C:\ProgramData\Indago\
├── Indago.psd1
├── Indago.psm1
├── Public\
├── Private\
├── Scriptlets\
│   └── ScriptletCatalog.json
└── Tests\
```

For manual deployment, load by absolute path:

```powershell
Import-Module "C:\ProgramData\Indago\Indago.psd1"
```

---

## Quick Start

### Usage (from a SYSTEM prompt)

```powershell
# Load the module (absolute path — no PSModulePath needed)
Import-Module "C:\ProgramData\Indago\Indago.psd1"

# See what tasks are available
Get-IndagoList

# Get help for a specific task
Get-IndagoHelp -Name WUQuickHealth

# Run a task
Invoke-Indago -Name WUQuickHealth
Invoke-Indago -Name DEFStatusTriage
Invoke-Indago -Name BLStatusSnapshot

# Check who's logged in
Get-LoggedOnUser
```

That's it. No pipes, no braces, no passwords, no downloads.

---

## Commands

### `Invoke-Indago`

The main command. Looks up a scriptlet by name, injects parameters, and executes it in the correct context.

```powershell
Invoke-Indago -Name <TaskName> [-Param1 <string>] [-Param2 <string>] ... [-Param5 <string>] [-AsSystem] [-Verbose]
```

| Parameter | Description |
|---|---|
| `-Name` | The scriptlet name (required). Use `Get-IndagoList` to see available names. |
| `-Param1` to `-Param5` | Generic parameters whose meaning varies per scriptlet. Use `Get-IndagoHelp` to see what each parameter does for a specific task. |
| `-AsSystem` | Force execution in SYSTEM context even if the scriptlet defaults to User context. |
| `-Verbose` | Show diagnostic output during execution. |

**Examples:**

```powershell
Invoke-Indago -Name WUQuickHealth
Invoke-Indago -Name WUQuickHealth -Param1 "7" -Verbose
Invoke-Indago -Name WingetUpgradeSystemSilent
```

### `Get-IndagoList`

Lists all available scriptlets in the catalog, optionally filtered by category.

```powershell
Get-IndagoList [-Category <string>]
```

**Examples:**

```powershell
Get-IndagoList
Get-IndagoList -Category WindowsUpdate
Get-IndagoList -Category DefenderEndpoint
Get-IndagoList -Category BitLocker
Get-IndagoList -Category Firewall
```

### `Get-IndagoHelp`

Shows detailed help for a specific scriptlet: description, parameter definitions, execution context, version, and a usage example.

```powershell
Get-IndagoHelp -Name <TaskName>
```

If the name doesn't match exactly, it suggests close matches.

### `Get-LoggedOnUser`

Shows the currently logged-on interactive user. Useful for verifying which user context will be used by User-context scriptlets.

```powershell
Get-LoggedOnUser
```

---

## Scriptlet Catalog

Scriptlets are pre-built PowerShell tasks stored in `Scriptlets/ScriptletCatalog.json`. Each scriptlet is a JSON object with its script text, parameters, execution context, and metadata.

### Current Scriptlets

| Id | Name | Category | Context | Description |
|---|---|---|---|---|
| WU001 | `WUQuickHealth` | WindowsUpdate | System | 30-second triage: services, disk space, pending reboots, recent failures with HRESULT translation, cache size, and last update date |
| WU002 | `WUPolicyAudit` | WindowsUpdate | System | GPO/MDM/WSUS policy detection, ring assignment, deferral days, delivery optimization, and policy conflict identification |
| WU003 | `WUNetworkCheck` | WindowsUpdate | System | DNS resolution, HTTPS connectivity, WinHTTP proxy, system proxy, PAC/WPAD detection, VPN adapter detection, and metered connection status |
| DEF001 | `DEFStatusTriage` | DefenderEndpoint | System | Security Center AV bitmask decoding, Defender mode, RTP, definitions, services, MDE sensor, and signal gap analysis |
| DEF002 | `DEFDefinitionHealth` | DefenderEndpoint | System | Definition update source tracing, staleness analysis, fallback chain validation, MMPC connectivity, and scheduled update task health |
| DEF003 | `DEFThirdPartyAV` | DefenderEndpoint | System | Third-party AV conflict detection, ghost Security Center registrations, 10-vendor remnant scan (registry, services, drivers), and DisableAntiSpyware/DisableAntiVirus policy override detection |
| APP001 | `WingetUpgradeSystemSilent` | Applications | System | Runs winget upgrade --all as SYSTEM to silently update all machine-wide installed applications |
| APP002 | `WingetUpgradeUserApps` | Applications | User | Runs winget upgrade --all --scope user as the logged-on user to update user-scoped applications |
| INT001 | `IntuneForceComplianceCheck` | Intune | System | Triggers a forced Intune compliance evaluation via the Intune Management Extension agent |
| BL001 | `BLStatusSnapshot` | BitLocker | System | Volume encryption status with ghost-state detection, OS drive letter validation, last BitLocker event, and BDESVC health |
| BL002 | `BLTpmHealth` | BitLocker | System | TPM presence, readiness, version, firmware vulnerability scan (ROCA, TPM-FAIL), lockout state, and attestation readiness |
| FW001 | `FWStatusTriage` | Firewall | System | Firewall profile status with active adapter correlation, Security Center cross-reference for ghost detection, and MpsSvc health |
| FW002 | `FWPolicyConflict` | Firewall | System | Side-by-side Local/GPO/MDM firewall policy comparison, EnableFirewall=0 detection, MDMWinsOverGP validation, and orphaned GPO detection |

### Execution Contexts

Each scriptlet specifies where it runs:

| Context | Behavior |
|---|---|
| **System** | Executes directly in the current SYSTEM session. Native PowerShell objects returned. |
| **User** | Executes as the logged-on user via `CreateProcessAsUser`. Elevated (admin rights) without passwords. Output captured as text. |
| **Auto** | Runs as the logged-on user if one is detected, otherwise falls back to SYSTEM. |

### Adding New Scriptlets

Add entries to `Scriptlets/ScriptletCatalog.json`. The module validates the catalog on import — invalid entries are warned and skipped, never crash the module.

**Required fields:**

| Field | Type | Description |
|---|---|---|
| `Id` | string | Unique identifier (e.g. `WU001`, `DEF002`) |
| `Name` | string | Command name, alphanumeric only, no spaces (e.g. `DiagnoseWindowsUpdate`) |
| `DisplayName` | string | Human-readable title |
| `Category` | string | Grouping for `Get-IndagoList -Category` filter |
| `Description` | string | What this scriptlet does |
| `ExecutionContext` | string | `System`, `User`, or `Auto` |
| `Parameters` | object | Map of `Param1`–`Param5` definitions (can be empty `{}`) |
| `Script` | string | The PowerShell script text (embedded as a string) |
| `Version` | string | Scriptlet version |

**Optional fields:** `Tags` (string array), `Notes` (string).

**Parameter definition format:**

```json
"Parameters": {
  "Param1": {
    "Name": "DaysBack",
    "Description": "How many days of history to check",
    "Required": false,
    "Default": "30"
  }
}
```

**Example scriptlet:**

```json
{
  "Id": "NET001",
  "Name": "FlushDns",
  "DisplayName": "Flush DNS Cache",
  "Category": "Network",
  "Description": "Clears the DNS resolver cache.",
  "ExecutionContext": "System",
  "Parameters": {},
  "Script": "Clear-DnsClientCache\nWrite-Output 'DNS cache flushed successfully.'",
  "Tags": ["dns", "network"],
  "Version": "1.0",
  "Notes": "Requires no parameters."
}
```

Run `Tests\Invoke-SelfTest.ps1` after editing the catalog to validate your changes.

---

## Architecture

### How User-Context Execution Works

The module embeds the [RunAsUser](https://github.com/KelvinTegelaar/RunAsUser) C# engine, which uses Win32 APIs to execute a process as the logged-on user directly — no Task Scheduler, no passwords, no visible windows.

```
SYSTEM session
  │
  ├── Import-Module → compiles C# engine via Add-Type (~1-2s, once per session)
  │
  └── Invoke-Indago -Name SomeUserTask
        │
        ├── WTSEnumerateSessions → find active user session
        ├── WTSQueryUserToken → get user's security token
        ├── DuplicateTokenEx → create elevated primary token
        ├── CreateEnvironmentBlock → build user's env vars
        ├── Base64-encode script → -EncodedCommand
        └── CreateProcessAsUserW → spawn hidden powershell.exe as user
              │
              ├── Script executes with user's profile, HKCU, drives, printers
              ├── stdout captured via Win32 named pipes
              └── Output returned to SYSTEM session
```

**Key properties:**
- **No passwords** — SYSTEM has `SeDelegateSessionUserImpersonatePrivilege` to impersonate the user's token
- **Invisible** — `CREATE_NO_WINDOW` flag, user sees nothing
- **Elevated** — uses the linked (full) token when UAC gives a limited token
- **RMM-safe** — `CREATE_BREAKAWAY_FROM_JOB` escapes RMM job sandboxes
- **Self-cleaning** — no scheduled tasks, no temp files (unless script exceeds command-line limit, in which case a temp `.ps1` is created and deleted after execution)

### Module Structure

```
Indago/
├── Indago.psd1              # Manifest: PS 5.1, zero external dependencies
├── Indago.psm1              # C# engine source + Add-Type + dot-sourcing + state init
│
├── Public/                        # Exported commands (what the human types)
│   ├── Invoke-Indago.ps1         # Main dispatcher: lookup → param inject → route → execute
│   ├── Get-IndagoList.ps1        # Catalog browser with category filter
│   ├── Get-IndagoHelp.ps1        # Per-task help with usage examples
│   └── Get-LoggedOnUser.ps1       # Show active interactive user
│
├── Private/                       # Internal engine (not exported)
│   ├── Invoke-AsUser.ps1          # CreateProcessAsUser wrapper (hidden, elevated, breakaway)
│   ├── Resolve-LoggedOnUser.ps1   # User detection via CIM (Win32_ComputerSystem + explorer.exe)
│   ├── Write-WinLog.ps1           # Tab-delimited daily log files
│   └── Import-ScriptletCatalog.ps1 # JSON loader with schema validation
│
├── Scriptlets/
│   └── ScriptletCatalog.json      # All pre-built tasks (single source of truth)
│
└── Tests/
    └── Invoke-SelfTest.ps1        # Schema + structure validation
```

### Module State

All shared state lives in a single hashtable in the root module:

```powershell
$script:IndagoState = @{
    ModuleRoot       = $PSScriptRoot     # Absolute path to module folder
    ScriptletCatalog = $null             # Loaded JSON catalog
    LogPath          = $null             # C:\ProgramData\Indago\Logs\
    LoggedOnUser     = $null             # Cached interactive user info
    TypeLoaded       = $false            # Whether the C# engine compiled
}
```

### Logging

All task executions are logged to `C:\ProgramData\Indago\Logs\Indago_YYYY-MM-DD.log` as tab-delimited entries:

```
2026-03-29 14:30:01	WUQuickHealth	System	N/A	Success	2341ms	
2026-03-29 14:31:15	WingetUpgradeUserApps	User	DOMAIN\jsmith	Success	1204ms	
2026-03-29 14:32:00	DEFStatusTriage	System	N/A	Error	502ms	MsSense service not found
```

Logging never crashes a task — failures are demoted to warnings.

---

## Requirements

- **PowerShell 5.1** (Windows PowerShell, ships with Windows 10/11 and Server 2016+)
- **SYSTEM context** — the module is designed to run as `NT AUTHORITY\SYSTEM` (typical for RMM sessions)
- **No external modules** — zero dependencies, everything is self-contained
- **No internet** — the module is deployed as a folder, no gallery or downloads needed

## Self-Test

Validate the catalog schema and module structure after making changes:

```powershell
& "C:\ProgramData\Indago\Tests\Invoke-SelfTest.ps1"
```

This verifies:
- All expected files exist
- `ScriptletCatalog.json` parses as valid JSON
- Every scriptlet has all required fields
- Every script body parses without syntax errors
- No duplicate IDs or Names
- Module manifest is valid

## License

MIT License — see [LICENSE](LICENSE) for details.

This module includes code derived from [RunAsUser](https://github.com/KelvinTegelaar/RunAsUser) by Kelvin Tegelaar, licensed under the MIT License.
