#region Test 5: Invoke-AsUserCacheToDisk Error Handling
Write-Host ''
Write-Host '--- Invoke-AsUser ---' -ForegroundColor Cyan

$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$null = Import-Module -Name (Join-Path $moduleRoot 'Indago.psd1') -Force -WarningAction SilentlyContinue

$testResult = & (Get-Module Indago) {
    function Set-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true)]
            [Alias('PSPath')]
            [string[]]$Path,
            [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
            [Object]$AclObject
        )
        throw "Mocked Set-Acl failure"
    }

    function Get-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true)]
            [Alias('PSPath')]
            [string[]]$Path
        )
        throw "Mocked Get-Acl failure"
    }

    function Set-Content {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true)]
            [Alias('PSPath')]
            [string[]]$Path,
            [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
            [Object]$Value,
            [Parameter()]
            [string]$Encoding,
            [Parameter()]
            [switch]$Force
        )
        # do nothing
    }

    $warns = @()
    $noCrash = $false

    try {
        $ErrorActionPreference = 'Stop'
        $oldSystemRoot = $env:SystemRoot
        $env:SystemRoot = '/tmp'

        $fakeUser = [PSCustomObject]@{ FullName = 'TestUser' }

        # We need to capture both Warnings and Errors so that the overall script doesn't fail from StartProcessAsCurrentUser
        # but we also need to avoid suppressing terminating errors if they come from our ACL catch block (which shouldn't terminate).
        # We will use -ErrorAction SilentlyContinue on the cmdlet call, and check $warns.
        Invoke-AsUserCacheToDisk -ScriptText "Write-Output 'Test'" -TimeoutMs 1000 -LoggedOnUser $fakeUser -WarningVariable warns -WarningAction Continue -ErrorAction SilentlyContinue

        # If it reached here without terminating due to ACL setup, then NoCrash is true.
        # The fact that it continued past the ACL block to the StartProcessAsCurrentUser block and then threw an error there means it didn't terminate during ACL.
        $noCrash = $true
    }
    catch {
        # The only reason it would reach this block is if a terminating error occurred.
        # But we set -ErrorAction SilentlyContinue. If it terminated despite that, it means something went wrong.
        $noCrash = $false
        Write-Host "Error in Invoke-AsUserCacheToDisk test wrapper: $_"
    }
    finally {
        $ErrorActionPreference = 'Continue'
        Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        Remove-Item Function:\Set-Acl -ErrorAction SilentlyContinue
        Remove-Item Function:\Set-Content -ErrorAction SilentlyContinue
        if ($null -ne $oldSystemRoot) { $env:SystemRoot = $oldSystemRoot }
    }

    return @{
        NoCrash = $noCrash
        WarnsCount = $warns.Count
        WarnMessage = if ($warns.Count -gt 0) { $warns[0].Message } else { "" }
    }
}

Test-Assert 'Invoke-AsUserCacheToDisk handles ACL setup error without terminating' ($testResult.NoCrash -eq $true)
Test-Assert 'Invoke-AsUserCacheToDisk emits warning on ACL failure' ($testResult.WarnsCount -gt 0)
Test-Assert 'Warning message contains expected text' ($testResult.WarnMessage -match "Invoke-AsUserCacheToDisk: Could not set ACL on temp file:")
#endregion
