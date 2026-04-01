function Write-WinLog {
    <#
    .SYNOPSIS
        Appends a structured log entry to the Indago daily log file.
    .DESCRIPTION
        Writes timestamped, tab-delimited log entries to
        C:\ProgramData\Indago\Logs\Indago_YYYY-MM-DD.log.
        Each entry records task name, execution context, status, duration, and message.
    .PARAMETER TaskName
        The scriptlet name being executed.
    .PARAMETER ExecutionContext
        System or User.
    .PARAMETER Status
        Success, Error, or Skipped.
    .PARAMETER Message
        Additional detail or error message.
    .PARAMETER DurationMs
        Execution duration in milliseconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('System', 'User')]
        [string]$ExecutionContext,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Error', 'Skipped', 'Warning')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$Message = '',

        [Parameter(Mandatory = $false)]
        [int]$DurationMs = 0
    )

    try {
        $logDir = $script:IndagoState.LogPath
        if ($null -eq $logDir) {
            $logDir = Join-Path -Path 'C:\ProgramData\Indago' -ChildPath 'Logs'
        }

        if (-not (Test-Path -Path $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop
        }

        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path -Path $logDir -ChildPath "Indago_$dateStamp.log"

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $userName = if ($null -ne $script:IndagoState.LoggedOnUser) {
            $script:IndagoState.LoggedOnUser.UserName
        }
        else {
            'N/A'
        }

        # Tab-delimited log line for easy parsing
        $logEntry = "$timestamp`t$TaskName`t$ExecutionContext`t$userName`t$Status`t${DurationMs}ms`t$Message"

        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "Write-WinLog: Logged $Status for $TaskName"
    }
    catch {
        # Logging must never crash the task — warn and continue
        Write-Warning "Write-WinLog: Failed to write log entry. Error: $($_.Exception.Message)"
    }
}
