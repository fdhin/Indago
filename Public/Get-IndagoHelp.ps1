function Get-IndagoHelp {
    <#
    .SYNOPSIS
        Shows detailed help for a specific scriptlet, or all scriptlets if no name is given.
    .DESCRIPTION
        Displays the full description, parameter definitions, execution context,
        version, and notes for a named scriptlet. When called without -Name,
        shows help for every scriptlet in the catalog.
    .PARAMETER Name
        The scriptlet name to get help for. If omitted, shows help for all tasks.
    .EXAMPLE
        Get-IndagoHelp
    .EXAMPLE
        Get-IndagoHelp -Name DiagnoseWindowsUpdate
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Name
    )

    $catalog = @($script:IndagoState.ScriptletCatalog)

    if ($catalog.Count -eq 0) {
        Write-Warning 'No scriptlets loaded. The catalog may be missing or invalid.'
        return
    }

    # When no name given, show help for all tasks
    if ([string]::IsNullOrWhiteSpace($Name)) {
        foreach ($entry in $catalog) {
            Show-TaskHelp -Task $entry
        }
        return
    }

    $taskCollection = $catalog.Where({ $_.Name -eq $Name }, 'First')

    if ($taskCollection.Count -eq 0) {
        Write-Warning "Scriptlet not found: $Name"

        # Suggest close matches
        $suggestions = @($catalog | Where-Object { $_.Name -like "*$Name*" })
        if ($suggestions.Count -gt 0) {
            Write-Warning "Did you mean: $($suggestions.Name -join ', ')?"
        }
        else {
            Write-Warning 'Use Get-IndagoList to see all available tasks.'
        }
        return
    }

    $task = $taskCollection[0]

    Show-TaskHelp -Task $task
}

function Show-TaskHelp {
    <#
    .SYNOPSIS
        Renders formatted help for a single scriptlet. Internal helper for Get-IndagoHelp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Task
    )

    $helpLines = [System.Collections.Generic.List[string]]::new()
    $helpLines.Add('')
    $helpLines.Add("  $($Task.DisplayName)")
    $helpLines.Add("  $('=' * $Task.DisplayName.Length)")
    $helpLines.Add('')
    $helpLines.Add("  ID:        $($Task.Id)")
    $helpLines.Add("  Name:      $($Task.Name)")
    $helpLines.Add("  Category:  $($Task.Category)")
    $helpLines.Add("  Context:   $($Task.ExecutionContext)")
    $helpLines.Add("  Version:   $($Task.Version)")
    $helpLines.Add('')
    $helpLines.Add("  DESCRIPTION:")
    $helpLines.Add("  $($Task.Description)")
    $helpLines.Add('')

    # Show parameters if any exist
    if ($null -ne $Task.Parameters) {
        $paramNames = @($Task.Parameters | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object)
        if ($paramNames.Count -gt 0) {
            $helpLines.Add('  PARAMETERS:')
            foreach ($paramName in $paramNames) {
                $paramDef = $Task.Parameters.$paramName
                $requiredTag = if ($paramDef.Required -eq $true) { ' [REQUIRED]' } else { '' }
                $defaultTag = if (-not [string]::IsNullOrWhiteSpace($paramDef.Default)) { " (default: $($paramDef.Default))" } else { '' }
                $helpLines.Add("    -$paramName  =>  $($paramDef.Name)$requiredTag$defaultTag")
                $helpLines.Add("                $($paramDef.Description)")
            }
            $helpLines.Add('')
        }
    }
    else {
        $helpLines.Add('  PARAMETERS: None')
        $helpLines.Add('')
    }

    # Show usage example
    $exampleParts = [System.Collections.Generic.List[string]]::new()
    $exampleParts.Add("Invoke-Indago -Name $($Task.Name)")
    if ($null -ne $Task.Parameters) {
        $paramNames = @($Task.Parameters | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object)
        foreach ($paramName in $paramNames) {
            $paramDef = $Task.Parameters.$paramName
            if ($paramDef.Required -eq $true) {
                $exampleParts.Add("-$paramName `"<$($paramDef.Name)>`"")
            }
        }
    }
    $helpLines.Add("  USAGE:")
    $helpLines.Add("    $($exampleParts -join ' ')")
    $helpLines.Add('')

    # Show notes if present
    if (-not [string]::IsNullOrWhiteSpace($Task.Notes)) {
        $helpLines.Add("  NOTES:")
        $helpLines.Add("  $($Task.Notes)")
        $helpLines.Add('')
    }

    # Output as a single block of text
    $helpLines | ForEach-Object { Write-Output $_ }
}
