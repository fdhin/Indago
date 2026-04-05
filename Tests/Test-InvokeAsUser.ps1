#region Test 6: Invoke-AsUserCacheToDisk Error Handling
Write-Host ''
Write-Host '--- Invoke-AsUser ---' -ForegroundColor Cyan

$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$null = Import-Module -Name (Join-Path $moduleRoot 'Indago.psd1') -Force -WarningAction SilentlyContinue

$testResult = & (Get-Module Indago) {
    # Mock Get-Acl and Set-Acl to simulate ACL failure
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

    # Mock Set-Content to no-op (we don't need a real temp file)
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
        $env:SystemRoot = $env:TMPDIR
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
            $env:SystemRoot = '/tmp'
        }

        $fakeUser = [PSCustomObject]@{ FullName = 'TestUser' }

        # Call the function with mocked internals.
        # StartProcessAsCurrentUser will fail (no real user session), but
        # the ACL catch block should have already run without terminating.
        Invoke-AsUserCacheToDisk -ScriptText "Write-Output 'Test'" -TimeoutMs 1000 -LoggedOnUser $fakeUser -WarningVariable warns -WarningAction Continue -ErrorAction SilentlyContinue

        # Reaching here means the ACL block did not terminate the function
        $noCrash = $true
    }
    catch {
        # A terminating error after -ErrorAction SilentlyContinue means
        # something other than the expected path threw terminally.
        $noCrash = $false
    }
    finally {
        $ErrorActionPreference = 'Continue'
        Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        Remove-Item Function:\Set-Acl -ErrorAction SilentlyContinue
        Remove-Item Function:\Set-Content -ErrorAction SilentlyContinue
        if ($null -ne $oldSystemRoot) { $env:SystemRoot = $oldSystemRoot }
    }

    # PS 5.1 compatible: if/else cannot be used as a value expression in a hashtable
    $warnMsg = ''
    if ($warns.Count -gt 0) { $warnMsg = $warns[0].Message }

    return @{
        NoCrash     = $noCrash
        WarnsCount  = $warns.Count
        WarnMessage = $warnMsg
    }
}

Test-Assert 'Invoke-AsUserCacheToDisk handles ACL error without terminating' ($testResult.NoCrash -eq $true)
Test-Assert 'Invoke-AsUserCacheToDisk emits warning on ACL failure' ($testResult.WarnsCount -gt 0)
Test-Assert 'Warning message contains expected text' ($testResult.WarnMessage -match 'Invoke-AsUserCacheToDisk: Could not set ACL on temp file:')
#endregion
