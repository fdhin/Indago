function Resolve-LoggedOnUser {
    <#
    .SYNOPSIS
        Detects the currently logged-on interactive user.
    .DESCRIPTION
        Uses multiple strategies to find the active interactive user:
        1. Win32_ComputerSystem.UserName (most reliable for console sessions)
        2. Explorer.exe process owner (fallback for edge cases)
        Caches the result in $script:IndagoState.LoggedOnUser.
    .OUTPUTS
        [PSCustomObject] with UserName and Domain properties, or $null if no user is logged on.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    # Always query the live session rather than returning a cached identity.
    # Caching the lookup across multiple task executions in persistent RMM
    # agents is dangerous — if user A logs off and user B logs on, a persistent
    # cache would forever return user A's identity.

    $userInfo = $null

    #region Strategy 1: Win32_ComputerSystem
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($cs.UserName)) {
            $parts = $cs.UserName -split '\\'
            if ($parts.Count -eq 2) {
                $userInfo = [PSCustomObject]@{
                    UserName = $parts[1]
                    Domain   = $parts[0]
                    FullName = $cs.UserName
                    Source   = 'Win32_ComputerSystem'
                }
            }
            else {
                $userInfo = [PSCustomObject]@{
                    UserName = $cs.UserName
                    Domain   = $env:COMPUTERNAME
                    FullName = "$env:COMPUTERNAME\$($cs.UserName)"
                    Source   = 'Win32_ComputerSystem'
                }
            }
            Write-Verbose "Resolve-LoggedOnUser: Found user via Win32_ComputerSystem: $($userInfo.FullName)"
        }
    }
    catch {
        Write-Verbose "Resolve-LoggedOnUser: Win32_ComputerSystem query failed: $($_.Exception.Message)"
    }
    #endregion

    #region Strategy 2: Explorer.exe process owner (fallback)
    if ($null -eq $userInfo) {
        try {
            $explorerProc = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop |
                Select-Object -First 1

            if ($null -ne $explorerProc) {
                $ownerResult = Invoke-CimMethod -InputObject $explorerProc -MethodName GetOwner -ErrorAction Stop
                if ($ownerResult.ReturnValue -eq 0) {
                    $userInfo = [PSCustomObject]@{
                        UserName = $ownerResult.User
                        Domain   = $ownerResult.Domain
                        FullName = "$($ownerResult.Domain)\$($ownerResult.User)"
                        Source   = 'Explorer.exe'
                    }
                    Write-Verbose "Resolve-LoggedOnUser: Found user via Explorer.exe owner: $($userInfo.FullName)"
                }
            }
        }
        catch {
            Write-Verbose "Resolve-LoggedOnUser: Explorer.exe owner query failed: $($_.Exception.Message)"
        }
    }
    #endregion

    if ($null -eq $userInfo) {
        Write-Verbose 'Resolve-LoggedOnUser: No interactive user session detected.'
    }

    return $userInfo
}
