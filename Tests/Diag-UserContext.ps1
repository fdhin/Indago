<#
.SYNOPSIS
    Tests file-based output capture with redirect=false (pipe bypass).
#>

Write-Output ''
Write-Output '=== File-Based Capture Diagnostic ==='
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$mod = Get-Module Indago
if ($null -eq $mod) {
    Write-Output '[FAIL] Not loaded.'
    return
}

$user = & $mod { Resolve-LoggedOnUser }
Write-Output "[OK] User: $($user.FullName)"
Write-Output ''

$pwshPath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\powershell.exe"

# Heartbeat location: C:\Users\Public is writable by ALL users
$heartbeat = 'C:\Users\Public\indago_heartbeat.txt'
$outputFile = 'C:\Users\Public\indago_output.txt'

# Clean up first
if (Test-Path $heartbeat) { Remove-Item $heartbeat -Force }
if (Test-Path $outputFile) { Remove-Item $outputFile -Force }

# ============================================================
# TEST 1: Simple heartbeat — does the script execute at all?
# ============================================================
Write-Output '[TEST 1] Heartbeat via EncodedCommand (redirect=false)'

$script1 = @"
[System.IO.File]::WriteAllText('$heartbeat', "alive at `$(Get-Date -Format 'HH:mm:ss') as `$env:USERNAME")
"@
$enc1 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script1))
$args1 = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -EncodedCommand $enc1"

$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$pid1 = & $mod {
    param($app, $cmd, $workDir)
    [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
        $app, $cmd, $workDir,
        $false,   # hidden
        30000,    # 30s timeout
        $false,   # NOT elevated
        $false,   # NO redirect (pipe bypass)
        $false    # NO breakaway
    )
} $pwshPath "`"$pwshPath`" $args1" (Split-Path $pwshPath -Parent)
$sw1.Stop()

Write-Output "  PID: $pid1  Duration: $($sw1.ElapsedMilliseconds)ms"

if (Test-Path $heartbeat) {
    $content = Get-Content $heartbeat -Raw
    Write-Output "  [OK]   HEARTBEAT EXISTS: $content"
}
else {
    Write-Output '  [FAIL] No heartbeat file. Script never executed.'
    Write-Output '         The process is being created but dying before PowerShell initializes.'
    Write-Output ''
    Write-Output '  Trying with elevated=false, breakaway=false, visible=TRUE...'

    # Retry VISIBLE
    if (Test-Path $heartbeat) { Remove-Item $heartbeat -Force }
    $sw1b = [System.Diagnostics.Stopwatch]::StartNew()
    $pid1b = & $mod {
        param($app, $cmd, $workDir)
        [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
            $app, $cmd, $workDir,
            $true,    # VISIBLE
            30000,
            $false,
            $false,
            $false
        )
    } $pwshPath "`"$pwshPath`" $args1" (Split-Path $pwshPath -Parent)
    $sw1b.Stop()

    Write-Output "  PID: $pid1b  Duration: $($sw1b.ElapsedMilliseconds)ms"
    if (Test-Path $heartbeat) {
        $content = Get-Content $heartbeat -Raw
        Write-Output "  [OK]   VISIBLE heartbeat: $content"
    }
    else {
        Write-Output '  [FAIL] Still no heartbeat even with visible=true.'
    }
    Write-Output ''
    return
}
Write-Output ''

# ============================================================
# TEST 2: Full output capture via file
# ============================================================
Write-Output '[TEST 2] Output capture via temp file'

$script2 = @"
`$ErrorActionPreference = 'Continue'
try {
    `$result = & {
        Write-Output "USERNAME=`$env:USERNAME"
        Write-Output "USERPROFILE=`$env:USERPROFILE"
        Write-Output "LOCALAPPDATA=`$env:LOCALAPPDATA"
        Write-Output "HELLO_FROM_USER"
    } | Out-String
    [System.IO.File]::WriteAllText('$outputFile', `$result, [System.Text.Encoding]::UTF8)
} catch [System.Exception] {
    [System.IO.File]::WriteAllText('$outputFile', "ERROR: `$(`$_.Exception.Message)", [System.Text.Encoding]::UTF8)
}
"@
$enc2 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script2))
$args2 = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -EncodedCommand $enc2"

$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$pid2 = & $mod {
    param($app, $cmd, $workDir)
    [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
        $app, $cmd, $workDir,
        $false, 30000, $false, $false, $false
    )
} $pwshPath "`"$pwshPath`" $args2" (Split-Path $pwshPath -Parent)
$sw2.Stop()

Write-Output "  PID: $pid2  Duration: $($sw2.ElapsedMilliseconds)ms"

if (Test-Path $outputFile) {
    $output = Get-Content $outputFile -Raw
    Write-Output '  [OK]   Output file captured!'
    foreach ($line in ($output -split "`n")) {
        $t = $line.Trim()
        if ($t) { Write-Output "         $t" }
    }
}
else {
    Write-Output '  [FAIL] No output file.'
}
Write-Output ''

# Cleanup
if (Test-Path $heartbeat) { Remove-Item $heartbeat -Force }
if (Test-Path $outputFile) { Remove-Item $outputFile -Force }

Write-Output '=== Done ==='
Write-Output ''
