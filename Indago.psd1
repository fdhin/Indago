@{
    # Module identity
    RootModule           = 'Indago.psm1'
    ModuleVersion        = '0.5.0'
    GUID                 = 'b0269411-6c65-49f9-b9f9-4195117af5e7'
    Author               = 'Frantz Dhin'
    CompanyName          = 'ENVO IT A/S'
    Copyright            = '(c) 2026 Frantz Dhin. All rights reserved.'

    # Description (shown on PSGallery listing page)
    Description          = @'
Self-contained Windows admin toolkit designed for RMM/SYSTEM sessions.

Indago provides pre-built troubleshooting and repair scriptlets that
you can invoke with simple commands - no copy-paste, no special characters,
no script blocks, no pipe characters, no module downloads required.

The module includes a user-context execution engine (based on RunAsUser)
that uses Win32 CreateProcessAsUser to run tasks as the logged-on user
with admin elevation, without passwords ever touching the command line.

Key features:
- Zero external dependencies - everything is self-contained
- Type-friendly interface - Param1 through Param5, no braces or pipes needed
- Invisible user-context execution - no window flash, no Task Scheduler artifacts
- Metadata-driven scriptlet catalog - add tasks via JSON, no code changes
- Structured logging to C:\ProgramData\Indago\Logs
- RMM job breakaway support (CREATE_BREAKAWAY_FROM_JOB)
'@

    # Requirements
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    RequiredModules      = @()

    # Exports - explicit, no wildcards
    FunctionsToExport    = @(
        'Invoke-Indago',
        'Get-IndagoList',
        'Get-IndagoHelp',
        'Get-LoggedOnUser'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    # Files to include in the package
    FileList             = @(
        'Indago.psd1',
        'Indago.psm1',
        'README.md',
        'LICENSE',
        'Public\Invoke-Indago.ps1',
        'Public\Get-IndagoList.ps1',
        'Public\Get-IndagoHelp.ps1',
        'Public\Get-LoggedOnUser.ps1',
        'Private\Invoke-AsUser.ps1',
        'Private\Resolve-LoggedOnUser.ps1',
        'Private\Write-WinLog.ps1',
        'Private\Import-ScriptletCatalog.ps1',
        'Scriptlets\ScriptletCatalog.json',
        'Tests\Invoke-SelfTest.ps1'
    )

    # PSGallery metadata
    PrivateData          = @{
        PSData = @{
            # Tags for discoverability on PSGallery (max 4000 chars total)
            Tags                     = @(
                'Windows',
                'Admin',
                'RMM',
                'SYSTEM',
                'Troubleshooting',
                'Repair',
                'WindowsUpdate',
                'Defender',
                'Endpoint',
                'Intune',
                'Sysadmin',
                'RunAsUser',
                'UserContext',
                'MSP',
                'ZohoAssist',
                'ConnectWise',
                'Datto',
                'NinjaRMM',
                'RemoteManagement',
                'PSEdition_Desktop'
            )

            # License
            LicenseUri               = 'https://github.com/fdhin/Indago/blob/main/LICENSE'

            # Project page
            ProjectUri               = 'https://github.com/fdhin/Indago'

            # Release notes (shown on PSGallery version page)
            ReleaseNotes             = @'
## v0.5.0 (2026-04-05)

Complete Tier 5 diagnostic suite -- 30 scriptlets across 5 categories.

### Commands
- Invoke-Indago: Run pre-built troubleshooting/repair scriptlets by name
- Get-IndagoList: Browse available scriptlets with category filtering
- Get-IndagoHelp: Detailed help for each scriptlet with usage examples
- Get-LoggedOnUser: Show the currently logged-on interactive user

### Windows Update Suite (7 scriptlets)
- WU001 WUQuickHealth: Service health, disk space, reboot state, failure history with HRESULT translation
- WU002 WUComponentHealth: CBS store corruption, DISM health, pending.xml, SessionsPending backlog
- WU003 WUNetworkCheck: WSUS/WUfB config, endpoint connectivity, proxy/PAC detection, metered connection
- WU004 WUPendingUpdates: Pending update enumeration with KB cross-reference and stale detection
- WU005 WUDriverConflict: Driver update isolation, WU driver policy, co-installer detection, rollback history
- WU006 WUHistoryDump: Full update timeline with HRESULT translation, failure clustering, KB gap detection
- WU007 WUEnvironmentAudit: Feature update eligibility, safeguard holds, edition/build/EOL, storage reserves

### Defender Suite (7 scriptlets)
- DEF001 DEFStatusTriage: Security Center AV decode, Defender mode, RTP, definitions, MDE sensor, signal gaps
- DEF002 DEFExclusions: SYSTEM + user-context exclusion enumeration, ASR rule audit, risk scoring
- DEF003 DEFThreatHistory: Threat detection timeline, quarantine inventory, remediation failure analysis
- DEF004 DEFUpdatePipeline: Definition update channel diagnostics, MMPC connectivity, fallback chain
- DEF005 DEFScanHealth: Scan execution history, resource impact, scheduled task validation, offline scan
- DEF006 DEFPlatformVersion: Platform/engine/definition version audit, event log warnings, update services
- DEF007 DEFEventAnalysis: Defender event log timeline from Operational log with 26-event taxonomy

### BitLocker Suite (8 scriptlets)
- BL001 BLStatusSnapshot: Volume status, ghost-state detection, BDESVC health
- BL002 BLTpmHealth: TPM presence, spec version, firmware CVEs, lockout, provisioning readiness
- BL003 BLHardwarePrereqs: UEFI/Secure Boot, GPT, system partition, Modern Standby, OEM quirks
- BL004 BLIntunePolicy: Intune join state, CSP registry, IME log, MDM enrollment health
- BL005 BLEscrowCheck: Escrow pipeline, AAD identity, escrow events, connectivity, protector status
- BL006 BLPolicyConflict: GPO vs MDM conflict detection, cipher/TPM decode, orphaned GPO settings
- BL007 BLEventAnalysis: Event log timeline, 16 tracked Event IDs, HRESULT translation map
- BL008 BLReadinessCheck: Encryption readiness dry run with go/no-go verdict

### Firewall Suite (4 scriptlets)
- FW001 FWStatusTriage: Profile status, adapter correlation, Security Center cross-reference, MpsSvc
- FW002 FWPolicyConflict: Local/GPO/MDM policy comparison, EnableFirewall=0, MDMWinsOverGP
- FW003 FWThirdParty: Security Center enumeration, productState decode, 14-vendor remnant scan, WFP
- FW004 FWRuleAudit: Allow-inbound rule analysis, any/any detection, port exposure, stale rules

### General (4 scriptlets)
- NET001-NET003: Network diagnostics (adapter, DNS, connectivity)
- PRF001: System profile overview
- APP001-APP002: Winget patching (system + user scope)
- INT001: Intune compliance force check

### Engine
- User-context execution via Win32 CreateProcessAsUser (based on RunAsUser)
- No passwords, no Task Scheduler artifacts, invisible to the logged-on user
- RMM job breakaway support (CREATE_BREAKAWAY_FROM_JOB)
- Automatic JSON output deserialization for user-context tasks

### Previous
- v0.1.5 (2026-04-04): Initial release with 7 scriptlets
'@

            # Minimum PowerShell Gallery module requirements
            RequireLicenseAcceptance = $false
        }
    }
}
