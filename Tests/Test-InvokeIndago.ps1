#region Test: Invoke-Indago
Write-Host ''
Write-Host '--- Invoke-Indago ---' -ForegroundColor Cyan

$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$null = Import-Module -Name (Join-Path $moduleRoot 'Indago.psd1') -Force -WarningAction SilentlyContinue

$testResult = & (Get-Module Indago) {
    $originalState = $script:IndagoState
    $originalLogPath = $script:IndagoState.LogPath

    try {
        # Set up a dummy catalog for testing
        $dummyCatalog = @(
            [PSCustomObject]@{
                Id = 'TEST001'
                Name = 'TestSystemTask'
                ExecutionContext = 'System'
                Parameters = $null
                Script = "Write-Output 'System Output'"
            },
            [PSCustomObject]@{
                Id = 'TEST002'
                Name = 'TestRequiredParams'
                ExecutionContext = 'System'
                Parameters = [PSCustomObject]@{
                    Param1 = [PSCustomObject]@{ Name = 'ReqParam'; Required = $true; Description = 'A required param' }
                }
                Script = "Write-Output `"`$Param1`""
            },
            [PSCustomObject]@{
                Id = 'TEST003'
                Name = 'TestParamInjection'
                ExecutionContext = 'System'
                Parameters = [PSCustomObject]@{
                    Param1 = [PSCustomObject]@{ Name = 'P1'; Required = $false; Default = 'DefVal' }
                }
                Script = "Write-Output `"`$Param1-`$Param2`""
            },
            [PSCustomObject]@{
                Id = 'TEST004'
                Name = 'TestUserTask'
                ExecutionContext = 'User'
                Parameters = $null
                Script = "Write-Output 'User Output'"
            }
        )

        $script:IndagoState = [PSCustomObject]@{
            ScriptletCatalog = $dummyCatalog
            LogPath = $originalLogPath
            TypeLoaded = $true
        }

        # Mock Write-WinLog to avoid polluting real logs
        # Must be in script scope so module functions pick it up
        function script:Write-WinLog {
            param($TaskName, $ExecutionContext, $Status, $DurationMs, $Message)
            $script:LastWinLog = @{
                TaskName = $TaskName
                ExecutionContext = $ExecutionContext
                Status = $Status
            }
        }
        $script:LastWinLog = $null

        $results = @{}

        # Test 1: No name provided
        $out = Invoke-Indago | Out-String
        $results.NoNameHasUsage = $out -match 'Usage: Invoke-Indago'

        # Test 2: Task not found
        $results.NotFoundHasError = $false
        try {
            $errs = @()
            Invoke-Indago -Name 'NonExistentTask' -ErrorVariable errs -ErrorAction SilentlyContinue
            if ($errs.Count -gt 0 -and $errs[0].Exception.Message -match 'Scriptlet not found') {
                $results.NotFoundHasError = $true
            }
        } catch {
            if ($_.Exception.Message -match 'Scriptlet not found') {
                $results.NotFoundHasError = $true
            }
        }

        # Test 3: Missing required parameter
        # Use -ErrorAction Stop so Write-Error becomes terminating and is caught
        # by the catch block. -ErrorVariable is unreliable across module scope
        # boundaries in PS 5.1.
        $results.MissingParamHasError = $false
        try {
            Invoke-Indago -Name 'TestRequiredParams' -ErrorAction Stop
        } catch {
            if ($_.Exception.Message -match 'requires -Param1') {
                $results.MissingParamHasError = $true
            }
        }

        # Test 4: System context execution & output
        $sysOut = Invoke-Indago -Name 'TestSystemTask'
        $results.SystemTaskExecutes = ($sysOut -eq 'System Output')
        $results.SystemTaskLogs = ($script:LastWinLog.ExecutionContext -eq 'System' -and $script:LastWinLog.Status -eq 'Success')

        # Test 5: Parameter injection & escaping
        $paramOut = Invoke-Indago -Name 'TestParamInjection' -Param2 "test'val"
        $results.ParamInjectionWorks = ($paramOut -eq "DefVal-test'val")

        # Test 6: AsSystem override
        $script:LastWinLog = $null
        $asSystemOut = Invoke-Indago -Name 'TestUserTask' -AsSystem
        $results.AsSystemOverrides = ($script:LastWinLog.ExecutionContext -eq 'System' -and $asSystemOut -eq 'User Output')

        return $results
    }
    finally {
        $script:IndagoState = $originalState
        Remove-Item Function:\script:Write-WinLog -ErrorAction SilentlyContinue
    }
}

Test-Assert 'Invoke-Indago shows usage when Name is omitted' ($testResult.NoNameHasUsage -eq $true)
Test-Assert 'Invoke-Indago warns when task is not found' ($testResult.NotFoundHasError -eq $true)
Test-Assert 'Invoke-Indago enforces required parameters' ($testResult.MissingParamHasError -eq $true)
Test-Assert 'Invoke-Indago executes System tasks natively' ($testResult.SystemTaskExecutes -eq $true)
Test-Assert 'Invoke-Indago injects parameters correctly' ($testResult.ParamInjectionWorks -eq $true)
Test-Assert 'Invoke-Indago -AsSystem overrides ExecutionContext' ($testResult.AsSystemOverrides -eq $true)
#endregion
