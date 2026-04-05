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

    # Apply category filter if provided
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $catalog = @($catalog | Where-Object { $_.Category -eq $Category })
        if ($catalog.Count -eq 0) {
            Write-Warning "No scriptlets found in category: $Category"

            # Show available categories to help the user
            $allCategories = @($script:IndagoState.ScriptletCatalog) |
                ForEach-Object { $_.Category } |
                Select-Object -Unique |
                Sort-Object
            Write-Warning "Available categories: $($allCategories -join ', ')"
            return
        }
    }

    # Format as a clean table for console readability, grouped by category
    $catalog |
        Sort-Object -Property Category, Name |
        ForEach-Object {
            [PSCustomObject]@{
                Name        = $_.Name
                Category    = $_.Category
                Context     = $_.ExecutionContext
                Description = $_.DisplayName
            }
        } | Format-Table -AutoSize -Wrap
}
