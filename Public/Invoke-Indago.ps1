function Resolve-ExecutionContext {
    param(
        [string]$TaskContext,
        [switch]$AsSystem
    )

    $execContext = $TaskContext
    if ($AsSystem.IsPresent) {
        $execContext = 'System'
        Write-Verbose 'Invoke-Indago: Forced to System context via -AsSystem switch.'
    }
    elseif ($execContext -eq 'Auto') {
        $loggedOnUser = Resolve-LoggedOnUser
        if ($null -ne $loggedOnUser) {
            $execContext = 'User'
            Write-Verbose "Invoke-Indago: Auto-resolved to User context ($($loggedOnUser.FullName))"
        }
        else {
            $execContext = 'System'
            Write-Verbose 'Invoke-Indago: Auto-resolved to System context (no user logged on)'
        }
    }
    return $execContext
}

function Build-ScriptletContent {
    param(
        [object]$Task,
        [hashtable]$BoundParams
    )

    $scriptText = $Task.Script
    $paramBlock = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $BoundParams.Keys) {
        $value = $BoundParams[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $escapedValue = $value -replace "'", "''"
            $paramBlock.Add("`$$key = '$escapedValue'")
        }
        else {
            if ($null -ne $Task.Parameters -and $null -ne $Task.Parameters.$key) {
                $defaultVal = $Task.Parameters.$key.Default
                if (-not [string]::IsNullOrWhiteSpace($defaultVal)) {
                    $escapedDefault = $defaultVal -replace "'", "''"
                    $paramBlock.Add("`$$key = '$escapedDefault'")
                }
                else {
                    $paramBlock.Add("`$$key = `$null")
                }
            }
            else {
                $paramBlock.Add("`$$key = `$null")
            }
        }
    }

    return ($paramBlock -join "`n") + "`n" + $scriptText
}

function Invoke-Indago {
    <#
    .SYNOPSIS
        Runs a named scriptlet from the Indago catalog.
    .DESCRIPTION
        Looks up a pre-built troubleshooting or repair scriptlet by name,
        injects parameters, and executes it in the appropriate context
        (System or User). No special characters, script blocks, or pipes required.

        System-context tasks execute directly and return native PowerShell objects.
        User-context tasks execute via CreateProcessAsUser and return text output.
    .PARAMETER Name
        The scriptlet name (e.g. DiagnoseWindowsUpdate, DiagnoseDefenderSensor).
        Use Get-IndagoList to see available names.
    .PARAMETER Param1
        First parameter for the scriptlet. Meaning varies per task.
        Use Get-IndagoHelp -Name <task> to see what each parameter does.
    .PARAMETER Param2
        Second parameter for the scriptlet.
    .PARAMETER Param3
        Third parameter for the scriptlet.
    .PARAMETER Param4
        Fourth parameter for the scriptlet.
    .PARAMETER Param5
        Fifth parameter for the scriptlet.
    .PARAMETER AsSystem
        Force execution in SYSTEM context even if the scriptlet defaults to User.
    .EXAMPLE
        Invoke-Indago -Name DiagnoseWindowsUpdate
    .EXAMPLE
        Invoke-Indago -Name DiagnoseWindowsUpdate -Param1 "30" -Verbose
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$Param1,

        [Parameter(Mandatory = $false)]
        [string]$Param2,

        [Parameter(Mandatory = $false)]
        [string]$Param3,

        [Parameter(Mandatory = $false)]
        [string]$Param4,

        [Parameter(Mandatory = $false)]
        [string]$Param5,

        [Parameter(Mandatory = $false)]
        [switch]$AsSystem
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    #region No-name guard — show task list instead of deadlocking
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Output 'Usage: Invoke-Indago -Name <TaskName>'
        Write-Output ''
        Get-IndagoList
        return
    }
    #endregion

    #region Look up scriptlet
    $catalog = @($script:IndagoState.ScriptletCatalog)
    if ($catalog.Count -eq 0) {
        Write-Error 'No scriptlets loaded. The catalog may be missing or invalid.'
        return
    }

    $task = $catalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $task) {
        Write-Error "Scriptlet not found: $Name. Use Get-IndagoList to see available tasks."
        # Suggest close matches
        $suggestions = @($catalog | Where-Object { $_.Name -like "*$Name*" })
        if ($suggestions.Count -gt 0) {
            Write-Warning "Did you mean: $($suggestions.Name -join ', ')?"
        }
        return
    }

    Write-Verbose "Invoke-Indago: Found scriptlet $($task.Id) - $($task.DisplayName)"
    #endregion

    #region Validate required parameters
    if ($null -ne $task.Parameters) {
        $paramNames = @($task.Parameters | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        foreach ($paramName in $paramNames) {
            $paramDef = $task.Parameters.$paramName
            if ($paramDef.Required -eq $true) {
                $suppliedValue = (Get-Variable -Name $paramName -ValueOnly -ErrorAction SilentlyContinue)
                if ([string]::IsNullOrWhiteSpace($suppliedValue)) {
                    Write-Error "Scriptlet '$Name' requires -$paramName ($($paramDef.Name): $($paramDef.Description))"
                    return
                }
            }
        }
    }
    #endregion

    #region Determine execution context
    $execContext = Resolve-ExecutionContext -TaskContext $task.ExecutionContext -AsSystem:$AsSystem.IsPresent
    #endregion

    #region Build the script with parameter injection
    $boundParams = @{
        'Param1' = $Param1
        'Param2' = $Param2
        'Param3' = $Param3
        'Param4' = $Param4
        'Param5' = $Param5
    }
    $fullScript = Build-ScriptletContent -Task $task -BoundParams $boundParams
    Write-Verbose "Invoke-Indago: Script prepared ($($fullScript.Length) chars), context: $execContext"
    #endregion

    #region Execute
    try {
        if ($execContext -eq 'System') {
            # Direct execution in current SYSTEM session — native PowerShell objects
            Write-Verbose 'Invoke-Indago: Executing in System context (direct).'
            $sb = [scriptblock]::Create($fullScript)
            $result = & $sb
            $stopwatch.Stop()

            Write-WinLog -TaskName $Name -ExecutionContext 'System' -Status 'Success' `
                -DurationMs $stopwatch.ElapsedMilliseconds

            return $result
        }
        else {
            # User-context execution via CreateProcessAsUser — text output
            Write-Verbose 'Invoke-Indago: Executing in User context (CreateProcessAsUser).'

            $output = Invoke-AsUser -ScriptText $fullScript
            $stopwatch.Stop()

            Write-WinLog -TaskName $Name -ExecutionContext 'User' -Status 'Success' `
                -DurationMs $stopwatch.ElapsedMilliseconds

            if (-not [string]::IsNullOrWhiteSpace($output)) {
                # Try to deserialize JSON output for richer display
                # Scriptlets that want structured output will ConvertTo-Json their results
                try {
                    $deserialized = ConvertFrom-Json -InputObject $output -ErrorAction Stop
                    return $deserialized
                }
                catch {
                    # Not JSON — return as plain text (this is fine)
                    return $output
                }
            }
            else {
                Write-WinLog -TaskName $Name -ExecutionContext 'User' -Status 'Warning' `
                    -Message 'No output captured from user-context execution' `
                    -DurationMs $stopwatch.ElapsedMilliseconds
                Write-Warning "Invoke-Indago: '$Name' completed but produced no output. The user-context process may have failed silently. Run with -Verbose for diagnostics."
                return $null
            }
        }
    }
    catch {
        $stopwatch.Stop()
        Write-WinLog -TaskName $Name -ExecutionContext $execContext -Status 'Error' `
            -Message $_.Exception.Message -DurationMs $stopwatch.ElapsedMilliseconds

        Write-Error "Invoke-Indago: Failed to execute '$Name'. Error: $($_.Exception.Message)"
        return $null
    }
    #endregion
}
