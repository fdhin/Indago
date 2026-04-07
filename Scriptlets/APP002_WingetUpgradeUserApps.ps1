# APP002_WingetUpgradeUserApps.ps1
# Scriptlet: APP002 - Upgrade User Applications (winget)
# Context: User | Version: 1.1

$ErrorActionPreference = 'Continue'

$wingetPath = $null
$resolveMethod = 'none'

# Strategy 1: App Execution Alias
$alias = Get-Command winget -ErrorAction SilentlyContinue
if ($null -ne $alias -and (Test-Path $alias.Source)) {
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

# Strategy 3: AppxPackage (user context, no -AllUsers needed)
if ($null -eq $wingetPath) {
    try {
        $pkgs = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
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
        Write-Verbose "Strategy 3 failed: $($_.Exception.Message)"
    }
}

# Strategy 4: Glob fallback
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
Write-Output 'User-scoped upgrade complete.'
Write-Output ''
