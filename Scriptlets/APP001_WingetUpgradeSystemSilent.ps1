# APP001_WingetUpgradeSystemSilent.ps1
# Scriptlet: APP001 - Upgrade Machine Applications (winget)
# Context: System | Version: 1.2

$ErrorActionPreference = 'Continue'

# Resolve winget path - SYSTEM has no user profile, so we skip
# user-specific strategies and focus on machine-wide resolution.
$wingetPath = $null
$resolveMethod = 'none'

# Strategy 1: App Execution Alias
$alias = Get-Command winget -ErrorAction SilentlyContinue
if ($null -ne $alias) {
    $wingetPath = $alias.Source
    $resolveMethod = 'AppAlias'
}

# Strategy 2: Resolve from DesktopAppInstaller package (-AllUsers for SYSTEM)
if ($null -eq $wingetPath) {
    try {
        $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $pkg) {
            $candidate = Join-Path $pkg.InstallLocation 'winget.exe'
            if (Test-Path $candidate) {
                $wingetPath = $candidate
                $resolveMethod = 'AppxPackage'
            }
        }
    } catch { }
}

# Strategy 3: Brute-force glob
if ($null -eq $wingetPath) {
    $progFiles = $env:ProgramFiles
    if (-not [string]::IsNullOrWhiteSpace($progFiles)) {
        $globPattern = Join-Path $progFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe\winget.exe'
        $found = Get-Item -Path $globPattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
    foreach ($line in $output) {
        Write-Output $line
    }
}
catch {
    Write-Output "[ERR] winget failed: $($_.Exception.Message)"
}

Write-Output ''
Write-Output 'Machine-wide upgrade complete.'
Write-Output ''
