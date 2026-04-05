#region Test 4: Write-WinLog Error Handling
Write-Host ''
Write-Host '--- Write-WinLog ---' -ForegroundColor Cyan

$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$null = Import-Module -Name (Join-Path $moduleRoot 'Indago.psd1') -Force -WarningAction SilentlyContinue

$testResult = & (Get-Module Indago) {
    $originalState = $script:IndagoState

    try {
        # Initialize an explicit PSCustomObject instead of hashtable so $logDir is mapped explicitly if checked that way
        $script:IndagoState = [PSCustomObject]@{ LogPath = 'X:\Invalid\Path\That\Does\Not\Exist\Log\Dir' }

        $warns = @()
        $noCrash = $false

        try {
            $ErrorActionPreference = 'Stop'
            # We must catch the warning internally and not throw due to ErrorAction Stop affecting Add-Content but maybe other stuff.
            Write-WinLog -TaskName 'Test' -ExecutionContext 'System' -Status 'Success' -WarningVariable warns -WarningAction Continue -ErrorAction Continue
            $noCrash = $true
        }
        catch {
            $noCrash = $false
        }
        finally {
            $ErrorActionPreference = 'Continue'
        }

        return @{
            NoCrash = $noCrash
            WarnsCount = $warns.Count
        }
    }
    finally {
        $script:IndagoState = $originalState
    }
}

Test-Assert 'Write-WinLog handles invalid path without terminating error' ($testResult.NoCrash -eq $true)
Test-Assert 'Write-WinLog emits warning on failure' ($testResult.WarnsCount -gt 0)
#endregion
