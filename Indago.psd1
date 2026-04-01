@{
    # Module identity
    RootModule           = 'Indago.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b0269411-6c65-49f9-b9f9-4195117af5e7'
    Author               = 'Frantz Dhin'
    CompanyName          = 'Frantz Dhin'
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
            LicenseUri               = 'https://github.com/frantzdhin/Indago/blob/main/LICENSE'

            # Project page
            ProjectUri               = 'https://github.com/frantzdhin/Indago'

            # Release notes (shown on PSGallery version page)
            ReleaseNotes             = @'
## v1.0.0 (2026-03-29)

Initial release.

### Commands
- Invoke-Indago: Run pre-built troubleshooting/repair scriptlets by name
- Get-IndagoList: Browse available scriptlets with category filtering
- Get-IndagoHelp: Detailed help for each scriptlet with usage examples
- Get-LoggedOnUser: Show the currently logged-on interactive user

### Built-in Scriptlets
- WU001 DiagnoseWindowsUpdate: Windows Update service health, failure history, WSUS config
- DEF001 DiagnoseDefenderSensor: MDE sensor, onboarding, AV status, cloud connectivity
- SYS001 GetSystemOverview: OS, uptime, disk, RAM, reboot flags, domain, license

### Engine
- User-context execution via Win32 CreateProcessAsUser (based on RunAsUser)
- No passwords, no Task Scheduler artifacts, invisible to the logged-on user
- RMM job breakaway support (CREATE_BREAKAWAY_FROM_JOB)
- Automatic JSON output deserialization for user-context tasks
'@

            # Minimum PowerShell Gallery module requirements
            RequireLicenseAcceptance = $false
        }
    }
}
