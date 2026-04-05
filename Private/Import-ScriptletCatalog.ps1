function Import-ScriptletCatalog {
    <#
    .SYNOPSIS
        Loads and validates the ScriptletCatalog.json file.
    .DESCRIPTION
        Reads the scriptlet catalog from the module's Scriptlets directory,
        validates each entry against the expected schema, and returns the
        validated catalog array. Invalid entries are logged as warnings
        but do not halt the load.
    .PARAMETER Path
        Optional override path to the catalog JSON. Defaults to the module's
        built-in Scriptlets/ScriptletCatalog.json.
    .OUTPUTS
        [PSCustomObject[]] Array of validated scriptlet objects.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path -Path $script:IndagoState.ModuleRoot -ChildPath 'Scriptlets\ScriptletCatalog.json'
    }

    if (-not (Test-Path -Path $Path)) {
        Write-Warning "Import-ScriptletCatalog: Catalog not found at: $Path"
        return @()
    }

    try {
        $rawJson = Get-Content -Path $Path -Raw -ErrorAction Stop
        $catalog = ConvertFrom-Json -InputObject $rawJson -ErrorAction Stop
    }
    catch {
        Write-Warning "Import-ScriptletCatalog: Failed to parse JSON. Error: $($_.Exception.Message)"
        return @()
    }

    # Required fields for schema validation
    $requiredFields = @('Id', 'Name', 'DisplayName', 'Category', 'Description', 'ExecutionContext', 'Script', 'Version')
    $validContexts = @('System', 'User', 'Auto')

    $validatedCatalog = [System.Collections.Generic.List[PSCustomObject]]::new()
    $catalogArray = @($catalog)

    function Write-ValidationError {
        param (
            [string]$Id,
            [string]$Message
        )
        Write-Warning "Import-ScriptletCatalog: Scriptlet $Id $Message"
        return $false
    }

    foreach ($entry in $catalogArray) {
        $isValid = $true
        $entryId = if ($null -ne $entry.Id) { $entry.Id } else { '(unknown)' }

        #region Check required fields
        foreach ($field in $requiredFields) {
            $value = $entry.$field
            if ($null -eq $value -or ([string]$value).Trim() -eq '') {
                $isValid = Write-ValidationError -Id $entryId -Message "is missing required field: $field"
            }
        }
        #endregion

        #region Validate ExecutionContext
        if ($null -ne $entry.ExecutionContext -and $entry.ExecutionContext -notin $validContexts) {
            $isValid = Write-ValidationError -Id $entryId -Message "has invalid ExecutionContext: $($entry.ExecutionContext). Must be one of: $($validContexts -join ', ')"
        }
        #endregion

        #region Validate Script parses
        if (-not [string]::IsNullOrWhiteSpace($entry.Script)) {
            try {
                $null = [scriptblock]::Create($entry.Script)
            }
            catch {
                $isValid = Write-ValidationError -Id $entryId -Message "has a script syntax error: $($_.Exception.Message)"
            }
        }
        #endregion

        #region Validate Name is alphanumeric (no spaces or special chars)
        if ($null -ne $entry.Name -and $entry.Name -notmatch '^[A-Za-z0-9]+$') {
            $isValid = Write-ValidationError -Id $entryId -Message "Name contains invalid characters: $($entry.Name). Use alphanumeric only."
        }
        #endregion

        if ($isValid) {
            $validatedCatalog.Add($entry)
        }
        else {
            Write-Warning "Import-ScriptletCatalog: Scriptlet $entryId failed validation and will be skipped."
        }
    }

    Write-Verbose "Import-ScriptletCatalog: Validated $($validatedCatalog.Count) of $($catalogArray.Count) scriptlets."
    return $validatedCatalog.ToArray()
}
