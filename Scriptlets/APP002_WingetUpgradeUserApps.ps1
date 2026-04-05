# APP002_WingetUpgradeUserApps.ps1
# Scriptlet: APP002 - Upgrade User Applications (winget)
# Context: User | Version: 1.0

$ErrorActionPreference = 'Continue'

$wingetPath = $null
$resolveMethod = 'none'

# Strategy 1: App Execution Alias
$alias = Get-Command winget -ErrorAction SilentlyContinue
if ($null -ne $alias) {
    $wingetPath = $alias.Source
    $resolveMethod = 'AppAlias'
}

# Strategy 2: LOCALAPPDATA probe
if ($null -eq $wingetPath -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $probe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $probe) {
        $wingetPath = $probe
        $resolveMethod = 'LocalAppData'
    }
}

# Strategy 3: AppxPackage
if ($null -eq $wingetPath) {
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $pkg) {
            $candidate = Join-Path $pkg.InstallLocation 'winget.exe'
            if (Test-Path $candidate) {
                $wingetPath = $candidate
                $resolveMethod = 'AppxPackage'
            }
        }
    } catch { }
}

# Strategy 4: Glob fallback
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
Write-Output '=== Winget Upgrade Report (User-Scoped) ==='
Write-Output ''

if ($null -eq $wingetPath) {
    Write-Output '[ERR] winget not found.'
    Write-Output '      Install App Installer from the Microsoft Store.'
    Write-Output ''
    return
}

Write-Output "[OK]  Resolved winget via: $resolveMethod"
Write-Output "      Path: $wingetPath"
Write-Output "      User: $env:USERNAME"
Write-Output ''

try {
    $output = & $wingetPath upgrade --all --silent --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    foreach ($line in $output) {
        Write-Output $line
    }
}
catch {
    Write-Output "[ERR] winget failed: $($_.Exception.Message)"
}

Write-Output ''
Write-Output 'User-scoped upgrade complete.'
Write-Output ''
