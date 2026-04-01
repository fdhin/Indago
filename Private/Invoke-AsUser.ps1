function Invoke-AsUser {
    <#
    .SYNOPSIS
        Executes a script string as the currently logged-on user via CreateProcessAsUser.
    .DESCRIPTION
        Wraps the RunAsUser C# engine with Indago defaults:
        - Hidden window (no user-visible flash)
        - Elevated token (admin rights without password)
        - Output capture via stdout pipe
        - RMM job breakaway support (CREATE_BREAKAWAY_FROM_JOB)
        - Base64-encoded command (avoids file access and quoting issues)
    .PARAMETER ScriptText
        The PowerShell script to execute as the logged-on user.
    .PARAMETER TimeoutMs
        Maximum milliseconds to wait for the script to complete.
        Default: 300000 (5 minutes). Use -1 for infinite wait.
    .OUTPUTS
        [string] The captured stdout from the user-context process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 300000
    )

    #region Verify C# type is loaded
    if (-not $script:IndagoState.TypeLoaded) {
        Write-Error 'Invoke-AsUser: The RunAsUser C# type is not loaded. User-context execution is unavailable.'
        return $null
    }
    #endregion

    #region Verify a user is logged on
    $loggedOnUser = Resolve-LoggedOnUser
    if ($null -eq $loggedOnUser) {
        Write-Error 'Invoke-AsUser: No interactive user session detected. This task requires a logged-on user.'
        return $null
    }
    Write-Verbose "Invoke-AsUser: Target user: $($loggedOnUser.FullName)"
    #endregion

    #region Encode and execute
    try {
        $encodedCommand = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($ScriptText)
        )
        $pwshPath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\powershell.exe"
        $pwshArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -EncodedCommand $encodedCommand"

        # Check command line length limit
        $maxLength = 32767
        if ($pwshArgs.Length -gt $maxLength) {
            Write-Verbose 'Invoke-AsUser: Encoded command exceeds command line limit. Using CacheToDisk mode.'
            return Invoke-AsUserCacheToDisk -ScriptText $ScriptText -TimeoutMs $TimeoutMs
        }

        Write-Verbose "Invoke-AsUser: Executing as $($loggedOnUser.FullName) (hidden, elevated, breakaway)"

        $output = [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
            $pwshPath,                              # appPath
            "`"$pwshPath`" $pwshArgs",              # cmdLine
            (Split-Path $pwshPath -Parent),         # workDir
            $false,                                 # visible = hidden
            $TimeoutMs,                             # wait
            $true,                                  # elevated = admin token
            $true,                                  # redirectOutput = capture stdout
            $true                                   # breakaway = RMM job compat
        )

        return $output
    }
    catch {
        Write-Error "Invoke-AsUser: Failed to execute as user. Error: $($_.Exception.Message)"
        return $null
    }
    #endregion
}

function Invoke-AsUserCacheToDisk {
    <#
    .SYNOPSIS
        Fallback for scripts that exceed the command line length limit.
    .DESCRIPTION
        Writes the script to a user-accessible temp file, executes it via
        -File parameter, then cleans up.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 300000
    )

    $tempDir = Join-Path -Path $env:SystemRoot -ChildPath 'Temp'
    $scriptGuid = [guid]::NewGuid().ToString('N')
    $tempFile = Join-Path -Path $tempDir -ChildPath "$scriptGuid.ps1"

    try {
        Set-Content -Path $tempFile -Value $ScriptText -Encoding UTF8 -Force -ErrorAction Stop

        # Grant user read+execute on the temp file
        try {
            $acl = Get-Acl -Path $tempFile -ErrorAction Stop
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Users', 'ReadAndExecute', 'Allow'
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $tempFile -AclObject $acl -ErrorAction Stop
        }
        catch {
            Write-Warning "Invoke-AsUserCacheToDisk: Could not set ACL on temp file: $($_.Exception.Message)"
        }

        $pwshPath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\powershell.exe"
        $pwshArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$tempFile`""

        $output = [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
            $pwshPath,
            "`"$pwshPath`" $pwshArgs",
            (Split-Path $pwshPath -Parent),
            $false,
            $TimeoutMs,
            $true,
            $true,
            $true
        )

        return $output
    }
    catch {
        Write-Error "Invoke-AsUserCacheToDisk: Failed. Error: $($_.Exception.Message)"
        return $null
    }
    finally {
        if (Test-Path -Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
