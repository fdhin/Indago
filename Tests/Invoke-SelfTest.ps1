<#
.SYNOPSIS
    Self-test harness for Indago module.
.DESCRIPTION
    Validates the scriptlet catalog schema, script syntax, and module structure.
    Run this after making changes to verify nothing is broken.

    This test does NOT require SYSTEM context or a Windows machine — it only
    validates the JSON schema and script syntax.
.EXAMPLE
    .\Invoke-SelfTest.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$passed = 0
$failed = 0
$total  = 0

function Test-Assert {
    param(
        [string]$TestName,
        [bool]$Condition,
        [string]$FailMessage = ''
    )
    $script:total++
    if ($Condition) {
        $script:passed++
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host "  [FAIL] $TestName" -ForegroundColor Red
        if ($FailMessage) {
            Write-Host "         $FailMessage" -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Indago Self-Test' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

#region Test 1: Module Structure
Write-Host '--- Module Structure ---' -ForegroundColor Cyan
$moduleRoot = Split-Path -Path $PSScriptRoot -Parent

Test-Assert 'Indago.psd1 exists' `
    (Test-Path (Join-Path $moduleRoot 'Indago.psd1'))

Test-Assert 'Indago.psm1 exists' `
    (Test-Path (Join-Path $moduleRoot 'Indago.psm1'))

Test-Assert 'Public directory exists' `
    (Test-Path (Join-Path $moduleRoot 'Public'))

Test-Assert 'Private directory exists' `
    (Test-Path (Join-Path $moduleRoot 'Private'))

Test-Assert 'Scriptlets directory exists' `
    (Test-Path (Join-Path $moduleRoot 'Scriptlets'))

$expectedPublic = @('Invoke-Indago.ps1', 'Get-IndagoList.ps1', 'Get-IndagoHelp.ps1', 'Get-LoggedOnUser.ps1')
foreach ($file in $expectedPublic) {
    Test-Assert "Public/$file exists" `
        (Test-Path (Join-Path $moduleRoot "Public\$file"))
}

$expectedPrivate = @('Invoke-AsUser.ps1', 'Resolve-LoggedOnUser.ps1', 'Write-WinLog.ps1', 'Import-ScriptletCatalog.ps1')
foreach ($file in $expectedPrivate) {
    Test-Assert "Private/$file exists" `
        (Test-Path (Join-Path $moduleRoot "Private\$file"))
}
#endregion

#region Test 2: Catalog JSON
Write-Host ''
Write-Host '--- Scriptlet Catalog Schema ---' -ForegroundColor Cyan

$catalogPath = Join-Path $moduleRoot 'Scriptlets\ScriptletCatalog.json'

Test-Assert 'ScriptletCatalog.json exists' (Test-Path $catalogPath)

$catalog = $null
$jsonValid = $false
try {
    $rawJson = Get-Content -Path $catalogPath -Raw -ErrorAction Stop
    $catalog = ConvertFrom-Json -InputObject $rawJson -ErrorAction Stop
    $jsonValid = $true
}
catch {
    # Will be caught by the assert below
}

Test-Assert 'ScriptletCatalog.json is valid JSON' $jsonValid

if ($jsonValid -and $null -ne $catalog) {
    $catalogArray = @($catalog)
    Test-Assert "Catalog has entries (found $($catalogArray.Count))" ($catalogArray.Count -gt 0)

    $requiredFields = @('Id', 'Name', 'DisplayName', 'Category', 'Description', 'ExecutionContext', 'Script', 'Version')
    $validContexts = @('System', 'User', 'Auto')

    foreach ($entry in $catalogArray) {
        $entryId = $entry.Id

        # Required fields
        foreach ($field in $requiredFields) {
            $value = $entry.$field
            Test-Assert "[$entryId] Has required field: $field" `
                ($null -ne $value -and ([string]$value).Trim() -ne '')
        }

        # Valid ExecutionContext
        Test-Assert "[$entryId] ExecutionContext is valid ($($entry.ExecutionContext))" `
            ($entry.ExecutionContext -in $validContexts)

        # Name is alphanumeric
        Test-Assert "[$entryId] Name is alphanumeric ($($entry.Name))" `
            ($entry.Name -match '^[A-Za-z0-9]+$')

        # Script parses without syntax errors
        $scriptParses = $false
        try {
            $null = [scriptblock]::Create($entry.Script)
            $scriptParses = $true
        }
        catch {
            # Will be caught below
        }
        Test-Assert "[$entryId] Script parses without syntax errors" $scriptParses

        # Script is not just a stub
        Test-Assert "[$entryId] Script is implemented (not a stub)" `
            ($entry.Script.Length -gt 100) `
            'Script appears to be a stub placeholder.'

        # Parameters object exists (can be empty)
        Test-Assert "[$entryId] Has Parameters field" `
            ($null -ne $entry.Parameters)
    }

    # Check for duplicate IDs
    $ids = $catalogArray | ForEach-Object { $_.Id }
    $uniqueIds = $ids | Select-Object -Unique
    Test-Assert 'No duplicate IDs in catalog' ($ids.Count -eq $uniqueIds.Count)

    # Check for duplicate Names
    $names = $catalogArray | ForEach-Object { $_.Name }
    $uniqueNames = $names | Select-Object -Unique
    Test-Assert 'No duplicate Names in catalog' ($names.Count -eq $uniqueNames.Count)
}
#endregion

#region Test 3: Module Manifest
Write-Host ''
Write-Host '--- Module Manifest ---' -ForegroundColor Cyan

$manifestPath = Join-Path $moduleRoot 'Indago.psd1'
$manifestValid = $false
$manifest = $null
try {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    $manifestValid = $true
}
catch {
    # Will be caught below
}

Test-Assert 'Module manifest is valid' $manifestValid

if ($manifestValid -and $null -ne $manifest) {
    Test-Assert 'PowerShellVersion is 5.1' `
        ($manifest.PowerShellVersion -eq [version]'5.1')

    Test-Assert 'RootModule is Indago.psm1' `
        ($manifest.RootModule -eq 'Indago.psm1')

    $expectedFunctions = @('Invoke-Indago', 'Get-IndagoList', 'Get-IndagoHelp', 'Get-LoggedOnUser')
    foreach ($fn in $expectedFunctions) {
        Test-Assert "Exports function: $fn" `
            ($manifest.ExportedFunctions.Keys -contains $fn)
    }
}
#endregion

#region Test 4: Write-WinLog
. (Join-Path $PSScriptRoot 'Test-WriteWinLog.ps1')
#endregion

#region Summary
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$summaryColor = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Results: $passed passed, $failed failed, $total total" -ForegroundColor $summaryColor
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) {
    exit 1
}
#endregion
