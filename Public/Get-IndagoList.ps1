function Get-IndagoList {
    <#
    .SYNOPSIS
        Lists available scriptlets in the Indago catalog.
    .DESCRIPTION
        Displays all pre-built tasks with their names, categories, execution context,
        and descriptions. Optionally filter by category.
    .PARAMETER Category
        Filter results to a specific category (e.g. WindowsUpdate, DefenderEndpoint).
    .EXAMPLE
        Get-IndagoList
    .EXAMPLE
        Get-IndagoList -Category WindowsUpdate
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Category
    )

    $catalog = @($script:IndagoState.ScriptletCatalog)

    if ($catalog.Count -eq 0) {
        Write-Warning 'No scriptlets loaded. The catalog may be missing or invalid.'
        return
    }

    # Apply category filter if provided (case-insensitive partial match)
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $catalog = @($catalog | Where-Object { $_.Category -like "*$Category*" })
        if ($catalog.Count -eq 0) {
            Write-Warning "No scriptlets found matching category: $Category"

            # Show available categories to help the user
            $allCategories = $script:IndagoState.ScriptletCatalog.Category |
                Select-Object -Unique |
                Sort-Object
            Write-Warning "Available categories: $($allCategories -join ', ')"
            return
        }
    }

    # Output as PSCustomObjects -- never use Format-Table inside a function.
    # Callers can pipe to Format-Table, Where-Object, or capture into a variable.
    # Sort by Category then Id so techs see the correct workflow order
    # (lower numbers = safe read-only triage, higher = deeper diagnostics).
    $catalog |
        Sort-Object -Property Category, Id |
        ForEach-Object {
            [PSCustomObject]@{
                Id          = $_.Id
                Name        = $_.Name
                Category    = $_.Category
                Context     = $_.ExecutionContext
                Description = $_.DisplayName
            }
        }
}
