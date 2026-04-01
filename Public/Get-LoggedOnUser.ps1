function Get-LoggedOnUser {
    <#
    .SYNOPSIS
        Shows the currently logged-on interactive user.
    .DESCRIPTION
        Displays the username, domain, and detection source for the
        active interactive user on this machine. Useful for verifying
        which user context will be used by User-context scriptlets.
    .EXAMPLE
        Get-LoggedOnUser
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $userInfo = Resolve-LoggedOnUser

    if ($null -eq $userInfo) {
        Write-Warning 'No interactive user is currently logged on.'
        return $null
    }

    # Return a clean object for console display
    [PSCustomObject]@{
        UserName = $userInfo.UserName
        Domain   = $userInfo.Domain
        FullName = $userInfo.FullName
        Source   = $userInfo.Source
    }
}
