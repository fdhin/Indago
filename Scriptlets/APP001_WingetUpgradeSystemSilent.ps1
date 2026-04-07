# APP001_WingetUpgradeSystemSilent.ps1
# Scriptlet: APP001 - Upgrade Machine Applications (winget)
# Context: System | Version: 1.3

$ErrorActionPreference = 'Continue'

# Resolve winget path - SYSTEM has no user profile, so we skip
# user-specific strategies and focus on machine-wide resolution.
$wingetPath = $null
$resolveMethod = 'none'

# Strategy 1: App Execution Alias
$alias = Get-Command winget -ErrorAction SilentlyContinue
if ($null -ne $alias -and (Test-Path $alias.Source)) {
    $wingetPath = $alias.Source
    $resolveMethod = 'AppAlias'
}

# Strategy 2: Resolve from DesktopAppInstaller package (-AllUsers for SYSTEM)
if ($null -eq $wingetPath) {
    try {
        $pkgs = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
        if ($null -ne $pkgs) {
            foreach ($pkg in @($pkgs)) {
                $candidate = Join-Path $pkg.InstallLocation 'winget.exe'
                if (Test-Path $candidate) {
                    $wingetPath = $candidate
                    $resolveMethod = 'AppxPackage'
                    break
                }
            }
        }
    } catch {
        Write-Verbose "Strategy 2 failed: $($_.Exception.Message)"
    }
}

# Strategy 3: Brute-force glob
if ($null -eq $wingetPath) {
    # Prefer ProgramW6432 to avoid WoW64 redirection under 32-bit PS
    $progFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($progFiles)) { $progFiles = $env:ProgramFiles }
    if (-not [string]::IsNullOrWhiteSpace($progFiles)) {
        $globPattern = Join-Path $progFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe\winget.exe'
        # -Force required: WindowsApps is a hidden system folder
        $found = Get-Item -Path $globPattern -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $found) {
            $wingetPath = $found.FullName
            $resolveMethod = 'GlobFallback'
        }
    }
}

Write-Output ''
Write-Output '=== Winget Upgrade Report (Machine-Wide) ==='
Write-Output ''

if ($null -eq $wingetPath) {
    Write-Output '[ERR] winget not found after 3 resolution strategies.'
    Write-Output '      Tried: AppAlias, AppxPackage (-AllUsers), GlobFallback'
    Write-Output '      Install App Installer from the Microsoft Store.'
    Write-Output ''
    return
}

Write-Output "[OK]  Resolved winget via: $resolveMethod"
Write-Output "      Path: $wingetPath"
Write-Output ''

try {
    $output = & $wingetPath upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $exitCode = $LASTEXITCODE

    # @($output) prevents character-by-character iteration when output is a single string.
    # .ToString() strips PS 5.1 ErrorRecord wrapping from stderr lines.
    foreach ($line in @($output)) {
        Write-Output $line.ToString()
    }

    if ($exitCode -ne 0) {
        Write-Output ''
        Write-Output "[WARN] winget exited with code: $exitCode"
        Write-Output '       Non-zero exit codes may indicate partial failures or no applicable updates.'
    }
}
catch {
    Write-Output "[ERR] winget failed to execute: $($_.Exception.Message)"
}

Write-Output ''
Write-Output 'Machine-wide upgrade complete.'
Write-Output ''
